import Foundation
import Testing
import EmuuBase
import EmuuTestSupport
@testable import EmuuADB

/// Opt-in checks against the real adb server / a real emulator. Enable with:
/// - `EMUU_REAL_ADB=1`: talk to the running adb server on 127.0.0.1:5037 (no device needed).
/// - `EMUU_REAL_DEVICE=emulator-5580`: also run device checks (non-destructive; installs and then
///   uninstalls the probe package `dev.emuu.probe`, and removes the OBB/tmp files it creates).
/// - `EMUU_PROBE_DIR=<dir with base.apk and fr.apk>`: signed probe APKs built with the SDK build-tools.
enum RealEnv {
    static let env = ProcessInfo.processInfo.environment
    static var adbEnabled: Bool { env["EMUU_REAL_ADB"] == "1" || deviceSerial != nil }
    static var deviceSerial: DeviceSerial? { env["EMUU_REAL_DEVICE"].map(DeviceSerial.init(rawValue:)) }
    static var probeDir: URL? { env["EMUU_PROBE_DIR"].map { URL(fileURLWithPath: $0) } }
    static let probePackage = "dev.emuu.probe"
}

@Suite("Real adb server", .enabled(if: RealEnv.adbEnabled), .serialized)
struct RealADBServerTests {
    @Test func versionAndDevicesMatchBinary() async throws {
        let server = ADBServer()
        let version = try await server.version()
        let binary = try await SystemProcessRunner().run(ProcessRequest(executable: try ADBLocator.require(), arguments: ["version"], timeout: .seconds(10)))
        print("[real] host:version = \(version); adb version: \(binary.stdoutString.split(separator: "\n").first ?? "")")
        #expect(binary.stdoutString.contains("1.0.\(version)"))
        let ours = try await server.devices()
        let theirs = try await SystemProcessRunner().run(ProcessRequest(executable: try ADBLocator.require(), arguments: ["devices", "-l"], timeout: .seconds(10)))
        print("[real] devices = \(ours.map { "\($0.serial) \($0.state.rawValue)" })")
        #expect(ours.map(\.serial).sorted() == ADBDevice.parseList(theirs.stdoutString).map(\.serial).sorted())
    }
}

@Suite("Real device", .enabled(if: RealEnv.deviceSerial != nil), .serialized)
struct RealDeviceTests {
    let client = ADBClient(serial: RealEnv.deviceSerial ?? testSerial)

    @Test func shellBasics() async throws {
        let features = try await client.server.features(of: client.serial)
        print("[real] features: \(features.sorted().joined(separator: ","))")
        let r = try await client.shell("echo out; echo err >&2; exit 7", timeout: .seconds(10))
        #expect(r.stdoutString == "out\n")
        #expect(r.stderrString == "err\n")
        #expect(r.exitCode == 7)
        let clock = ContinuousClock()
        var durations: [Duration] = []
        for _ in 0..<20 {
            let t = clock.now
            _ = try await client.shell("cat /proc/meminfo", timeout: .seconds(10))
            durations.append(clock.now - t)
        }
        durations.sort()
        print("[real] native shell `cat /proc/meminfo` x20: median \(durations[10]), max \(durations[19])")
        let binaryClient = ADBClient(serial: client.serial, transport: .binary)
        let t = clock.now
        for _ in 0..<5 { _ = try await binaryClient.shell("cat /proc/meminfo", timeout: .seconds(10)) }
        print("[real] adb binary shell x5: avg \((clock.now - t) / 5)")
        let spec = try await DeviceSpec.query(client)
        print("[real] device spec: \(spec)")
        #expect(!spec.abis.isEmpty)
    }

    @Test func helpersAndPlayStore() async throws {
        let helpers = DeviceHelpers(client: client)
        let png = try await helpers.screenshotPNG()
        print("[real] screenshot: \(png.count) bytes PNG")
        #expect(png.starts(with: DeviceHelpers.pngSignature))
        let summary = try await helpers.summary()
        print("[real] summary: \(summary)")
        let status = try await PlayStore(shell: client).status()
        print("[real] play store: \(status)")
        #expect(status.storeInstalled)
        let account = try await PlayStore(shell: client).accountState()
        print("[real] account state: \(account)")
        let clipHelp = try await client.shell("cmd clipboard help 2>&1", timeout: .seconds(10)).stdoutString
        print("[real] cmd clipboard help: \(clipHelp.prefix(400))")
        let am = try await client.shell("am help 2>&1 | grep -A3 send-trim-memory", timeout: .seconds(10)).stdoutString
        print("[real] am send-trim-memory help: \(am)")
        let pmHelp = try await client.shell("pm help 2>&1 | grep -E 'bypass-low-target-sdk-block|install-write' | head -5", timeout: .seconds(10)).stdoutString
        print("[real] pm help: \(pmHelp)")
    }

    @Test func pushStatPull() async throws {
        let dir = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let local = dir.appendingPathComponent("blob.bin")
        let payload = Data((0..<(8 * 1024 * 1024 + 3)).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) })
        try payload.write(to: local)
        let remote = "/data/local/tmp/emuu-probe-blob.bin"
        let t = ContinuousClock.now
        try await client.push(local, to: remote)
        print("[real] pushed 8 MiB in \(ContinuousClock.now - t)")
        let st = try await client.stat(remote)
        #expect(st.size == UInt32(payload.count))
        let back = dir.appendingPathComponent("back.bin")
        try await client.pull(remote, to: back)
        #expect(try Data(contentsOf: back) == payload)
        let sum = try await client.shellOutput("md5sum \(remote) | cut -d' ' -f1")
        print("[real] device md5 \(sum)")
        _ = try await client.shell("rm -f \(remote)", timeout: .seconds(10))
    }

    @Test(.enabled(if: RealEnv.probeDir != nil)) func installLaunchUninstallProbe() async throws {
        let probe = RealEnv.probeDir!
        let pm = PackageManager(shell: client)
        _ = try? await pm.uninstall(RealEnv.probePackage)
        let cache = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: cache) }
        let installer = APKInstaller(client: client, cacheDirectory: cache)

        // 1. Single APK, streamed.
        let r1 = try await installer.install(.apk(probe.appendingPathComponent("base.apk")))
        print("[real] single apk: \(r1.status) pkg=\(r1.packageName ?? "-") in \(r1.duration)")
        #expect(r1.status == .installed)
        #expect(r1.packageName == RealEnv.probePackage)
        let listed = try await pm.listPackages()
        let mine = listed.first { $0.info.packageName == RealEnv.probePackage }
        print("[real] listed: \(String(describing: mine))")
        #expect(mine?.info.versionName == "0.3-probe")
        #expect(mine?.info.versionCode == 3)
        print("[real] launcher activity: \(String(describing: try await pm.launcherActivity(of: RealEnv.probePackage)))")
        try await pm.launch(RealEnv.probePackage)
        try await Task.sleep(for: .seconds(1))
        try await pm.forceStop(RealEnv.probePackage)

        // 2. Split set (base + config.fr) through a PackageManager session.
        let r2 = try await installer.install(.splitAPKs([probe.appendingPathComponent("base.apk"), probe.appendingPathComponent("fr.apk")]))
        print("[real] split set: \(r2.status) apks=\(r2.apkCount)")
        #expect(r2.status == .installed)
        let paths = try await pm.apkPaths(of: RealEnv.probePackage)
        print("[real] pm path: \(paths)")
        #expect(paths.count == 2)

        // 3. XAPK with OBB.
        let dir = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let obb = Data((0..<(3 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 5) })
        let obbPath = "Android/obb/\(RealEnv.probePackage)/main.3.\(RealEnv.probePackage).obb"
        let manifestJSON = """
        {"xapk_version":2,"package_name":"\(RealEnv.probePackage)","version_code":"3","split_apks":[{"file":"\(RealEnv.probePackage).apk","id":"base"},{"file":"config.fr.apk","id":"config.fr"}],
         "expansions":[{"file":"\(obbPath)","install_location":"EXTERNAL_STORAGE","install_path":"\(obbPath)"}]}
        """
        let xapk = try Fixtures.zip([
            "manifest.json": Data(manifestJSON.utf8),
            "\(RealEnv.probePackage).apk": try Data(contentsOf: probe.appendingPathComponent("base.apk")),
            "config.fr.apk": try Data(contentsOf: probe.appendingPathComponent("fr.apk")),
            obbPath: obb,
        ], to: dir.appendingPathComponent("probe.xapk"))
        let r3 = try await installer.install(file: xapk)
        print("[real] xapk: \(r3.status) apks=\(r3.apkCount) obbs=\(r3.obbCount) in \(r3.duration)")
        #expect(r3.status == .installed)
        let remoteOBB = "/sdcard/\(obbPath)"
        let st = try await client.stat(remoteOBB)
        print("[real] obb on device: exists=\(st.exists) size=\(st.size)")
        #expect(st.size == UInt32(obb.count))

        // 4. Uninstall and clean up.
        #expect(try await pm.uninstall(RealEnv.probePackage))
        _ = try await client.shell("rm -rf /sdcard/Android/obb/\(RealEnv.probePackage)", timeout: .seconds(10))
        #expect(try await pm.isInstalled(RealEnv.probePackage) == false)
    }
}

@Suite("Real probe APKs", .enabled(if: RealEnv.probeDir != nil))
struct RealProbeAPKTests {
    @Test func realManifestsParse() async throws {
        let zip = ZipTool(runner: SystemProcessRunner())
        let base = try APKManifest.parse(binaryXML: try #require(try await zip.read("AndroidManifest.xml", from: RealEnv.probeDir!.appendingPathComponent("base.apk"))))
        let fr = try APKManifest.parse(binaryXML: try #require(try await zip.read("AndroidManifest.xml", from: RealEnv.probeDir!.appendingPathComponent("fr.apk"))))
        #expect(base == APKManifest(packageName: "dev.emuu.probe", versionCode: 3, versionName: "0.3-probe", minSdkVersion: 24, targetSdkVersion: 36))
        #expect(fr.splitName == "config.fr")
    }
}
