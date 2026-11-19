import Foundation

/// Where a spawned process's stdout/stderr goes.
public enum OutputDisposition: Sendable, Hashable {
    /// Captured: collected into `ProcessResult` for `run`, streamed as lines for `spawn`.
    case pipe
    /// Sent to /dev/null.
    case discard
    /// Appended to a file (created if needed). Good for chatty long-running processes (engine logs).
    case file(URL)
}

/// Everything needed to start a process.
public struct ProcessRequest: Sendable, Hashable, CustomStringConvertible {
    public var executable: URL
    public var arguments: [String]
    /// Variables set for the child. Merged over the parent's environment when `inheritEnvironment` is true.
    public var environment: [String: String]
    public var inheritEnvironment: Bool
    public var workingDirectory: URL?
    /// Bytes written to stdin, after which stdin is closed. nil = stdin is /dev/null (for `run`) or an
    /// open pipe writable via `SpawnedProcess.writeStdin` (for `spawn`).
    public var stdin: Data?
    /// `run` only: overall time limit. On expiry the process gets SIGTERM, then SIGKILL after 2 s,
    /// and `run` throws `EmuuError.processTimedOut`. Ignored by `spawn`.
    public var timeout: Duration?
    public var stdout: OutputDisposition
    public var stderr: OutputDisposition

    public init(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        inheritEnvironment: Bool = true,
        workingDirectory: URL? = nil,
        stdin: Data? = nil,
        timeout: Duration? = nil,
        stdout: OutputDisposition = .pipe,
        stderr: OutputDisposition = .pipe
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.inheritEnvironment = inheritEnvironment
        self.workingDirectory = workingDirectory
        self.stdin = stdin
        self.timeout = timeout
        self.stdout = stdout
        self.stderr = stderr
    }

    /// Convenience: executable given as a path.
    public init(_ executablePath: String, _ arguments: [String] = [], timeout: Duration? = nil) {
        self.init(executable: URL(fileURLWithPath: executablePath), arguments: arguments, timeout: timeout)
    }

    /// The child's effective environment.
    public func resolvedEnvironment(parent: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        inheritEnvironment ? parent.merging(environment) { _, new in new } : environment
    }

    /// Shell-ish rendering for logs and error messages.
    public var description: String {
        ([executable.path] + arguments).map { arg in
            arg.isEmpty || arg.contains(where: { $0 == " " || $0 == "\"" || $0 == "'" }) ? "'\(arg.replacingOccurrences(of: "'", with: "'\\''"))'" : arg
        }.joined(separator: " ")
    }

    /// Short name (`adb shell …`) for error messages.
    public var commandSummary: String {
        ([executable.lastPathComponent] + arguments.prefix(3)).joined(separator: " ") + (arguments.count > 3 ? " …" : "")
    }
}

/// How a process ended.
public enum ProcessTermination: Sendable, Hashable, CustomStringConvertible {
    case exited(code: Int32)
    case signaled(signal: Int32)

    /// Exit code, or 128+signal for signals (shell convention).
    public var statusCode: Int32 {
        switch self {
        case .exited(let code): return code
        case .signaled(let sig): return 128 + sig
        }
    }

    public var description: String {
        switch self {
        case .exited(let code): return "exit \(code)"
        case .signaled(let sig): return "signal \(sig)"
        }
    }
}

/// Result of a completed `run`.
public struct ProcessResult: Sendable, Hashable {
    public var request: ProcessRequest
    public var termination: ProcessTermination
    public var stdout: Data
    public var stderr: Data
    public var duration: Duration

    public init(request: ProcessRequest, termination: ProcessTermination, stdout: Data = Data(), stderr: Data = Data(), duration: Duration = .zero) {
        self.request = request
        self.termination = termination
        self.stdout = stdout
        self.stderr = stderr
        self.duration = duration
    }

    public var exitCode: Int32 { termination.statusCode }
    public var succeeded: Bool { termination == .exited(code: 0) }
    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
    /// stdout with surrounding whitespace/newlines removed (and `\r` from adb's pty output).
    public var trimmedStdout: String { stdoutString.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Returns self on exit 0, otherwise throws `EmuuError.processFailed`.
    @discardableResult
    public func checked() throws -> ProcessResult {
        guard succeeded else {
            let detail = stderrString.isEmpty ? stdoutString : stderrString
            throw EmuuError.processFailed(command: request.commandSummary, exitCode: exitCode, stderr: String(detail.suffix(2000)))
        }
        return self
    }
}

/// Handle to a long-running child started with `ProcessRunner.spawn`.
///
/// Line streams are single-consumer `AsyncStream`s that keep only the newest
/// `SpawnedProcessDefaults.streamBufferLines` unconsumed lines (bounded memory if nobody listens).
/// They finish when the corresponding pipe reaches EOF. For `.discard`/`.file` dispositions they finish immediately.
public protocol SpawnedProcess: AnyObject, Sendable {
    var pid: Int32 { get }
    var request: ProcessRequest { get }
    var stdoutLines: AsyncStream<String> { get }
    var stderrLines: AsyncStream<String> { get }
    /// nil while running.
    var termination: ProcessTermination? { get }
    var isRunning: Bool { get }
    /// The last few lines seen on piped stdout+stderr (for crash diagnostics), oldest first.
    func recentOutput() -> [String]
    /// Waits for exit (returns immediately if already exited). This does not observe task cancellation:
    /// to bound the wait, signal the process (see `terminate(grace:)`). Any number of callers may wait.
    func waitForExit() async -> ProcessTermination
    /// Sends a signal (SIGTERM, SIGKILL, SIGSTOP, SIGCONT, …). No-op once exited.
    func send(signal: Int32)
    /// Writes to stdin (only when the request had `stdin == nil`).
    func writeStdin(_ data: Data) throws
    func closeStdin()
}

extension SpawnedProcess {
    public func terminate() { send(signal: SIGTERM) }
    public func kill() { send(signal: SIGKILL) }

    /// SIGTERM, wait up to `grace`, then SIGKILL. Returns the final termination.
    @discardableResult
    public func terminate(grace: Duration, clock: any EmuuClock = SystemClock()) async -> ProcessTermination {
        if let t = termination { return t }
        send(signal: SIGTERM)
        let deadline = clock.monotonicNow() + grace
        while clock.monotonicNow() < deadline {
            if let t = termination { return t }
            try? await clock.sleep(for: .milliseconds(50))
        }
        if termination == nil { send(signal: SIGKILL) }
        return await waitForExit()
    }
}

public enum SpawnedProcessDefaults {
    /// Max unconsumed lines buffered per stream.
    public static let streamBufferLines = 2000
    /// Lines kept for `recentOutput()`.
    public static let recentOutputLines = 200
}

/// Abstraction over launching processes. Every module shells out through this so tests can use
/// `EmuuTestSupport.FakeProcessRunner`.
public protocol ProcessRunner: Sendable {
    /// Runs to completion, capturing piped output. Non-zero exit is NOT an error (call `.checked()`).
    /// Throws `EmuuError.processLaunchFailed`, `.processTimedOut`, or `CancellationError`
    /// (the child is terminated when the calling task is cancelled).
    func run(_ request: ProcessRequest) async throws -> ProcessResult

    /// Starts a long-running process and returns immediately.
    func spawn(_ request: ProcessRequest) async throws -> any SpawnedProcess
}

/// Finds executables on PATH.
public enum ExecutableLocator {
    public static func find(
        _ name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        extraDirectories: [String] = [],
        fileManager: FileManager = .default
    ) -> URL? {
        if name.contains("/") {
            return fileManager.isExecutableFile(atPath: name) ? URL(fileURLWithPath: name) : nil
        }
        let dirs = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init) + extraDirectories
        for dir in dirs where !dir.isEmpty {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }
}
