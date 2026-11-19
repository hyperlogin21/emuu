import Foundation
import Testing
import EmuuBase
import EmuuTestSupport
@testable import EmuuADB

let testSerial = DeviceSerial.emulator(consolePort: 5580)
let fakeADB = URL(fileURLWithPath: "/fake/sdk/platform-tools/adb")

func makeClient(_ fake: FakeADBServer, runner: FakeProcessRunner = FakeProcessRunner(), transport: ADBClient.Transport = .automatic) -> ADBClient {
    let server = ADBServer(endpoint: ADBServerEndpoint(port: fake.port), adbExecutable: fakeADB, runner: runner, connectTimeout: .seconds(2))
    return ADBClient(serial: testSerial, server: server, transport: transport)
}

@Suite("ADB smart-socket client")
struct ADBClientTests {
    @Test func hostVersionDevicesFeatures() async throws {
        let fake = try FakeADBServer()
        let server = ADBServer(endpoint: ADBServerEndpoint(port: fake.port), adbExecutable: fakeADB, runner: FakeProcessRunner())
        #expect(try await server.version() == 41)
        fake.setDevices([("emulator-5580", "device"), ("emulator-5554", "offline")])
        let devices = try await server.devices()
        #expect(devices.count == 2)
        #expect(devices[0].serial == "emulator-5580")
        #expect(devices[0].state == .device)
        #expect(devices[0].model == "sdk_gphone64_arm64")
        #expect(devices[0].transportID == 1)
        #expect(devices[1].state == .offline)
        #expect(try await server.state(of: testSerial) == .device)
        let features = try await server.features(of: testSerial)
        #expect(features.contains("shell_v2"))
        await #expect(throws: EmuuError.deviceNotReady(DeviceSerial(rawValue: "emulator-9999"))) {
            _ = try await server.features(of: DeviceSerial(rawValue: "emulator-9999"))
        }
    }

    @Test func shellV2SeparatesStreamsAndExitCode() async throws {
        let fake = try FakeADBServer()
        fake.onShell { cmd in
            if cmd == "cat /proc/meminfo" { return .init(stdout: "MemTotal: 2000000 kB\n", stderr: "warn\n", exit: 0) }
            return .init(stderr: "no\n", exit: 3)
        }
        let client = makeClient(fake)
        let r = try await client.shell("cat /proc/meminfo", timeout: .seconds(5))
        #expect(r.succeeded)
        #expect(r.stdoutString == "MemTotal: 2000000 kB\n")
        #expect(r.stderrString == "warn\n")
        #expect(r.request.arguments == ["-s", "emulator-5580", "shell", "cat /proc/meminfo"])
        let bad = try await client.shell("false", timeout: .seconds(5))
        #expect(bad.exitCode == 3)
        #expect(throws: EmuuError.self) { try bad.checked() }
        #expect(try await client.shellOutput("cat /proc/meminfo") == "MemTotal: 2000000 kB")
        #expect(fake.requests.contains("host:transport:emulator-5580"))
        #expect(fake.requests.contains("shell,v2,raw:cat /proc/meminfo"))
    }

    @Test func shellTimeoutThrowsProcessTimedOut() async throws {
        let fake = try FakeADBServer()
        fake.onShell { _ in .init(stdout: "late", delay: 2) }
        let client = makeClient(fake)
        let start = ContinuousClock.now
        await #expect {
            _ = try await client.shell("sleep 10", timeout: .milliseconds(300))
        } throws: { error in
            if case EmuuError.processTimedOut = error { return true }
            return false
        }
        #expect(ContinuousClock.now - start < .seconds(1.5))
    }

    @Test func cancellationAbortsBlockedShell() async throws {
        let fake = try FakeADBServer()
        fake.onShell { _ in .init(stdout: "late", delay: 3) }
        let client = makeClient(fake)
        let start = ContinuousClock.now
        let task = Task { try await client.shell("sleep 10", timeout: nil) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(ContinuousClock.now - start < .seconds(1.5))
    }

    @Test func missingDeviceThrowsDeviceNotReady() async throws {
        let fake = try FakeADBServer()
        fake.setDevices([])
        let client = makeClient(fake)
        await #expect(throws: EmuuError.deviceNotReady(testSerial)) {
            _ = try await client.shell("true", timeout: .seconds(5))
        }
        fake.setDevices([("emulator-5580", "offline")])
        await #expect(throws: EmuuError.deviceNotReady(testSerial)) {
            _ = try await client.shell("true", timeout: .seconds(5))
        }
    }

    @Test func fallsBackToBinaryWithoutShellV2() async throws {
        let fake = try FakeADBServer()
        fake.setShellV2Supported(false)
        let runner = FakeProcessRunner()
        runner.on(executable: "adb", arguments: ["-s", "emulator-5580", "shell", "getprop ro.build.version.sdk"], respond: .success("36\n"))
        let client = makeClient(fake, runner: runner)
        #expect(try await client.getprop("ro.build.version.sdk") == "36")
        // Second call goes straight to the binary (no repeated native attempt).
        #expect(try await client.getprop("ro.build.version.sdk") == "36")
        #expect(runner.invocations.count == 2)
        #expect(fake.requests.filter { $0.hasPrefix("shell,v2") }.count == 1)
    }

    @Test func binaryTransportMapsDeviceErrors() async throws {
        let fake = try FakeADBServer()
        let runner = FakeProcessRunner()
        runner.on(executable: "adb", argumentsPrefix: ["-s", "emulator-5580", "shell"], respond: .failure(1, stderr: "adb: device 'emulator-5580' not found\n"))
        let client = makeClient(fake, runner: runner, transport: .binary)
        await #expect(throws: EmuuError.deviceNotReady(testSerial)) {
            _ = try await client.shell("true", timeout: .seconds(5))
        }
        runner.on(executable: "adb", argumentsPrefix: ["-s", "emulator-5580", "forward"], respond: .success("27183\n"))
        #expect(try await client.adb(["forward", "tcp:0", "localabstract:scrcpy"], timeout: .seconds(5)).trimmedStdout == "27183")
    }

    @Test func pushPullStatRoundTrip() async throws {
        let fake = try FakeADBServer()
        let client = makeClient(fake)
        let dir = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let local = dir.appendingPathComponent("blob.bin")
        let payload = Data((0..<(300 * 1024 + 17)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try payload.write(to: local)
        let seen = Locked<[TransferProgress]>([])
        try await client.push(local, to: "/sdcard/Android/obb/com.game/main.1.com.game.obb", permissions: 0o644) { p in seen.withLock { $0.append(p) } }
        #expect(fake.files["/sdcard/Android/obb/com.game/main.1.com.game.obb"] == payload)
        #expect(fake.pushModes["/sdcard/Android/obb/com.game/main.1.com.game.obb"] == 0o100644)
        #expect(seen.current.last?.bytesTransferred == UInt64(payload.count))
        #expect(seen.current.last?.fraction == 1)

        let st = try await client.stat("/sdcard/Android/obb/com.game/main.1.com.game.obb")
        #expect(st.exists && st.isRegularFile && st.size == UInt32(payload.count))
        #expect(try await client.stat("/nope").exists == false)

        let back = dir.appendingPathComponent("back.bin")
        try await client.pull("/sdcard/Android/obb/com.game/main.1.com.game.obb", to: back)
        #expect(try Data(contentsOf: back) == payload)

        await #expect(throws: EmuuError.self) { try await client.pull("/missing", to: dir.appendingPathComponent("x")) }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("x").path))

        fake.failPush(to: "/sdcard/full")
        await #expect {
            try await client.push(local, to: "/sdcard/full")
        } throws: { error in
            guard case EmuuError.adb(let m) = error else { return false }
            return m.contains("No space left on device")
        }
    }

    @Test func execOutIsBinarySafe() async throws {
        let fake = try FakeADBServer()
        let png = DeviceHelpers.pngSignature + Data([0x00, 0x0D, 0x0A, 0xFF, 0x0A, 0x00])
        fake.onExec { cmd, _ in cmd == "screencap -p" ? png : Data() }
        let client = makeClient(fake)
        #expect(try await DeviceHelpers(client: client).screenshotPNG() == png)
        fake.onExec { _, _ in Data("error: no display\n".utf8) }
        await #expect(throws: EmuuError.self) { _ = try await DeviceHelpers(client: client).screenshotPNG() }
    }

    @Test func execStreamingUploadsExactBytes() async throws {
        let fake = try FakeADBServer()
        let received = Locked(Data())
        fake.onExec { cmd, conn in
            guard let r = cmd.range(of: "-S ") else { return Data("bad".utf8) }
            let size = Int(cmd[r.upperBound...].prefix(while: { $0.isNumber }))!
            received.set(conn.readExactly(size) ?? Data())
            return Data("Success\n".utf8)
        }
        let client = makeClient(fake)
        let dir = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("big.apk")
        let payload = Data((0..<(3 * 1024 * 1024 + 5)).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        try payload.write(to: file)
        let calls = Locked(0)
        let out = try await client.execStreaming("cmd package install -S \(payload.count)", uploading: file) { _ in calls.withLock { $0 += 1 } }
        #expect(out == "Success\n")
        #expect(received.current == payload)
        #expect(calls.current >= 3 && calls.current <= 6)  // throttled to ~1 MiB steps
    }

    @Test func startsServerWhenRefused() async throws {
        // Reserve a free port, then release it so nothing listens there.
        let probe = try FakeADBServer()
        let port = probe.port
        probe.stop()
        let started = Locked<FakeADBServer?>(nil)
        let runner = FakeProcessRunner()
        runner.on(executable: "adb", arguments: ["start-server"], respond: .handler { req in
            #expect(req.environment["ANDROID_ADB_SERVER_PORT"] == String(port))
            started.set(try FakeADBServer(port: port))
            return ProcessResult(request: req, termination: .exited(code: 0))
        })
        let server = ADBServer(endpoint: ADBServerEndpoint(port: port), adbExecutable: fakeADB, runner: runner)
        #expect(try await server.version() == 41)
        #expect(runner.commandLines == [["adb", "start-server"]])
        started.current?.stop()
    }

    @Test func manyConcurrentShellsAreIndependent() async throws {
        let fake = try FakeADBServer()
        fake.onShell { cmd in .init(stdout: cmd.uppercased(), exit: 0) }
        let client = makeClient(fake)
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for i in 0..<40 {
                group.addTask { try await client.shell("echo \(i)", timeout: .seconds(5)).stdoutString == "ECHO \(i)" }
            }
            for try await ok in group { #expect(ok) }
        }
        #expect(fake.connectionCount == 40)
    }

    @Test func waitForDevicePolls() async throws {
        let fake = try FakeADBServer()
        fake.setDevices([("emulator-5580", "offline")])
        let server = ADBServer(endpoint: ADBServerEndpoint(port: fake.port), adbExecutable: fakeADB, runner: FakeProcessRunner())
        _ = Task {
            try await Task.sleep(for: .milliseconds(150))
            fake.setDevices([("emulator-5580", "device")])
        }
        let dev = try await server.waitForDevice(testSerial, timeout: .seconds(3), pollInterval: .milliseconds(50))
        #expect(dev.state == .device)
        fake.setDevices([])
        await #expect(throws: EmuuError.deviceNotReady(testSerial)) {
            try await server.waitForDevice(testSerial, timeout: .milliseconds(200), pollInterval: .milliseconds(50))
        }
    }
}
