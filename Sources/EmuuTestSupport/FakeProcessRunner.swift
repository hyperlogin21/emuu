import Foundation
import EmuuBase

/// Scriptable `ProcessRunner` for tests.
///
/// ```swift
/// let runner = FakeProcessRunner()
/// runner.on(executable: "adb", arguments: ["-s", "emulator-5554", "shell", "getprop", "sys.boot_completed"],
///           respond: .success("1\n"))
/// runner.on({ $0.arguments.contains("install") }, respond: .failure(1, stderr: "INSTALL_FAILED_NO_MATCHING_ABIS"))
/// ```
///
/// Rules are checked newest-first, so later registrations override earlier ones. A rule with
/// several responses returns them in order and then keeps repeating the last one.
/// Unmatched `run` requests return `unmatchedResponse` (default: throws `processLaunchFailed` naming the
/// command, so missing scripting fails loudly).
public final class FakeProcessRunner: ProcessRunner, @unchecked Sendable {
    public enum Response: Sendable {
        /// Completed process.
        case result(exitCode: Int32, stdout: Data, stderr: Data)
        /// Thrown from `run`.
        case error(EmuuError)
        /// Computed from the request.
        case handler(@Sendable (ProcessRequest) throws -> ProcessResult)

        public static func success(_ stdout: String = "", stderr: String = "") -> Response {
            .result(exitCode: 0, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
        }

        public static func failure(_ exitCode: Int32, stdout: String = "", stderr: String = "") -> Response {
            .result(exitCode: exitCode, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
        }
    }

    public enum InvocationKind: Sendable, Hashable { case run, spawn }

    public struct Invocation: Sendable {
        public let kind: InvocationKind
        public let request: ProcessRequest
        /// `executable.lastPathComponent` + arguments, for easy assertions.
        public var commandLine: [String] { [request.executable.lastPathComponent] + request.arguments }
    }

    private struct Rule {
        let matcher: @Sendable (ProcessRequest) -> Bool
        var responses: [Response]
        let delay: Duration
        var hits = 0
    }

    private struct SpawnRule {
        let matcher: @Sendable (ProcessRequest) -> Bool
        let factory: @Sendable (ProcessRequest) -> FakeSpawnedProcess
    }

    private struct State {
        var rules: [Rule] = []
        var spawnRules: [SpawnRule] = []
        var invocations: [Invocation] = []
        var spawned: [FakeSpawnedProcess] = []
        var nextPID: Int32 = 40_000
    }

    private let state = Locked(State())
    private let unmatched: Locked<Response?>

    public init() {
        unmatched = Locked(nil)
    }

    /// Response for unmatched `run` requests; nil (default) throws.
    public var unmatchedResponse: Response? {
        get { unmatched.current }
        set { unmatched.set(newValue) }
    }

    // MARK: Scripting

    /// Registers a rule. `delay` is a real delay; if the request's timeout is shorter, `run` throws
    /// `processTimedOut` after the timeout instead (lets you test timeout handling quickly).
    public func on(_ matcher: @escaping @Sendable (ProcessRequest) -> Bool, respond responses: Response..., delay: Duration = .zero) {
        precondition(!responses.isEmpty, "at least one response")
        state.withLock { $0.rules.append(Rule(matcher: matcher, responses: responses, delay: delay)) }
    }

    /// Matches executable basename and, if given, an exact argument list.
    public func on(executable name: String, arguments: [String]? = nil, respond responses: Response..., delay: Duration = .zero) {
        precondition(!responses.isEmpty, "at least one response")
        let matcher: @Sendable (ProcessRequest) -> Bool = { req in
            req.executable.lastPathComponent == name && (arguments == nil || req.arguments == arguments!)
        }
        state.withLock { $0.rules.append(Rule(matcher: matcher, responses: responses, delay: delay)) }
    }

    /// Matches executable basename and an argument prefix.
    public func on(executable name: String, argumentsPrefix prefix: [String], respond responses: Response..., delay: Duration = .zero) {
        precondition(!responses.isEmpty, "at least one response")
        let matcher: @Sendable (ProcessRequest) -> Bool = { req in
            req.executable.lastPathComponent == name && req.arguments.starts(with: prefix)
        }
        state.withLock { $0.rules.append(Rule(matcher: matcher, responses: responses, delay: delay)) }
    }

    /// Scripts `spawn`. Unmatched spawns get a default `FakeSpawnedProcess` that stays running.
    public func onSpawn(_ matcher: @escaping @Sendable (ProcessRequest) -> Bool, factory: @escaping @Sendable (ProcessRequest) -> FakeSpawnedProcess) {
        state.withLock { $0.spawnRules.append(SpawnRule(matcher: matcher, factory: factory)) }
    }

    // MARK: Inspection

    public var invocations: [Invocation] { state.withLock { $0.invocations } }
    public var commandLines: [[String]] { invocations.map(\.commandLine) }
    public var spawnedProcesses: [FakeSpawnedProcess] { state.withLock { $0.spawned } }

    public func reset() {
        state.set(State())
    }

    // MARK: ProcessRunner

    public func run(_ request: ProcessRequest) async throws -> ProcessResult {
        try Task.checkCancellation()
        let picked: (Response, Duration)? = state.withLock { s in
            s.invocations.append(Invocation(kind: .run, request: request))
            guard let idx = s.rules.lastIndex(where: { $0.matcher(request) }) else { return nil }
            let rule = s.rules[idx]
            let response = rule.responses[min(rule.hits, rule.responses.count - 1)]
            s.rules[idx].hits += 1
            return (response, rule.delay)
        }
        let response: Response
        let delay: Duration
        if let picked {
            (response, delay) = picked
        } else if let fallback = unmatched.current {
            (response, delay) = (fallback, .zero)
        } else {
            throw EmuuError.processLaunchFailed(command: request.description, message: "FakeProcessRunner: no rule matches")
        }

        if delay > .zero {
            if let timeout = request.timeout, timeout < delay {
                try await Task.sleep(for: timeout)
                throw EmuuError.processTimedOut(command: request.commandSummary, timeout: timeout)
            }
            try await Task.sleep(for: delay)
        }

        switch response {
        case .result(let code, let out, let err):
            return ProcessResult(request: request, termination: .exited(code: code), stdout: out, stderr: err, duration: delay)
        case .error(let error):
            throw error
        case .handler(let body):
            return try body(request)
        }
    }

    public func spawn(_ request: ProcessRequest) async throws -> any SpawnedProcess {
        let (factory, pid): ((@Sendable (ProcessRequest) -> FakeSpawnedProcess)?, Int32) = state.withLock { s in
            s.invocations.append(Invocation(kind: .spawn, request: request))
            s.nextPID += 1
            return (s.spawnRules.last(where: { $0.matcher(request) })?.factory, s.nextPID)
        }
        let process = factory?(request) ?? FakeSpawnedProcess(request: request, pid: pid)
        state.withLock { $0.spawned.append(process) }
        return process
    }
}

/// Controllable `SpawnedProcess`. Tests push output with `emit…` and end it with `exit(…)`.
/// By default SIGTERM/SIGINT/SIGKILL make it exit as `.signaled`; set `exitsOnTerminate = false`
/// to simulate a process that ignores SIGTERM. All signals are recorded in `receivedSignals`.
public final class FakeSpawnedProcess: SpawnedProcess, @unchecked Sendable {
    public let pid: Int32
    public let request: ProcessRequest
    public let stdoutLines: AsyncStream<String>
    public let stderrLines: AsyncStream<String>

    private let outCont: AsyncStream<String>.Continuation
    private let errCont: AsyncStream<String>.Continuation

    private struct State {
        var termination: ProcessTermination?
        var waiters: [CheckedContinuation<ProcessTermination, Never>] = []
        var signals: [Int32] = []
        var stdin = Data()
        var stdinClosed = false
        var recent: [String] = []
        var exitsOnTerminate = true
    }

    private let state = Locked(State())

    public init(request: ProcessRequest, pid: Int32 = 42_424) {
        self.request = request
        self.pid = pid
        (stdoutLines, outCont) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(SpawnedProcessDefaults.streamBufferLines))
        (stderrLines, errCont) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(SpawnedProcessDefaults.streamBufferLines))
    }

    public var exitsOnTerminate: Bool {
        get { state.withLock { $0.exitsOnTerminate } }
        set { state.withLock { $0.exitsOnTerminate = newValue } }
    }

    public var receivedSignals: [Int32] { state.withLock { $0.signals } }
    public var stdinData: Data { state.withLock { $0.stdin } }
    public var isStdinClosed: Bool { state.withLock { $0.stdinClosed } }

    public func emit(stdout line: String) {
        state.withLock { $0.recent.append(line) }
        outCont.yield(line)
    }

    public func emit(stderr line: String) {
        state.withLock { $0.recent.append(line) }
        errCont.yield(line)
    }

    /// Ends both line streams (EOF) without exiting.
    public func finishOutput() {
        outCont.finish()
        errCont.finish()
    }

    /// Exits normally with `code`.
    public func exit(code: Int32 = 0) { finish(.exited(code: code)) }

    /// Finishes with any termination. Idempotent.
    public func finish(_ termination: ProcessTermination) {
        let waiters: [CheckedContinuation<ProcessTermination, Never>]? = state.withLock { s in
            guard s.termination == nil else { return nil }
            s.termination = termination
            let w = s.waiters
            s.waiters = []
            return w
        }
        guard let waiters else { return }
        finishOutput()
        waiters.forEach { $0.resume(returning: termination) }
    }

    // MARK: SpawnedProcess

    public var termination: ProcessTermination? { state.withLock { $0.termination } }
    public var isRunning: Bool { termination == nil }

    public func recentOutput() -> [String] {
        state.withLock { Array($0.recent.suffix(SpawnedProcessDefaults.recentOutputLines)) }
    }

    public func waitForExit() async -> ProcessTermination {
        await withCheckedContinuation { cont in
            let done: ProcessTermination? = state.withLock { s in
                if let t = s.termination { return t }
                s.waiters.append(cont)
                return nil
            }
            if let done { cont.resume(returning: done) }
        }
    }

    public func send(signal: Int32) {
        let shouldExit: Bool = state.withLock { s in
            guard s.termination == nil else { return false }
            s.signals.append(signal)
            return signal == SIGKILL || ((signal == SIGTERM || signal == SIGINT) && s.exitsOnTerminate)
        }
        if shouldExit { finish(.signaled(signal: signal)) }
    }

    public func writeStdin(_ data: Data) throws {
        try state.withLock { s in
            guard !s.stdinClosed else { throw EmuuError.io(path: "stdin", message: "stdin is closed") }
            s.stdin.append(data)
        }
    }

    public func closeStdin() {
        state.withLock { $0.stdinClosed = true }
    }
}
