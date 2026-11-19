import Foundation
import Testing
import EmuuBase
import EmuuTestSupport
@testable import EmuuADB

@Suite("Parsers")
struct ParsingTests {
    @Test(arguments: [false, true]) func binaryManifest(utf8: Bool) throws {
        let data = Fixtures.manifest(package: "com.example.game", versionCode: 1234, versionName: "1.2.3", split: "config.arm64_v8a", minSdk: 26, utf8: utf8)
        let m = try APKManifest.parse(binaryXML: data)
        #expect(m.packageName == "com.example.game")
        #expect(m.versionCode == 1234)
        #expect(m.versionName == "1.2.3")
        #expect(m.splitName == "config.arm64_v8a")
        #expect(m.minSdkVersion == 26)
    }

    @Test func binaryManifestRejectsGarbage() {
        #expect(throws: EmuuError.self) { try APKManifest.parse(binaryXML: Data("<?xml version='1.0'?>".utf8)) }
        #expect(throws: EmuuError.self) { try APKManifest.parse(binaryXML: Data([0x03, 0x00, 0x08, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x01])) }
        let truncated = Fixtures.manifest(package: "com.x.y").prefix(60)
        #expect(throws: EmuuError.self) { try APKManifest.parse(binaryXML: Data(truncated)) }
    }

    /// Cross-checks the AXML parser against aapt2 on a real APK shipped with the SDK (skipped if absent).
    @Test(.enabled(if: RealAPK.sample != nil && RealAPK.aapt2 != nil)) func realAPKMatchesAapt2() async throws {
        let apk = RealAPK.sample!
        let zip = ZipTool(runner: SystemProcessRunner())
        let data = try #require(try await zip.read("AndroidManifest.xml", from: apk))
        let ours = try APKManifest.parse(binaryXML: data)
        let r = try await SystemProcessRunner().run(ProcessRequest(executable: RealAPK.aapt2!, arguments: ["dump", "packagename", apk.path], timeout: .seconds(30)))
        #expect(ours.packageName == r.trimmedStdout)
        let badging = try await SystemProcessRunner().run(ProcessRequest(executable: RealAPK.aapt2!, arguments: ["dump", "badging", apk.path], timeout: .seconds(30)))
        if let vc = ours.versionCode { #expect(badging.stdoutString.contains("versionCode='\(vc)'")) }
    }

    @Test func splitClassification() {
        #expect(SplitSelector.classify(fileName: "config.arm64_v8a.apk") == .abi("arm64-v8a"))
        #expect(SplitSelector.classify(fileName: "split_config.armeabi_v7a.apk") == .abi("armeabi-v7a"))
        #expect(SplitSelector.classify(fileName: "splits/base-x86_64.apk") == .abi("x86-64"))
        #expect(SplitSelector.classify(fileName: "config.xxhdpi.apk") == .density("xxhdpi"))
        #expect(SplitSelector.classify(fileName: "base-tvdpi.apk") == .density("tvdpi"))
        #expect(SplitSelector.classify(fileName: "config.en.apk") == .language("en"))
        #expect(SplitSelector.classify(fileName: "base-pt_br.apk") == .language("pt"))
        #expect(SplitSelector.classify(fileName: "base-master.apk") == .other)
        #expect(SplitSelector.classify(fileName: "base.apk") == .other)
        #expect(SplitSelector.classify(fileName: "com.big.game.apk") == .other)
        #expect(SplitSelector.classify(fileName: "split_ads.apk") == .other)
        #expect(SplitSelector.classify(fileName: "feature_maps-master.apk") == .other)
    }

    @Test func splitSelection() throws {
        let spec = DeviceSpec(abis: ["arm64-v8a"], density: 420, languages: ["de"], sdkLevel: 36)
        let names = ["base.apk", "config.arm64_v8a.apk", "config.armeabi_v7a.apk", "config.xhdpi.apk", "config.xxhdpi.apk", "config.xxxhdpi.apk", "config.en.apk", "config.de.apk"]
        let sel = try SplitSelector.select(names, for: spec)
        #expect(sel.selected == ["base.apk", "config.arm64_v8a.apk", "config.xxhdpi.apk", "config.de.apk"])
        // Unknown language: keep all language splits; density above max: take the largest.
        let sel2 = try SplitSelector.select(["base.apk", "config.mdpi.apk", "config.hdpi.apk", "config.en.apk", "config.ja.apk"],
                                            for: DeviceSpec(abis: ["arm64-v8a"], density: 640, languages: ["sw"], sdkLevel: 36))
        #expect(sel2.selected == ["base.apk", "config.hdpi.apk", "config.en.apk", "config.ja.apk"])
        #expect(throws: EmuuError.self) {
            _ = try SplitSelector.select(["base.apk", "config.x86.apk", "config.x86_64.apk"], for: spec)
        }
    }

    @Test func nativeABIs() {
        let entries = ["AndroidManifest.xml", "lib/arm64-v8a/libgame.so", "lib/arm64-v8a/libfmod.so", "lib/armeabi-v7a/libgame.so", "lib/README"]
        #expect(SplitSelector.nativeABIs(inAPKEntries: entries) == ["arm64-v8a", "armeabi-v7a"])
    }

    @Test func deviceSpecParsing() {
        let spec = DeviceSpec.parse(Fixtures.deviceSpecReply(abis: "arm64-v8a,armeabi-v7a", density: 320, locale: "pt-BR", sdk: 36)
            .components(separatedBy: "@@EMUU@@").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        #expect(spec.abis == ["arm64-v8a", "armeabi-v7a"])
        #expect(spec.density == 320)
        #expect(spec.languages == ["pt"])
        #expect(spec.sdkLevel == 36)
        let overridden = DeviceSpec.parse(["arm64-v8a", "Physical density: 320\nOverride density: 280", "320", "", "en-US", "35"])
        #expect(overridden.density == 280)
        #expect(overridden.languages == ["en"])
    }

    @Test func installOutputParsing() {
        #expect(InstallFailureCatalog.parse("Performing Streamed Install\nSuccess\n") == .success)
        #expect(InstallFailureCatalog.parse("Success: streamed 100 bytes\n") == .success)
        #expect(InstallFailureCatalog.parse("Failure [INSTALL_FAILED_NO_MATCHING_ABIS: Failed to extract native libraries, res=-113]")
                == .failure(code: "INSTALL_FAILED_NO_MATCHING_ABIS", detail: "Failed to extract native libraries, res=-113"))
        #expect(InstallFailureCatalog.parse("Failure [INSTALL_FAILED_ALREADY_EXISTS]") == .failure(code: "INSTALL_FAILED_ALREADY_EXISTS", detail: ""))
        #expect(InstallFailureCatalog.parse("adb: failed to install x.apk: INSTALL_PARSE_FAILED_NO_CERTIFICATES: No signature found")
                == .failure(code: "INSTALL_PARSE_FAILED_NO_CERTIFICATES", detail: "No signature found"))
        if case .failure(let code, let detail) = InstallFailureCatalog.parse("Error: Unable to open file: /x\n") {
            #expect(code == "INSTALL_ERROR")
            #expect(detail.contains("Unable to open file"))
        } else { Issue.record("expected failure") }
        let text = InstallFailureCatalog.explain(code: "INSTALL_FAILED_NO_MATCHING_ABIS", appABIs: ["x86"], deviceABIs: ["arm64-v8a"])
        #expect(text.contains("x86-only"))
        #expect(InstallFailureCatalog.explain(code: "INSTALL_FAILED_SOMETHING_NEW").contains("INSTALL_FAILED_SOMETHING_NEW"))
    }

    @Test func xapkManifest() throws {
        let m = try BundleManifest.parseXAPK(Data(#"""
        {"package_name":"com.a.b","version_code":"7","version_name":"1.0","split_apks":[{"file":"com.a.b.apk","id":"base"}],
         "expansions":[{"file":"Android/obb/com.a.b/main.7.com.a.b.obb","install_path":"Android/obb/com.a.b/main.7.com.a.b.obb"}]}
        """#.utf8))
        #expect(m.packageName == "com.a.b")
        #expect(m.versionCode == 7)
        #expect(m.apkFiles == ["com.a.b.apk"])
        #expect(APKInstaller.remoteExpansionPath(m.expansions[0], packageName: "com.a.b") == "/sdcard/Android/obb/com.a.b/main.7.com.a.b.obb")
        // An unsafe or odd install_path falls back to the canonical OBB dir.
        let odd = BundleManifest.Expansion(file: "data/main.obb", installPath: "../../system/x")
        #expect(APKInstaller.remoteExpansionPath(odd, packageName: "com.a.b") == "/sdcard/Android/obb/com.a.b/main.obb")
        // Regression: the bundle's package_name is untrusted and becomes part of the device path.
        let plain = BundleManifest.Expansion(file: "main.obb", installPath: "main.obb")
        #expect(APKInstaller.remoteExpansionPath(plain, packageName: "x/../../data/com.victim.app/files") == nil)
        #expect(APKInstaller.remoteExpansionPath(plain, packageName: "..") == nil)
        // An install_path into another package's OBB dir is not honoured.
        let other = BundleManifest.Expansion(file: "Android/obb/com.other/main.obb", installPath: "Android/obb/com.other/main.obb")
        #expect(APKInstaller.remoteExpansionPath(other, packageName: "com.a.b") == "/sdcard/Android/obb/com.a.b/main.obb")
        let dotted = BundleManifest.Expansion(file: "main.obb", installPath: "Android/obb/com.a.b/./x/main.obb")
        #expect(APKInstaller.remoteExpansionPath(dotted, packageName: "com.a.b") == "/sdcard/Android/obb/com.a.b/main.obb")
        #expect(throws: EmuuError.self) { _ = try BundleManifest.parseXAPK(Data("nope".utf8)) }
    }

    @Test func zipHelpers() {
        #expect(ZipTool.literalPattern("a[1]*?.apk") == "a[[]1][*][?].apk")
        #expect(ZipTool.isSafeEntryName("Android/obb/x/main.obb"))
        #expect(!ZipTool.isSafeEntryName("../evil"))
        #expect(!ZipTool.isSafeEntryName("a/../../evil"))
        #expect(!ZipTool.isSafeEntryName("/etc/passwd"))
    }

    @Test func zipToolRealUnzip() async throws {
        let dir = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try Fixtures.zip(["a[1].txt": Data("one".utf8), "sub/b.txt": Data("two".utf8)], to: dir.appendingPathComponent("t.zip"))
        let zip = ZipTool(runner: SystemProcessRunner())
        #expect(Set(try await zip.list(archive)) == ["a[1].txt", "sub/b.txt"])
        #expect(try await zip.read("a[1].txt", from: archive) == Data("one".utf8))
        #expect(try await zip.read("missing.txt", from: archive) == nil)
        let urls = try await zip.extract(["sub/b.txt", "a[1].txt"], from: archive, to: dir.appendingPathComponent("out"))
        #expect(try Data(contentsOf: urls[0]) == Data("two".utf8))
        #expect(try Data(contentsOf: urls[1]) == Data("one".utf8))
        await #expect(throws: EmuuError.self) { _ = try await zip.extract(["../x"], from: archive, to: dir) }
    }

    /// Regression: Info-ZIP restores symlink entries as symlinks, and the installer then pushed the link target
    /// (any host file) to the device. Symlink entries, and entries below one, are refused.
    @Test func zipToolRefusesSymlinkEntries() async throws {
        let dir = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src.appendingPathComponent("Android/obb/com.evil"), withIntermediateDirectories: true)
        let secret = dir.appendingPathComponent("secret.txt")
        try Data("host secret".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(atPath: src.appendingPathComponent("Android/obb/com.evil/main.1.com.evil.obb").path,
                                                   withDestinationPath: secret.path)
        try FileManager.default.createSymbolicLink(atPath: src.appendingPathComponent("linkdir").path, withDestinationPath: dir.path)
        try Data("apk".utf8).write(to: src.appendingPathComponent("base.apk"))
        let archive = dir.appendingPathComponent("evil.xapk")
        let made = try await SystemProcessRunner().run(ProcessRequest(
            executable: URL(fileURLWithPath: "/usr/bin/zip"),
            arguments: ["-y", "-q", "-r", archive.path, "base.apk", "Android", "linkdir"], workingDirectory: src, timeout: .seconds(30)))
        #expect(made.succeeded)
        let zip = ZipTool(runner: SystemProcessRunner())
        #expect(try await zip.symlinkEntries(archive) == ["Android/obb/com.evil/main.1.com.evil.obb", "linkdir"])
        let out = dir.appendingPathComponent("out")
        do {
            _ = try await zip.extract(["Android/obb/com.evil/main.1.com.evil.obb"], from: archive, to: out)
            Issue.record("symlink entry was extracted")
        } catch let e as EmuuError {
            guard case .install(let code, _) = e else { Issue.record("unexpected \(e)"); return }
            #expect(code == "EMUU_UNSAFE_ARCHIVE")
        }
        await #expect(throws: EmuuError.self) { _ = try await zip.extract(["linkdir/secret.txt"], from: archive, to: out) }
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("Android/obb/com.evil/main.1.com.evil.obb").path))
        // Plain entries of the same archive still extract.
        let ok = try await zip.extract(["base.apk"], from: archive, to: out)
        #expect(try Data(contentsOf: ok[0]) == Data("apk".utf8))
        // The post-extraction check alone also catches a link on disk.
        try FileManager.default.createSymbolicLink(atPath: out.appendingPathComponent("l.apk").path, withDestinationPath: secret.path)
        #expect(ZipTool.plainFileCheck("l.apk", in: out) == .notPlain)
        #expect(ZipTool.plainFileCheck("base.apk", in: out) == .ok)
        #expect(ZipTool.plainFileCheck("nope.apk", in: out) == .missing)
    }

    @Test func devicesListParsing() {
        let text = """
        List of devices attached
        emulator-5580          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:3
        0123456789ABCDEF       unauthorized usb:1-1 transport_id:4
        R58M12345              no permissions (missing udev rules? user is in the plugdev group); see [http://developer.android.com/tools/device.html] usb:1-2 transport_id:5

        """
        let d = ADBDevice.parseList(text)
        #expect(d.count == 3)
        #expect(d[0].state == .device && d[0].transportID == 3)
        #expect(d[1].state == .unauthorized)
        #expect(d[2].state == .noPermissions)
        #expect(d[2].transportID == 5)
    }

    @Test func getpropParsing() {
        let p = DeviceHelpers.parseGetprop("[ro.product.model]: [sdk_gphone64_arm64]\n[weird]: [a]: [b]\n[empty]: []\r\ngarbage\n")
        #expect(p["ro.product.model"] == "sdk_gphone64_arm64")
        #expect(p["weird"] == "a]: [b")
        #expect(p["empty"] == "")
        #expect(p.count == 3)
    }

    @Test func wireEncoding() throws {
        #expect(try ADBWire.request("host:version") == Data("000chost:version".utf8))
        #expect(throws: EmuuError.self) { _ = try ADBWire.request(String(repeating: "x", count: 70_000)) }
        #expect(ADBWire.parseHexLength(Data("001f".utf8)) == 31)
        #expect(ADBWire.syncPacket("QUIT", value: 0) == Data("QUIT".utf8) + Data([0, 0, 0, 0]))
        #expect(ADBWire.shellV2Packet(.closeStdin) == Data([4, 0, 0, 0, 0]))
    }
}

enum RealAPK {
    static var sdk: URL { SDKDiscovery.candidateRoots().first! }
    static var sample: URL? {
        let candidates = (try? FileManager.default.subpathsOfDirectory(atPath: sdk.appendingPathComponent("emulator/resources/skins").path)) ?? []
        return candidates.first(where: { $0.hasSuffix(".apk") }).map { sdk.appendingPathComponent("emulator/resources/skins").appendingPathComponent($0) }
    }
    static var aapt2: URL? {
        let bt = sdk.appendingPathComponent("build-tools")
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: bt.path)) ?? []).sorted()
        return versions.reversed().map { bt.appendingPathComponent($0).appendingPathComponent("aapt2") }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
