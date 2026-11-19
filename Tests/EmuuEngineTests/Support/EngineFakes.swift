import Darwin
import Foundation
import EmuuBase
import EmuuTestSupport
@testable import EmuuEngine

/// Temporary `EmuuPaths` + fake SDK tree, removed on deinit.
final class TempWorld: @unchecked Sendable {
    let root: URL
    let paths: EmuuPaths
    let sdk: AndroidSDK

    init(withPlayStoreImage: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("emuu-engine-tests-\(UUID().uuidString)", isDirectory: true)
        paths = EmuuPaths(root: root.appendingPathComponent("home", isDirectory: true))
        try paths.ensureDirectories()
        let sdkRoot = root.appendingPathComponent("sdk", isDirectory: true)
        try Self.makeExecutable(sdkRoot.appendingPathComponent("emulator/emulator"))
        try Self.makeExecutable(sdkRoot.appendingPathComponent("platform-tools/adb"))
        try "Pkg.Revision=36.4.9\nPkg.Path=emulator\n".write(to: sdkRoot.appendingPathComponent("emulator/source.properties"), atomically: true, encoding: .utf8)
        sdk = AndroidSDK(root: sdkRoot, emulator: sdkRoot.appendingPathComponent("emulator/emulator"),
                         adb: sdkRoot.appendingPathComponent("platform-tools/adb"), emulatorVersion: "36.4.9")
        if withPlayStoreImage {
            try Self.makeImage(sdkRoot: sdkRoot, api: "android-36.1", tag: "google_apis_playstore", abi: "arm64-v8a",
                               properties: "AndroidVersion.ApiLevel=36.1\nPkg.Revision=4\nSystemImage.TagDisplay=Google Play\nPkg.Desc=System Image arm64-v8a with Google Play.\n")
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    static func makeExecutable(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    static func makeImage(sdkRoot: URL, api: String, tag: String, abi: String, properties: String?, packageXML: String? = nil) throws {
        let dir = sdkRoot.appendingPathComponent("system-images/\(api)/\(tag)/\(abi)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("img".utf8).write(to: dir.appendingPathComponent("system.img"))
        if let properties { try properties.write(to: dir.appendingPathComponent("source.properties"), atomically: true, encoding: .utf8) }
        if let packageXML { try packageXML.write(to: dir.appendingPathComponent("package.xml"), atomically: true, encoding: .utf8) }
    }
}

// MARK: Fake host processes

/// Host view for tests. Spawned fake processes are alive while running; SIGSTOP/SIGCONT recorded on them
/// decide `isStopped`. Extra "foreign" processes can be registered for adoption tests.
final class FakeHost: HostProcessInspecting, @unchecked Sendable {
    struct Foreign {
        var argv: [String]
        var env: [String: String]
        var alive = true
        var stopped = false
    }

    private let runner: FakeProcessRunner
    private let foreign = Locked([Int32: Foreign]())
    let signalsToForeign = Locked([(Int32, Int32)]())

    init(runner: FakeProcessRunner) { self.runner = runner }

    func addForeign(pid: Int32, argv: [String], env: [String: String], stopped: Bool = false) {
        foreign.withLock { $0[pid] = Foreign(argv: argv, env: env, stopped: stopped) }
    }

    func killForeign(_ pid: Int32) { foreign.withLock { $0[pid]?.alive = false } }

    private func spawned(_ pid: Int32) -> FakeSpawnedProcess? {
        runner.spawnedProcesses.last { $0.pid == pid }
    }

    func isAlive(_ pid: Int32) -> Bool {
        if let p = spawned(pid) { return p.isRunning }
        return foreign.withLock { $0[pid]?.alive ?? false }
    }

    func isStopped(_ pid: Int32) -> Bool {
        if let p = spawned(pid) {
            guard p.isRunning else { return false }
            return p.receivedSignals.last { $0 == SIGSTOP || $0 == SIGCONT } == SIGSTOP
        }
        return foreign.withLock { ($0[pid]?.alive ?? false) && ($0[pid]?.stopped ?? false) }
    }

    func arguments(of pid: Int32) -> [String]? {
        if let p = spawned(pid) {
            return p.isRunning ? ["/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64-headless"] + p.request.arguments : nil
        }
        return foreign.withLock { $0[pid].flatMap { $0.alive ? $0.argv : nil } }
    }

    func environment(of pid: Int32) -> [String: String]? {
        if let p = spawned(pid) { return p.isRunning ? p.request.environment : nil }
        return foreign.withLock { $0[pid].flatMap { $0.alive ? $0.env : nil } }
    }

    func allPIDs() -> [Int32] {
        runner.spawnedProcesses.filter(\.isRunning).map(\.pid) + foreign.withLock { $0.filter { $0.value.alive }.map(\.key) }
    }

    func signal(_ pid: Int32, _ signal: Int32) -> Bool {
        signalsToForeign.withLock { $0.append((pid, signal)) }
        return foreign.withLock { m in
            guard m[pid]?.alive == true else { return false }
            switch signal {
            case SIGSTOP: m[pid]?.stopped = true
            case SIGCONT: m[pid]?.stopped = false
            case SIGKILL, SIGTERM: m[pid]?.alive = false
            default: break
            }
            return true
        }
    }
}

// MARK: Fake console

/// Scripted console server. `handler` maps a command line to a reply; the greeting/auth exchange is built in.
final class FakeConsole: ConsoleConnector, @unchecked Sendable {
    enum Reply {
        case ok(String)
        case ko(String)
        /// Reply, then close the connection (like `kill`).
        case okThenClose(String)
        /// Close without replying.
        case close
        /// Never reply (simulates a SIGSTOPped engine).
        case silence
    }

    let token: String
    let requireAuth: Bool
    private let state = Locked<(commands: [String], connections: Int, refuse: Bool)>(([], 0, false))
    private let handlerBox: Locked<@Sendable (String) -> Reply>
    var handler: @Sendable (String) -> Reply {
        get { handlerBox.current }
        set { handlerBox.set(newValue) }
    }

    init(token: String = "secret", requireAuth: Bool = true, handler: @escaping @Sendable (String) -> Reply = { _ in .ok("") }) {
        self.token = token
        self.requireAuth = requireAuth
        self.handlerBox = Locked(handler)
    }

    var commands: [String] { state.withLock { $0.commands } }
    var connections: Int { state.withLock { $0.connections } }
    func refuseConnections(_ refuse: Bool) { state.withLock { $0.refuse = refuse } }

    func connect(port: Int, timeout: Duration) async throws -> any ConsoleTransport {
        let refuse = state.withLock { s -> Bool in
            if !s.refuse { s.connections += 1 }
            return s.refuse
        }
        if refuse { throw EmuuError.console("connect to port \(port): Connection refused") }
        let t = FakeConsoleTransport(console: self)
        let greeting = requireAuth
            ? "Android Console: Authentication required\r\nAndroid Console: type 'auth <auth_token>' to authenticate\r\nAndroid Console: you can find your <auth_token> in \r\n'/nonexistent/.emulator_console_auth_token'\r\nOK\r\n"
            : "Android Console: type 'help' for a list of commands\r\nOK\r\n"
        t.push(greeting)
        return t
    }

    fileprivate func handle(_ line: String, on t: FakeConsoleTransport) {
        state.withLock { $0.commands.append(line) }
        if line.hasPrefix("auth ") {
            if line == "auth \(token)" { t.push("Android Console: type 'help' for a list of commands\r\nOK\r\n") }
            else { t.push("KO: authentication token does not match ~/.emulator_console_auth_token\r\n") }
            return
        }
        switch handler(line) {
        case .ok(let text): t.push(text.isEmpty ? "OK\r\n" : text.replacingOccurrences(of: "\n", with: "\r\n") + "\r\nOK\r\n")
        case .ko(let msg): t.push("KO: \(msg)\r\n")
        case .okThenClose(let text):
            t.push((text.isEmpty ? "" : text + "\r\n") + "OK\r\n")
            t.finish()
        case .close: t.finish()
        case .silence: break
        }
    }
}

final class FakeConsoleTransport: ConsoleTransport, @unchecked Sendable {
    private let console: FakeConsole
    private struct Inbox { var chunks: [Data] = []; var finished = false; var closed = false }
    private let inbox = Locked(Inbox())

    init(console: FakeConsole) { self.console = console }

    func push(_ text: String) { inbox.withLock { $0.chunks.append(Data(text.utf8)) } }
    func finish() { inbox.withLock { $0.finished = true } }

    func send(_ data: Data) async throws {
        guard !inbox.withLock({ $0.closed }) else { throw EmuuError.console("closed") }
        for line in String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n") where !line.isEmpty {
            console.handle(line, on: self)
        }
    }

    func receive(timeout: Duration) async throws -> Data? {
        let deadline = ContinuousClock.now + timeout
        while true {
            enum Next { case data(Data), eof, wait }
            let next: Next = inbox.withLock { box in
                if !box.chunks.isEmpty { return .data(box.chunks.removeFirst()) }
                return box.finished || box.closed ? .eof : .wait
            }
            switch next {
            case .data(let d): return d
            case .eof: return nil
            case .wait:
                if ContinuousClock.now >= deadline { throw EmuuError.console("no reply within \(timeout)") }
                try await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    func close() { inbox.withLock { $0.closed = true } }
}
