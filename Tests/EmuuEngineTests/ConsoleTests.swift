import Foundation
import Testing
import EmuuBase
@testable import EmuuEngine

@Suite struct ConsoleParserTests {
    // Verbatim greeting from engine 36.4.9.
    static let greeting = "Android Console: Authentication required\r\nAndroid Console: type 'auth <auth_token>' to authenticate\r\nAndroid Console: you can find your <auth_token> in \r\n'/Users/leslie/.emulator_console_auth_token'\r\nOK\r\n"

    @Test func greetingAndTokenPath() {
        var p = ConsoleResponseParser()
        guard case .ok(let text)? = p.feed(Self.greeting) else { Issue.record("no reply"); return }
        #expect(ConsoleResponseParser.tokenPath(inGreeting: text) == "/Users/leslie/.emulator_console_auth_token")
        #expect(ConsoleResponseParser.tokenPath(inGreeting: "Android Console: type 'help' for a list of commands") == nil)
        #expect(p.isEmpty)
    }

    @Test func splitChunksAndQueuedReplies() {
        var p = ConsoleResponseParser()
        #expect(p.feed("virtual device is ru") == nil)
        #expect(p.feed("nning\r\nOK\r\nvirtual device is stopped\r\nOK\r\n") == .ok("virtual device is running"))
        #expect(p.feed("") == .ok("virtual device is stopped"))
        #expect(p.isEmpty)
    }

    /// Regression: output lines that merely end in `OK` or start with `KO` (snapshot names are user-chosen)
    /// must not end a reply; that left the real `OK` buffered and shifted every later reply by one.
    @Test func onlyExactOKAndKOColonLinesTerminate() {
        var p = ConsoleResponseParser()
        #expect(p.feed("pre_OK\r\nOK\r\n") == .ok("pre_OK"))
        #expect(p.isEmpty)
        #expect(p.feed("ID        TAG\r\n--        KOALA     68M\r\nOK\r\n") == .ok("ID        TAG\n--        KOALA     68M"))
        #expect(p.isEmpty)
        #expect(p.feed("this text ends without a newline.OK\r\n") == nil)
        #expect(p.feed("OK\r\n") == .ok("this text ends without a newline.OK"))
        #expect(p.feed("KO\r\n") == .ko(message: "", output: ""))
    }

    @Test func koWithPrecedingOutput() {
        var p = ConsoleResponseParser()
        #expect(p.feed("available sub-commands:\r\n    stop\r\n\r\nKO:  bad sub-command\r\n") ==
                .ko(message: "bad sub-command", output: "available sub-commands:\n    stop"))
        #expect(p.feed("KO: QEMU support no longer available\r\n") == .ko(message: "QEMU support no longer available", output: ""))
    }

    @Test func snapshotListAndGetAndHeartbeat() {
        // Verbatim `avd snapshot list` from 36.4.9 with one snapshot.
        let list = "List of snapshots present on all disks:\nID        TAG                 VM SIZE                DATE       VM CLOCK\n--        default_boot            68M 2026-11-18 20:58:52   00:07:26.927\n--        emuu_it                 70M 2026-11-18 21:20:00   00:01:00.000"
        #expect(ConsoleParsing.snapshotNames(fromList: list) == ["default_boot", "emuu_it"])
        #expect(ConsoleParsing.snapshotNames(fromList: "There is no snapshot available.") == [])
        #expect(ConsoleParsing.loadedSnapshot(fromGet: "(null)") == nil)
        #expect(ConsoleParsing.loadedSnapshot(fromGet: "default_boot") == "default_boot")
        #expect(ConsoleParsing.heartbeat(from: "heartbeat: 7") == 7)
        #expect(ConsoleVMStatus(statusText: "virtual device is stopped") == .stopped)
        #expect(ConsoleVMStatus(statusText: "virtual device is running") == .running)
    }
}

@Suite struct ConsoleClientTests {
    @Test func authenticatesOnceAndReusesConnection() async throws {
        let fake = FakeConsole { cmd in
            switch cmd {
            case "ping": return .ok("I am alive!")
            case "avd status": return .ok("virtual device is stopped")
            default: return .ko("unknown command, try 'help'")
            }
        }
        let client = ConsoleClient(port: 5580, connector: fake, token: "secret")
        #expect(await client.ping())
        #expect(try await client.vmStatus() == .stopped)
        await #expect(throws: EmuuError.self) { try await client.send("bogus") }
        #expect(fake.commands == ["auth secret", "ping", "avd status", "bogus"])
        #expect(fake.connections == 1)
    }

    @Test func wrongTokenFails() async {
        let fake = FakeConsole(token: "right")
        let client = ConsoleClient(port: 5580, connector: fake, token: "wrong")
        await #expect { try await client.send("ping") } throws: { error in
            guard case .console(let msg) = error as? EmuuError else { return false }
            return msg.contains("authentication failed")
        }
    }

    @Test func readsTokenFromFileWhenNoOverride() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokenFile = dir.appendingPathComponent("token")
        try "secret\n".write(to: tokenFile, atomically: true, encoding: .utf8)
        // A console without auth never needs the token.
        let open = FakeConsole(requireAuth: false) { _ in .ok("I am alive!") }
        #expect(await ConsoleClient(port: 5580, connector: open, tokenFile: tokenFile).ping())
        #expect(open.commands == ["ping"])
        // With auth, the file named in the greeting wins over the fallback; the fake names a missing file.
        let authed = FakeConsole(token: "secret") { _ in .ok("I am alive!") }
        let client = ConsoleClient(port: 5580, connector: authed, tokenFile: tokenFile)
        await #expect { try await client.send("ping") } throws: { error in
            guard case .console(let msg) = error as? EmuuError else { return false }
            return msg.contains("/nonexistent/.emulator_console_auth_token")
        }
    }

    @Test func reconnectsOnceAfterDrop() async throws {
        let drops = Locked(1)
        let fake = FakeConsole { cmd in
            if cmd == "avd name" {
                let drop = drops.withLock { n -> Bool in defer { n -= 1 }; return n > 0 }
                return drop ? .close : .ok("emuu-dev")
            }
            return .ok("")
        }
        let client = ConsoleClient(port: 5580, connector: fake, token: "secret")
        #expect(try await client.avdName() == "emuu-dev")
        #expect(fake.connections == 2)
    }

    @Test func killToleratesClose() async throws {
        let fake = FakeConsole { $0 == "kill" ? .okThenClose("OK: killing emulator, bye bye") : .ok("") }
        let client = ConsoleClient(port: 5580, connector: fake, token: "secret")
        try await client.kill()
        let fake2 = FakeConsole { $0 == "kill" ? .close : .ok("") }
        try await ConsoleClient(port: 5580, connector: fake2, token: "secret").kill()
    }

    @Test func silentEngineTimesOut() async {
        let fake = FakeConsole { _ in .silence }
        let client = ConsoleClient(port: 5580, connector: fake, token: "secret")
        let start = ContinuousClock.now
        await #expect(throws: EmuuError.self) { try await client.send("avd status", timeout: .milliseconds(200)) }
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func refusedConnectionIsConsoleError() async {
        let fake = FakeConsole()
        fake.refuseConnections(true)
        let client = ConsoleClient(port: 5580, connector: fake, token: "secret")
        #expect(await client.ping() == false)
    }

    @Test func snapshotNamesAreValidated() async {
        let client = ConsoleClient(port: 5580, connector: FakeConsole(), token: "secret")
        await #expect(throws: EmuuError.self) { try await client.snapshotSave("bad name; kill") }
    }

    @Test func realTCPTransportAgainstLocalServer() async throws {
        // A one-shot local TCP server speaking the console protocol, to exercise TCPConsoleTransport.
        let server = try LocalLineServer { line in
            line.hasPrefix("auth ") ? "Android Console: type 'help' for a list of commands\r\nOK\r\n" : "I am alive!\r\nOK\r\n"
        }
        defer { server.stop() }
        let client = ConsoleClient(port: server.port, token: "t")
        #expect(await client.ping())
        #expect(await client.ping())
    }
}

/// Minimal blocking TCP server on 127.0.0.1 for transport tests: sends the auth greeting, then answers
/// each received line with `reply(line)`.
final class LocalLineServer: @unchecked Sendable {
    let port: Int
    private let fd: Int32
    private let thread: Thread

    init(reply: @escaping @Sendable (String) -> String) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(fd, 4)
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        self.fd = fd
        self.port = Int(UInt16(bigEndian: bound.sin_port))
        thread = Thread {
            let c = accept(fd, nil, nil)
            guard c >= 0 else { return }
            let greeting = "Android Console: Authentication required\r\nAndroid Console: type 'auth <auth_token>' to authenticate\r\n'/tmp/x'\r\nOK\r\n"
            _ = greeting.withCString { send(c, $0, strlen($0), 0) }
            var pending = ""
            var buf = [UInt8](repeating: 0, count: 1024)
            while true {
                let n = recv(c, &buf, buf.count, 0)
                if n <= 0 { break }
                pending += String(decoding: buf[0..<n], as: UTF8.self)
                while let r = pending.range(of: "\r\n") {
                    let line = String(pending[..<r.lowerBound])
                    pending.removeSubrange(..<r.upperBound)
                    let out = reply(line)
                    _ = out.withCString { send(c, $0, strlen($0), 0) }
                }
            }
            close(c)
        }
        thread.start()
    }

    func stop() { close(fd) }
}

@Suite struct CommandLineTests {
    @Test func headlessArgumentsFromConfig() throws {
        var config = InstancePreset.standard.makeConfig(id: InstanceID(rawValue: "emuu-dev")!)
        config.videoDecoder = .hardware   // the engine default: no decoder flags
        let ports = try InstancePorts(console: 5580)
        var args = EngineCommandLine.arguments(for: config, ports: ports, options: EngineLaunchOptions(), videoDecoder: .hardware)
        #expect(args == ["-avd", "emuu-dev", "-no-window", "-no-boot-anim", "-ports", "5580,5581", "-gpu", "host",
                         "-memory", "2048", "-cores", "4", "-no-metrics", "-netfast"])
        config.audioOutput = false
        args = EngineCommandLine.arguments(for: config, ports: ports,
                                           options: EngineLaunchOptions(coldBoot: true, netfast: false, extraArguments: ["-no-sim"], qemuArguments: ["-device", "x"]),
                                           videoDecoder: .hardware)
        #expect(args.suffix(6) == ["-no-audio", "-no-snapshot-load", "-no-sim", "-qemu", "-device", "x"])
        #expect(!args.contains("-netfast"))
        #expect(EngineCommandLine.consolePort(fromArguments: args) == 5580)
        #expect(EngineCommandLine.consolePort(fromArguments: ["-avd", "x", "-port", "5600"]) == 5600)
        #expect(EngineCommandLine.consolePort(fromArguments: ["-avd", "x"]) == nil)
    }

    @Test func grpcDisplayServiceOnLoopbackWithToken() throws {
        let config = InstancePreset.lite.makeConfig(id: InstanceID(rawValue: "emuu-dev")!)
        let ports = try InstancePorts(console: 5584)
        let args = EngineCommandLine.arguments(for: config, ports: ports, grpcPort: 8584, options: EngineLaunchOptions())
        let i = try #require(args.firstIndex(of: "-grpc"))
        #expect(args[i + 1] == "8584")
        #expect(args[i + 2] == "-grpc-use-token")
        #expect(!args.contains("-grpc-use-jwt"))
        // console + 3000 when free, else the first free port in 8554…8999.
        #expect(PortAllocator.grpcPort(for: ports, isFree: { _ in true }) == 8584)
        #expect(PortAllocator.grpcPort(for: ports, isFree: { $0 != 8584 && $0 != 8554 }) == 8555)
        #expect(PortAllocator.grpcPort(for: ports, isFree: { _ in false }) == nil)
    }

    @Test func environmentPointsAtEmuuAVDHomeOnly() throws {
        let w = try TempWorld()
        let env = EngineCommandLine.environment(paths: w.paths, sdk: w.sdk)
        #expect(env["ANDROID_AVD_HOME"] == w.paths.avdHome.path)
        #expect(env["ANDROID_SDK_ROOT"] == w.sdk.root.path)
        #expect(!env.values.contains { $0.contains("/.android") })
    }

    @Test func videoDecoderModesMapToEngineFlagsAndEnvironment() throws {
        let w = try TempWorld()
        let config = InstancePreset.standard.makeConfig(id: InstanceID(rawValue: "vd")!)
        let ports = try InstancePorts(console: 5570)
        func args(_ m: VideoDecoderMode) -> [String] {
            EngineCommandLine.arguments(for: config, ports: ports, options: EngineLaunchOptions(extraArguments: ["-x"]), videoDecoder: m)
        }
        // Guest software codecs: the engine feature that registers the goldfish (host) codecs is turned off,
        // before any extra arguments.
        #expect(Array(args(.software).suffix(3)) == ["-feature", "-HardwareDecoder", "-x"])
        #expect(!args(.hardware).contains("-feature") && !args(.hostSoftware).contains("-feature"))
        #expect(args(.auto) == args(VideoDecoderMode.resolvedDefault))
        // Host decoding: VideoToolbox on/off through the engine's own variable ("0" is the only value that disables it).
        #expect(EngineCommandLine.environment(paths: w.paths, sdk: w.sdk, videoDecoder: .hostSoftware)["ANDROID_EMU_MEDIA_DECODER_VTB"] == "0")
        #expect(EngineCommandLine.environment(paths: w.paths, sdk: w.sdk, videoDecoder: .hardware)["ANDROID_EMU_MEDIA_DECODER_VTB"] == "1")
        #expect(EngineCommandLine.environment(paths: w.paths, sdk: w.sdk)["ANDROID_EMU_MEDIA_DECODER_VTB"] == nil)
    }

    @Test func decoderChangeColdBootsOnceAndClonesKeepTheGoldenSnapshot() {
        typealias E = EngineInstance
        // No snapshot or an explicit cold boot: launch as asked.
        #expect(E.videoDecoderPlan(desired: .software, snapshotCodecs: nil, hasQuickBootSnapshot: false, coldBoot: false, isClone: false) == (.software, false, nil))
        // A snapshot from before the setting (no marker) has host codecs: switching to software cold-boots once…
        let legacy = E.videoDecoderPlan(desired: .software, snapshotCodecs: nil, hasQuickBootSnapshot: true, coldBoot: false, isClone: false)
        #expect(legacy.mode == .software && legacy.coldBoot && legacy.note != nil)
        // …and the next start (marker now "guest") quick-boots.
        #expect(E.videoDecoderPlan(desired: .software, snapshotCodecs: .guest, hasQuickBootSnapshot: true, coldBoot: false, isClone: false) == (.software, false, nil))
        // Hardware ↔ host-software share the guest codecs: no cold boot. `auto` resolves first.
        #expect(E.videoDecoderPlan(desired: .hostSoftware, snapshotCodecs: .host, hasQuickBootSnapshot: true, coldBoot: false, isClone: false) == (.hostSoftware, false, nil))
        #expect(E.videoDecoderPlan(desired: .auto, snapshotCodecs: nil, hasQuickBootSnapshot: false, coldBoot: false, isClone: false).mode == VideoDecoderMode.resolvedDefault)
        // Back to hardware from a guest-codec snapshot also cold-boots.
        #expect(E.videoDecoderPlan(desired: .hardware, snapshotCodecs: .guest, hasQuickBootSnapshot: true, coldBoot: false, isClone: false).coldBoot)
        // A farm clone never saves, so it keeps the golden's codecs instead of cold-booting on every start.
        let clone = E.videoDecoderPlan(desired: .software, snapshotCodecs: nil, hasQuickBootSnapshot: true, coldBoot: false, isClone: true)
        #expect(clone.mode == .hardware && !clone.coldBoot && clone.note?.contains("re-seal") == true)
    }

    @Test func guestCodecsMarkerRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(EngineInstance.readGuestCodecsMarker(dir) == nil)
        EngineInstance.writeGuestCodecsMarker(dir, .guest)
        #expect(EngineInstance.readGuestCodecsMarker(dir) == .guest)
        EngineInstance.writeGuestCodecsMarker(dir, .host)
        #expect(EngineInstance.readGuestCodecsMarker(dir) == .host)
        #expect(!EngineInstance.hasQuickBootSnapshot(dir.appendingPathComponent("snapshots")))
    }

    @Test func portAllocatorSkipsBusyPairs() {
        let busy: Set<Int> = [5554, 5557, 5560]
        let pair = PortAllocator.firstFreePair(isFree: { !busy.contains($0) })
        #expect(pair?.console == 5558)
        #expect(PortAllocator.firstFreePair(isFree: { _ in false }) == nil)
        #expect(PortAllocator.firstFreePair(isFree: { _ in true }, excluding: [5554])?.console == 5556)
    }
}

/// A transport that delivers everything buffered so far in one chunk, after a delay: the shape that made
/// unserialized concurrent commands steal each other's replies.
final class CoalescingConsoleTransport: ConsoleTransport, @unchecked Sendable {
    private let buffer = Locked("Android Console: type 'help' for a list of commands\r\nOK\r\n")
    let sent = Locked<[String]>([])

    func send(_ data: Data) async throws {
        let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        sent.withLock { $0.append(line) }
        let reply = line == "avd status" ? "virtual device is running\r\nOK\r\n" : "OK\r\n"
        buffer.withLock { $0 += reply }
    }

    func receive(timeout: Duration) async throws -> Data? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            let chunk = buffer.withLock { b -> String in defer { b = "" }; return b }
            if !chunk.isEmpty { return Data(chunk.utf8) }
        }
        throw EmuuError.console("no reply within \(timeout)")
    }

    func close() {}
}

struct CoalescingConnector: ConsoleConnector {
    let transport: CoalescingConsoleTransport
    let connects = Locked(0)
    func connect(port: Int, timeout: Duration) async throws -> any ConsoleTransport {
        connects.withLock { $0 += 1 }
        try await Task.sleep(for: .milliseconds(10))
        return transport
    }
}

@Suite struct ConsoleSerializationTests {
    /// Regression: `avd status` and `avd start` issued concurrently on one client. Without explicit
    /// serialization both were written before either reply was read; the first reader consumed both replies
    /// and the second timed out ("no reply"), and a first use opened two connections.
    @Test func concurrentCommandsDoNotInterleave() async throws {
        let transport = CoalescingConsoleTransport()
        let connector = CoalescingConnector(transport: transport)
        let client = ConsoleClient(port: 5580, connector: connector, token: "secret", defaultTimeout: .seconds(1))
        async let status = client.vmStatus()
        async let start: Void = client.avdStart()
        async let status2 = client.send("avd status")
        let (s, _, s2) = try await (status, start, status2)
        #expect(s == .running)
        #expect(s2 == "virtual device is running")
        #expect(connector.connects.current == 1)
        #expect(transport.sent.current.count == 3)
    }
}
