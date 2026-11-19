import Foundation
import EmuuBase

/// Scriptable `DeviceShell`. Shell rules match the full command string; adb rules match the argument list.
/// Newest rule wins; multi-response rules return in order then repeat the last.
/// Unmatched calls return exit 127 with "fake: not scripted" on stderr (or throw if `throwOnUnmatched`).
public final class FakeDeviceShell: DeviceShell, @unchecked Sendable {
    public enum Reply: Sendable {
        case output(exitCode: Int32, stdout: String, stderr: String)
        case error(EmuuError)

        public static func ok(_ stdout: String = "") -> Reply { .output(exitCode: 0, stdout: stdout, stderr: "") }
        public static func fail(_ code: Int32, _ stderr: String = "") -> Reply { .output(exitCode: code, stdout: "", stderr: stderr) }
    }

    public enum Call: Sendable, Hashable {
        case shell(String)
        case adb([String])
    }

    private struct Rule {
        let matchesShell: (@Sendable (String) -> Bool)?
        let matchesADB: (@Sendable ([String]) -> Bool)?
        var replies: [Reply]
        var hits = 0
    }

    private struct State {
        var rules: [Rule] = []
        var calls: [Call] = []
        var throwOnUnmatched = false
    }

    public let serial: DeviceSerial
    private let state = Locked(State())

    public init(serial: DeviceSerial = .emulator(consolePort: 5554)) {
        self.serial = serial
    }

    public var throwOnUnmatched: Bool {
        get { state.withLock { $0.throwOnUnmatched } }
        set { state.withLock { $0.throwOnUnmatched = newValue } }
    }

    /// Exact shell command.
    public func onShell(_ command: String, reply replies: Reply...) {
        add(Rule(matchesShell: { $0 == command }, matchesADB: nil, replies: replies))
    }

    /// Shell commands with this prefix.
    public func onShell(prefix: String, reply replies: Reply...) {
        add(Rule(matchesShell: { $0.hasPrefix(prefix) }, matchesADB: nil, replies: replies))
    }

    public func onShell(where predicate: @escaping @Sendable (String) -> Bool, reply replies: Reply...) {
        add(Rule(matchesShell: predicate, matchesADB: nil, replies: replies))
    }

    /// adb argument lists with this prefix.
    public func onADB(prefix: [String], reply replies: Reply...) {
        add(Rule(matchesShell: nil, matchesADB: { $0.starts(with: prefix) }, replies: replies))
    }

    private func add(_ rule: Rule) {
        precondition(!rule.replies.isEmpty, "at least one reply")
        state.withLock { $0.rules.append(rule) }
    }

    public var calls: [Call] { state.withLock { $0.calls } }
    public var shellCommands: [String] {
        calls.compactMap { if case .shell(let c) = $0 { return c } else { return nil } }
    }

    public func shell(_ command: String, timeout: Duration?) async throws -> ProcessResult {
        let reply = state.withLock { s -> Reply? in
            s.calls.append(.shell(command))
            guard let i = s.rules.lastIndex(where: { $0.matchesShell?(command) ?? false }) else { return nil }
            return Self.take(&s.rules[i])
        }
        return try resolve(reply, args: ["shell", command])
    }

    public func adb(_ arguments: [String], timeout: Duration?) async throws -> ProcessResult {
        let reply = state.withLock { s -> Reply? in
            s.calls.append(.adb(arguments))
            guard let i = s.rules.lastIndex(where: { $0.matchesADB?(arguments) ?? false }) else { return nil }
            return Self.take(&s.rules[i])
        }
        return try resolve(reply, args: arguments)
    }

    private static func take(_ rule: inout Rule) -> Reply {
        let r = rule.replies[min(rule.hits, rule.replies.count - 1)]
        rule.hits += 1
        return r
    }

    private func resolve(_ reply: Reply?, args: [String]) throws -> ProcessResult {
        let request = ProcessRequest(executable: URL(fileURLWithPath: "/fake/adb"), arguments: ["-s", serial.rawValue] + args)
        guard let reply else {
            if throwOnUnmatched { throw EmuuError.adb("fake: not scripted: \(args.joined(separator: " "))") }
            return ProcessResult(request: request, termination: .exited(code: 127), stderr: Data("fake: not scripted".utf8))
        }
        switch reply {
        case .output(let code, let out, let err):
            return ProcessResult(request: request, termination: .exited(code: code), stdout: Data(out.utf8), stderr: Data(err.utf8))
        case .error(let e):
            throw e
        }
    }
}
