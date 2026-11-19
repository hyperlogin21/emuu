import Foundation
import Testing
import EmuuBase
import EmuuTestSupport
@testable import EmuuADB

/// Simulates PackageManager on the fake adb server.
final class FakePackageManager: @unchecked Sendable {
    let singleInstalls = Locked<[Data]>([])
    let sessionWrites = Locked<[(String, Data)]>([])
    let shellCommands = Locked<[String]>([])
    let commitReply = Locked("Success\n")
    let installReply = Locked("Success\n")
    let writeReply = Locked<String?>(nil)
    let spec = Locked(Fixtures.deviceSpecReply())

    init(_ fake: FakeADBServer) {
        fake.onShell { [self] cmd in
            shellCommands.withLock { $0.append(cmd) }
            if cmd.contains("ro.product.cpu.abilist") { return .init(stdout: spec.current) }
            if cmd.hasPrefix("cmd package install-create") { return .init(stdout: "Success: created install session [77]\n") }
            if cmd == "cmd package install-commit 77" { return .init(stdout: commitReply.current) }
            if cmd == "cmd package install-abandon 77" { return .init(stdout: "Success\n") }
            return .init(stderr: "unexpected \(cmd)", exit: 1)
        }
        fake.onExec { [self] cmd, conn in
            guard let r = cmd.range(of: "-S ") else { return Data("Error: bad\n".utf8) }
            let size = Int(cmd[r.upperBound...].prefix(while: { $0.isNumber }))!
            let data = conn.readExactly(size) ?? Data()
            if cmd.hasPrefix("cmd package install-write") {
                let parts = cmd.split(separator: " ")
                sessionWrites.withLock { $0.append((String(parts[parts.count - 2]), data)) }
                return Data((writeReply.current ?? "Success: streamed \(size) bytes\n").utf8)
            }
            singleInstalls.withLock { $0.append(data) }
            return Data(installReply.current.utf8)
        }
    }
}

@Suite("APK installer")
struct InstallerTests {
    let dir = Fixtures.tempDir()

    func makeInstaller(_ fake: FakeADBServer, runner: FakeProcessRunner = FakeProcessRunner(), transport: ADBClient.Transport = .automatic) -> (APKInstaller, URL) {
        let cache = dir.appendingPathComponent("cache", isDirectory: true)
        let client = makeClient(fake, runner: runner, transport: transport)
        return (APKInstaller(client: client, cacheDirectory: cache, zip: ZipTool(runner: SystemProcessRunner())), cache)
    }

    @Test func singleAPKIsStreamedIntoPackageManager() async throws {
        let fake = try FakeADBServer()
        let pm = FakePackageManager(fake)
        let apk = try Fixtures.apk(at: dir.appendingPathComponent("game.apk"), package: "com.example.game", abis: ["arm64-v8a", "armeabi-v7a"], payloadBytes: 2_500_000)
        let (installer, _) = makeInstaller(fake)
        let stages = Locked<[InstallStage]>([])
        let result = try await installer.install(file: apk) { p in stages.withLock { $0.append(p.stage) } }
        #expect(result.status == .installed)
        #expect(result.packageName == "com.example.game")
        #expect(result.apkCount == 1)
        #expect(pm.singleInstalls.current == [try Data(contentsOf: apk)])
        #expect(fake.requests.contains { $0.hasPrefix("exec:cmd package install -r -g -t -S ") })
        #expect(stages.current.first == .inspecting)
        #expect(stages.current.contains(.uploading))
        #expect(stages.current.last == .finished)
    }

    @Test func x86OnlyAPKIsRejectedBeforeUpload() async throws {
        let fake = try FakeADBServer()
        let pm = FakePackageManager(fake)
        let apk = try Fixtures.apk(at: dir.appendingPathComponent("x86.apk"), package: "com.old.game", abis: ["x86", "x86_64"])
        let (installer, _) = makeInstaller(fake)
        let result = try await installer.install(.apk(apk))
        guard case .failed(let code, let message) = result.status else { Issue.record("expected failure"); return }
        #expect(code == "INSTALL_FAILED_NO_MATCHING_ABIS")
        #expect(message.contains("x86-only"))
        #expect(message.contains("arm64-v8a"))
        #expect(pm.singleInstalls.current.isEmpty)
    }

    @Test func armv7OnlyAPKExplained() async throws {
        let fake = try FakeADBServer()
        _ = FakePackageManager(fake)
        let apk = try Fixtures.apk(at: dir.appendingPathComponent("v7.apk"), package: "com.old.game", abis: ["armeabi-v7a"])
        let (installer, _) = makeInstaller(fake)
        let result = try await installer.install(.apk(apk))
        guard case .failed(_, let message) = result.status else { Issue.record("expected failure"); return }
        #expect(message.contains("32-bit ARM"))
    }

    @Test func packageManagerFailureIsMappedToHumanText() async throws {
        let fake = try FakeADBServer()
        let pm = FakePackageManager(fake)
        pm.installReply.set("Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: Existing package com.example.game signatures do not match newer version; ignoring!]\n")
        let apk = try Fixtures.apk(at: dir.appendingPathComponent("game.apk"), package: "com.example.game")
        let (installer, _) = makeInstaller(fake)
        let result = try await installer.install(.apk(apk))
        guard case .failed(let code, let message) = result.status else { Issue.record("expected failure"); return }
        #expect(code == "INSTALL_FAILED_UPDATE_INCOMPATIBLE")
        #expect(message.contains("different key"))
        #expect(message.contains("signatures do not match"))
        #expect(result.packageName == "com.example.game")
    }

    @Test func notAnAPKFailsCleanly() async throws {
        let fake = try FakeADBServer()
        _ = FakePackageManager(fake)
        let bogus = dir.appendingPathComponent("bogus.apk")
        try Data("this is not a zip".utf8).write(to: bogus)
        let (installer, _) = makeInstaller(fake)
        let result = try await installer.install(.apk(bogus))
        guard case .failed(let code, _) = result.status else { Issue.record("expected failure"); return }
        #expect(code == "EMUU_NOT_A_ZIP")
    }

    @Test func xapkSelectsSplitsAndCopiesOBB() async throws {
        let fake = try FakeADBServer()
        let pm = FakePackageManager(fake)
        pm.spec.set(Fixtures.deviceSpecReply(abis: "arm64-v8a", density: 320, locale: "fr-FR"))
        let pkg = "com.big.game"
        let staging = dir.appendingPathComponent("parts", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        func apkData(_ name: String, split: String?, abis: [String] = []) throws -> Data {
            try Data(contentsOf: Fixtures.apk(at: staging.appendingPathComponent(name), package: pkg, split: split, abis: abis))
        }
        let obb = Data((0..<(700 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 3) })
        let manifestJSON = """
        {"xapk_version":2,"package_name":"\(pkg)","name":"Big Game","version_code":"42","version_name":"4.2",
         "split_apks":[{"file":"\(pkg).apk","id":"base"},{"file":"config.arm64_v8a.apk","id":"config.arm64_v8a"},
           {"file":"config.x86_64.apk","id":"config.x86_64"},{"file":"config.xxhdpi.apk","id":"config.xxhdpi"},
           {"file":"config.mdpi.apk","id":"config.mdpi"},{"file":"config.en.apk","id":"config.en"},{"file":"config.fr.apk","id":"config.fr"}],
         "expansions":[{"file":"Android/obb/\(pkg)/main.42.\(pkg).obb","install_location":"EXTERNAL_STORAGE","install_path":"Android/obb/\(pkg)/main.42.\(pkg).obb"}]}
        """
        let xapk = try Fixtures.zip([
            "manifest.json": Data(manifestJSON.utf8),
            "icon.png": Data([1, 2, 3]),
            "\(pkg).apk": try apkData("base.apk", split: nil),
            "config.arm64_v8a.apk": try apkData("a.apk", split: "config.arm64_v8a", abis: ["arm64-v8a"]),
            "config.x86_64.apk": try apkData("b.apk", split: "config.x86_64", abis: ["x86_64"]),
            "config.xxhdpi.apk": try apkData("c.apk", split: "config.xxhdpi"),
            "config.mdpi.apk": try apkData("d.apk", split: "config.mdpi"),
            "config.en.apk": try apkData("e.apk", split: "config.en"),
            "config.fr.apk": try apkData("f.apk", split: "config.fr"),
            "Android/obb/\(pkg)/main.42.\(pkg).obb": obb,
        ], to: dir.appendingPathComponent("game.xapk"))
        let (installer, cache) = makeInstaller(fake)
        let stages = Locked<Set<InstallStage>>([])
        let result = try await installer.install(file: xapk) { p in _ = stages.withLock { $0.insert(p.stage) } }
        #expect(result.status == .installed)
        #expect(result.packageName == pkg)
        #expect(result.apkCount == 4)
        #expect(result.obbCount == 1)
        let names = pm.sessionWrites.current.map(\.0)
        #expect(names == ["0_\(pkg).apk", "1_config.arm64_v8a.apk", "2_config.xxhdpi.apk", "3_config.fr.apk"])
        #expect(pm.shellCommands.current.contains { $0.hasPrefix("cmd package install-create -r -g -t -S ") })
        #expect(pm.shellCommands.current.contains("cmd package install-commit 77"))
        #expect(fake.files["/sdcard/Android/obb/\(pkg)/main.42.\(pkg).obb"] == obb)
        #expect(stages.current.isSuperset(of: [.inspecting, .extracting, .uploading, .committing, .copyingExpansionFiles, .finished]))
        // Extracted files are cleaned up.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func obbCopyFailureIsReportedNotThrown() async throws {
        let fake = try FakeADBServer()
        _ = FakePackageManager(fake)
        let pkg = "com.big.game"
        let base = try Fixtures.apk(at: dir.appendingPathComponent("base.apk"), package: pkg)
        let xapk = try Fixtures.zip([
            "base.apk": try Data(contentsOf: base),
            "Android/obb/\(pkg)/main.1.\(pkg).obb": Data(repeating: 7, count: 1000),
        ], to: dir.appendingPathComponent("noman.xapk"))
        fake.failPush(to: "/sdcard/Android/obb/\(pkg)/main.1.\(pkg).obb")
        let (installer, _) = makeInstaller(fake)
        let result = try await installer.install(.xapk(xapk))
        guard case .failed(let code, let message) = result.status else { Issue.record("expected failure"); return }
        #expect(code == "EMUU_OBB_COPY_FAILED")
        #expect(message.contains("installed"))
        #expect(result.packageName == pkg)   // from AndroidManifest (no manifest.json)
    }

    @Test func bundletoolAPKSUsesSplitsDirectory() async throws {
        let fake = try FakeADBServer()
        let pm = FakePackageManager(fake)
        let pkg = "com.example.apks"
        func d(_ name: String, _ split: String?, _ abis: [String] = []) throws -> Data {
            try Data(contentsOf: Fixtures.apk(at: dir.appendingPathComponent(name), package: pkg, split: split, abis: abis))
        }
        let apks = try Fixtures.zip([
            "toc.pb": Data([0x0A, 0x00]),
            "splits/base-master.apk": try d("m.apk", nil),
            "splits/base-arm64_v8a.apk": try d("a.apk", "config.arm64_v8a", ["arm64-v8a"]),
            "splits/base-armeabi_v7a.apk": try d("b.apk", "config.armeabi_v7a", ["armeabi-v7a"]),
            "splits/base-xhdpi.apk": try d("x.apk", "config.xhdpi"),
            "splits/base-hdpi.apk": try d("h.apk", "config.hdpi"),
            "splits/base-en.apk": try d("e.apk", "config.en"),
            "standalones/standalone-arm64_v8a_xhdpi.apk": try d("s.apk", nil),
        ], to: dir.appendingPathComponent("app.apks"))
        let (installer, _) = makeInstaller(fake)
        let result = try await installer.install(file: apks)
        #expect(result.status == .installed)
        #expect(result.packageName == pkg)
        #expect(pm.sessionWrites.current.map(\.0) == ["0_base-master.apk", "1_base-arm64_v8a.apk", "2_base-xhdpi.apk", "3_base-en.apk"])
    }

    @Test func apkmWithInfoJSON() async throws {
        let fake = try FakeADBServer()
        let pm = FakePackageManager(fake)
        let pkg = "com.example.apkm"
        let apkm = try Fixtures.zip([
            "info.json": Data(#"{"pname":"com.example.apkm","versioncode":"9","release_version":"0.9"}"#.utf8),
            "base.apk": try Data(contentsOf: Fixtures.apk(at: dir.appendingPathComponent("b.apk"), package: pkg)),
            "split_config.arm64_v8a.apk": try Data(contentsOf: Fixtures.apk(at: dir.appendingPathComponent("a.apk"), package: pkg, split: "config.arm64_v8a")),
            "split_config.x86.apk": try Data(contentsOf: Fixtures.apk(at: dir.appendingPathComponent("x.apk"), package: pkg, split: "config.x86")),
        ], to: dir.appendingPathComponent("app.apkm"))
        let (installer, _) = makeInstaller(fake)
        let result = try await installer.install(file: apkm)
        #expect(result.status == .installed)
        #expect(result.packageName == pkg)
        #expect(pm.sessionWrites.current.map(\.0) == ["0_base.apk", "1_split_config.arm64_v8a.apk"])
    }

    @Test func sessionWriteFailureAbandonsSession() async throws {
        let fake = try FakeADBServer()
        let pm = FakePackageManager(fake)
        pm.writeReply.set("Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE: not enough space]\n")
        let a = try Fixtures.apk(at: dir.appendingPathComponent("base.apk"), package: "com.x.y")
        let b = try Fixtures.apk(at: dir.appendingPathComponent("split.apk"), package: "com.x.y", split: "config.en")
        let (installer, _) = makeInstaller(fake)
        let result = try await installer.install(.splitAPKs([a, b]))
        guard case .failed(let code, let message) = result.status else { Issue.record("expected failure"); return }
        #expect(code == "INSTALL_FAILED_INSUFFICIENT_STORAGE")
        #expect(message.contains("Not enough free space"))
        #expect(pm.shellCommands.current.contains("cmd package install-abandon 77"))
        #expect(!pm.shellCommands.current.contains("cmd package install-commit 77"))
    }

    @Test func commitFailureIsReported() async throws {
        let fake = try FakeADBServer()
        let pm = FakePackageManager(fake)
        pm.commitReply.set("Failure [INSTALL_FAILED_MISSING_SPLIT: Missing split for com.x.y]\n")
        let a = try Fixtures.apk(at: dir.appendingPathComponent("base.apk"), package: "com.x.y")
        let b = try Fixtures.apk(at: dir.appendingPathComponent("split.apk"), package: "com.x.y", split: "config.en")
        let (installer, _) = makeInstaller(fake)
        let result = try await installer.install(.splitAPKs([a, b]))
        #expect(result.status == .failed(code: "INSTALL_FAILED_MISSING_SPLIT",
                                         message: InstallFailureCatalog.explain(code: "INSTALL_FAILED_MISSING_SPLIT", detail: "Missing split for com.x.y")))
        #expect(result.packageName == "com.x.y")
    }

    @Test func binaryTransportUsesAdbInstall() async throws {
        let fake = try FakeADBServer()
        let runner = FakeProcessRunner()
        runner.on(executable: "adb", argumentsPrefix: ["-s", "emulator-5580", "shell"], respond: .success(Fixtures.deviceSpecReply()))
        runner.on(executable: "adb", argumentsPrefix: ["-s", "emulator-5580", "install"], respond: .success("Performing Streamed Install\nSuccess\n"))
        let apk = try Fixtures.apk(at: dir.appendingPathComponent("b.apk"), package: "com.bin.app")
        let (installer, _) = makeInstaller(fake, runner: runner, transport: .binary)
        let result = try await installer.install(.apk(apk))
        #expect(result.status == .installed)
        #expect(runner.commandLines.contains(["adb", "-s", "emulator-5580", "install", "-r", "-g", "-t", apk.path]))
    }

    @Test func execUnsupportedFallsBackToBinaryInstall() async throws {
        let fake = try FakeADBServer()
        _ = FakePackageManager(fake)
        fake.setExecSupported(false)
        let runner = FakeProcessRunner()
        runner.on(executable: "adb", argumentsPrefix: ["-s", "emulator-5580", "install"],
                  respond: .failure(1, stderr: "adb: failed to install b.apk: Failure [INSTALL_FAILED_OLDER_SDK: Requires newer sdk version #99 (current version is #36)]\n"))
        let apk = try Fixtures.apk(at: dir.appendingPathComponent("b.apk"), package: "com.bin.app")
        let (installer, _) = makeInstaller(fake, runner: runner)
        let result = try await installer.install(.apk(apk))
        guard case .failed(let code, let message) = result.status else { Issue.record("expected failure"); return }
        #expect(code == "INSTALL_FAILED_OLDER_SDK")
        #expect(message.contains("newer Android version"))
    }

    @Test func missingFileThrows() async throws {
        let fake = try FakeADBServer()
        let (installer, _) = makeInstaller(fake)
        await #expect(throws: EmuuError.self) { _ = try await installer.install(.apk(dir.appendingPathComponent("nope.apk"))) }
        await #expect(throws: EmuuError.self) { _ = try await installer.install(file: dir.appendingPathComponent("x.zip")) }
    }
}
