import Foundation

/// Real `ProcessRunner` backed by Foundation `Process`.
public struct SystemProcessRunner: ProcessRunner {
    /// Grace period after exit to drain pipes. Guards against grandchildren (e.g. a forked adb server)
    /// that inherit the pipe and keep it open forever.
    public var pipeDrainGrace: Duration
    /// Delay between SIGTERM and SIGKILL on timeout/cancellation.
    public var killGrace: Duration

    public init(pipeDrainGrace: Duration = .seconds(2), killGrace: Duration = .seconds(2)) {
        self.pipeDrainGrace = pipeDrainGrace
        self.killGrace = killGrace
    }

    public func run(_ request: ProcessRequest) async throws -> ProcessResult {
        try Task.checkCancellation()
        let start = ContinuousClock.now
        let child = try ChildProcess(request: request, mode: .collect)
        let timedOut = Locked(false)
        let killGrace = self.killGrace

        let timeoutTask: Task<Void, Never>? = request.timeout.map { limit in
            Task.detached {
                do { try await Task.sleep(for: limit) } catch { return }
                guard child.termination == nil else { return }
                timedOut.set(true)
                child.send(signal: SIGTERM)
                try? await Task.sleep(for: killGrace)
                child.send(signal: SIGKILL)
            }
        }

        let termination = await withTaskCancellationHandler {
            await child.waitForExit()
        } onCancel: {
            child.send(signal: SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + killGrace.timeInterval) {
                child.send(signal: SIGKILL)
            }
        }
        timeoutTask?.cancel()

        let (out, err) = await child.drainCollected(grace: pipeDrainGrace)
        if timedOut.current, let limit = request.timeout {
            throw EmuuError.processTimedOut(command: request.commandSummary, timeout: limit)
        }
        if Task.isCancelled { throw CancellationError() }
        return ProcessResult(request: request, termination: termination, stdout: out, stderr: err, duration: ContinuousClock.now - start)
    }

    public func spawn(_ request: ProcessRequest) async throws -> any SpawnedProcess {
        try ChildProcess(request: request, mode: .stream)
    }
}

/// One launched child. Used for both `run` (collect mode) and `spawn` (stream mode).
final class ChildProcess: SpawnedProcess, @unchecked Sendable {
    enum Mode { case collect, stream }

    private struct ExitState {
        var termination: ProcessTermination?
        var waiters: [CheckedContinuation<ProcessTermination, Never>] = []
    }

    let request: ProcessRequest
    let pid: Int32
    let stdoutLines: AsyncStream<String>
    let stderrLines: AsyncStream<String>

    private let process: Process
    private let exitState = Locked(ExitState())
    private let stdinHandle: FileHandle?
    private let stdinLock = NSLock()
    private var stdinClosed = false
    private let outCollector: StreamCollector?
    private let errCollector: StreamCollector?
    private let recent = Locked<[String]>([])

    init(request: ProcessRequest, mode: Mode) throws {
        self.request = request
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: request.executable.path) else {
            throw EmuuError.processLaunchFailed(command: request.commandSummary, message: "not an executable file: \(request.executable.path)")
        }

        let process = Process()
        process.executableURL = request.executable
        process.arguments = request.arguments
        process.environment = request.resolvedEnvironment()
        if let wd = request.workingDirectory { process.currentDirectoryURL = wd }
        self.process = process

        // stdin
        var stdinWriter: FileHandle?
        var stdinPayload: Data?
        if let data = request.stdin {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinWriter = pipe.fileHandleForWriting
            stdinPayload = data
        } else if mode == .stream {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinWriter = pipe.fileHandleForWriting
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        if let w = stdinWriter {
            // Writing to a pipe whose reader exited must not kill us with SIGPIPE.
            _ = fcntl(w.fileDescriptor, F_SETNOSIGPIPE, 1)
        }
        self.stdinHandle = stdinWriter

        let recent = self.recent
        let onLine: @Sendable (String) -> Void = { line in
            recent.withLock { buf in
                buf.append(line)
                if buf.count > SpawnedProcessDefaults.recentOutputLines {
                    buf.removeFirst(buf.count - SpawnedProcessDefaults.recentOutputLines)
                }
            }
        }

        func makeOutput(_ disposition: OutputDisposition) throws -> (Any, StreamCollector?, AsyncStream<String>) {
            switch disposition {
            case .pipe:
                let pipe = Pipe()
                let (stream, cont) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(SpawnedProcessDefaults.streamBufferLines))
                var sink: (@Sendable (String) -> Void)?
                if mode == .stream {
                    sink = { (line: String) -> Void in
                        onLine(line)
                        cont.yield(line)
                    }
                }
                let onEOF: @Sendable () -> Void = { cont.finish() }
                let collector = StreamCollector(
                    handle: pipe.fileHandleForReading,
                    collect: mode == .collect,
                    lineSink: sink,
                    onEOF: onEOF
                )
                if mode == .collect { cont.finish() }
                return (pipe, collector, stream)
            case .discard:
                return (FileHandle.nullDevice, nil, AsyncStream { $0.finish() })
            case .file(let url):
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                // O_APPEND: every write goes to the current end of file, so the log can be capped in place
                // (`LogFileCap`) while the child keeps writing, without leaving a sparse hole.
                let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
                guard fd >= 0 else {
                    throw EmuuError.io(path: url.path, message: "cannot open for writing: \(String(cString: strerror(errno)))")
                }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                return (handle, nil, AsyncStream { $0.finish() })
            }
        }

        let (outTarget, outCollector, outStream) = try makeOutput(request.stdout)
        let (errTarget, errCollector, errStream) = try makeOutput(request.stderr)
        process.standardOutput = outTarget
        process.standardError = errTarget
        self.outCollector = outCollector
        self.errCollector = errCollector
        self.stdoutLines = outStream
        self.stderrLines = errStream

        let exitState = self.exitState
        process.terminationHandler = { p in
            let t: ProcessTermination = p.terminationReason == .uncaughtSignal
                ? .signaled(signal: p.terminationStatus)
                : .exited(code: p.terminationStatus)
            let waiters = exitState.withLock { s -> [CheckedContinuation<ProcessTermination, Never>] in
                s.termination = t
                let w = s.waiters
                s.waiters = []
                return w
            }
            for w in waiters { w.resume(returning: t) }
        }

        outCollector?.start()
        errCollector?.start()
        do {
            try process.run()
        } catch {
            outCollector?.stop()
            errCollector?.stop()
            throw EmuuError.processLaunchFailed(command: request.commandSummary, message: error.localizedDescription)
        }
        self.pid = process.processIdentifier

        // Close file handles we passed to the child (Foundation closes Pipe ends itself).
        if case .file = request.stdout, let h = outTarget as? FileHandle { try? h.close() }
        if case .file = request.stderr, let h = errTarget as? FileHandle { try? h.close() }

        if let payload = stdinPayload, let w = stdinWriter {
            DispatchQueue.global(qos: .utility).async { [self] in
                try? w.write(contentsOf: payload)
                closeStdin()
            }
        }
    }

    var termination: ProcessTermination? { exitState.withLock { $0.termination } }
    var isRunning: Bool { termination == nil }

    func recentOutput() -> [String] { recent.current }

    func waitForExit() async -> ProcessTermination {
        await withCheckedContinuation { cont in
            let done: ProcessTermination? = exitState.withLock { s in
                if let t = s.termination { return t }
                s.waiters.append(cont)
                return nil
            }
            if let done { cont.resume(returning: done) }
        }
    }

    func send(signal sig: Int32) {
        // Check under the lock so we never signal a recycled pid after exit.
        exitState.withLock { s in
            if s.termination == nil { _ = Darwin.kill(pid, sig) }
        }
    }

    func writeStdin(_ data: Data) throws {
        stdinLock.lock()
        defer { stdinLock.unlock() }
        guard let h = stdinHandle, !stdinClosed else {
            throw EmuuError.io(path: "stdin of \(request.commandSummary)", message: "stdin is not open")
        }
        do {
            try h.write(contentsOf: data)
        } catch {
            throw EmuuError.io(path: "stdin of \(request.commandSummary)", message: error.localizedDescription)
        }
    }

    func closeStdin() {
        stdinLock.lock()
        defer { stdinLock.unlock() }
        guard let h = stdinHandle, !stdinClosed else { return }
        stdinClosed = true
        try? h.close()
    }

    /// Collect mode: waits (bounded by `grace`) for both pipes to hit EOF and returns their bytes.
    func drainCollected(grace: Duration) async -> (Data, Data) {
        let deadline = ContinuousClock.now + grace
        while ContinuousClock.now < deadline {
            let outDone = outCollector?.isAtEOF ?? true
            let errDone = errCollector?.isAtEOF ?? true
            if outDone && errDone { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        outCollector?.stop()
        errCollector?.stop()
        closeStdin()
        return (outCollector?.collected ?? Data(), errCollector?.collected ?? Data())
    }
}

/// Reads one pipe via `readabilityHandler`, either collecting bytes or emitting lines.
final class StreamCollector: @unchecked Sendable {
    private struct State {
        var data = Data()
        var splitter = LineSplitter()
        var eof = false
    }

    private let handle: FileHandle
    private let collect: Bool
    private let lineSink: (@Sendable (String) -> Void)?
    private let onEOF: @Sendable () -> Void
    private let state = Locked(State())

    init(handle: FileHandle, collect: Bool, lineSink: (@Sendable (String) -> Void)?, onEOF: @escaping @Sendable () -> Void) {
        self.handle = handle
        self.collect = collect
        self.lineSink = lineSink
        self.onEOF = onEOF
    }

    func start() {
        handle.readabilityHandler = { [self] h in
            let chunk = h.availableData
            if chunk.isEmpty {
                finishEOF()
                return
            }
            let lines: [String] = state.withLock { s in
                if collect { s.data.append(chunk) }
                return lineSink == nil ? [] : s.splitter.feed(chunk)
            }
            if let sink = lineSink { lines.forEach(sink) }
        }
    }

    private func finishEOF() {
        handle.readabilityHandler = nil
        let tail: String?? = state.withLock { s in
            guard !s.eof else { return .none }
            s.eof = true
            return .some(lineSink == nil ? nil : s.splitter.finish())
        }
        guard let tail else { return } // already finished
        if let line = tail, let sink = lineSink { sink(line) }
        try? handle.close()
        onEOF()
    }

    /// Stops reading (used after the drain grace period expired or launch failed).
    func stop() {
        handle.readabilityHandler = nil
        let first = state.withLock { s -> Bool in
            if s.eof { return false }
            s.eof = true
            return true
        }
        // The handle is deliberately not closed here: a handler invocation may still be inside
        // `availableData`, and closing underneath it raises. The Pipe's handle closes on dealloc.
        if first { onEOF() }
    }

    var isAtEOF: Bool { state.withLock { $0.eof } }
    var collected: Data { state.withLock { $0.data } }
}
