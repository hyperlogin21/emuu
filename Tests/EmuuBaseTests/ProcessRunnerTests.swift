import Foundation
import Testing
@testable import EmuuBase

@Suite struct LineSplitterTests {
    @Test func splitsAcrossChunksAndCRLF() {
        var s = LineSplitter()
        #expect(s.feed(Data("hel".utf8)) == [])
        #expect(s.feed(Data("lo\r\nwor".utf8)) == ["hello"])
        #expect(s.feed(Data("ld\n\nx".utf8)) == ["world", ""])
        #expect(s.finish() == "x")
        #expect(s.finish() == nil)
    }

    @Test func capsLongLines() {
        var s = LineSplitter(maxLineBytes: 4)
        #expect(s.feed(Data("abcdefghij".utf8)) == ["abcd", "efgh"])
        #expect(s.finish() == "ij")
    }
}

@Suite(.timeLimit(.minutes(1))) struct SystemProcessRunnerTests {
    let runner = SystemProcessRunner()

    func sh(_ script: String, timeout: Duration? = nil, stdin: Data? = nil, env: [String: String] = [:]) -> ProcessRequest {
        ProcessRequest(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], environment: env, stdin: stdin, timeout: timeout)
    }

    @Test func capturesStdoutStderrAndExitCode() async throws {
        let r = try await runner.run(sh("echo out; echo err >&2; exit 3"))
        #expect(r.trimmedStdout == "out")
        #expect(r.stderrString == "err\n")
        #expect(r.termination == .exited(code: 3))
        #expect(!r.succeeded)
        #expect(throws: EmuuError.self) { try r.checked() }
    }

    @Test func passesStdinAndEnvironment() async throws {
        let r = try await runner.run(sh("cat; printf %s \"$EMUU_T\"", stdin: Data("piped\n".utf8), env: ["EMUU_T": "v1"]))
        #expect(r.stdoutString == "piped\nv1")
        let clean = try await runner.run(ProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/env"), environment: ["ONLY": "1"], inheritEnvironment: false))
        #expect(clean.trimmedStdout == "ONLY=1")
    }

    @Test func workingDirectory() async throws {
        var req = sh("pwd -P")
        req.workingDirectory = URL(fileURLWithPath: "/private/tmp")
        let r = try await runner.run(req)
        #expect(r.trimmedStdout == "/private/tmp")
    }

    @Test func largeOutputDoesNotDeadlock() async throws {
        // 4 MiB on stdout and 1 MiB on stderr: far beyond the 64 KiB pipe buffer.
        let r = try await runner.run(sh("head -c 4194304 /dev/zero; head -c 1048576 /dev/zero >&2"))
        #expect(r.stdout.count == 4_194_304)
        #expect(r.stderr.count == 1_048_576)
    }

    @Test func timeoutKillsAndThrows() async throws {
        let start = ContinuousClock.now
        await #expect(throws: EmuuError.processTimedOut(command: "sh -c sleep 30", timeout: .milliseconds(300))) {
            _ = try await runner.run(sh("sleep 30", timeout: .milliseconds(300)))
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func timeoutEscalatesToSIGKILL() async throws {
        let fast = SystemProcessRunner(pipeDrainGrace: .milliseconds(200), killGrace: .milliseconds(300))
        let start = ContinuousClock.now
        await #expect(throws: EmuuError.self) {
            _ = try await fast.run(sh("trap '' TERM; sleep 30", timeout: .milliseconds(200)))
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func cancellationTerminatesChild() async throws {
        let start = ContinuousClock.now
        let task = Task { try await runner.run(sh("sleep 30")) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func launchFailure() async {
        await #expect(throws: EmuuError.self) {
            _ = try await runner.run(ProcessRequest("/nonexistent/tool"))
        }
    }

    @Test func backgroundGrandchildHoldingPipeDoesNotHang() async throws {
        let quick = SystemProcessRunner(pipeDrainGrace: .milliseconds(300))
        let start = ContinuousClock.now
        let r = try await quick.run(sh("echo started; sleep 5 & exit 0"))
        #expect(r.trimmedStdout == "started")
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func discardAndFileDispositions() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("emuu-out-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: file) }
        var req = sh("echo one; echo two >&2")
        req.stdout = .file(file)
        req.stderr = .discard
        let r = try await runner.run(req)
        #expect(r.succeeded && r.stdout.isEmpty && r.stderr.isEmpty)
        var again = sh("echo three")
        again.stdout = .file(file)
        _ = try await runner.run(again)
        #expect(try String(contentsOf: file, encoding: .utf8) == "one\nthree\n")
    }

    @Test func spawnStreamsLinesAndExits() async throws {
        let p = try await runner.spawn(sh("echo a; echo b >&2; printf c; exit 7"))
        #expect(p.pid > 0)
        var out: [String] = []
        for await line in p.stdoutLines { out.append(line) }
        var err: [String] = []
        for await line in p.stderrLines { err.append(line) }
        #expect(out == ["a", "c"])
        #expect(err == ["b"])
        #expect(await p.waitForExit() == .exited(code: 7))
        #expect(!p.isRunning)
        #expect(Set(p.recentOutput()) == ["a", "b", "c"])
    }

    @Test func spawnStdinAndSignals() async throws {
        let p = try await runner.spawn(sh("read x; echo got:$x; sleep 30"))
        try p.writeStdin(Data("hi\n".utf8))
        var it = p.stdoutLines.makeAsyncIterator()
        #expect(await it.next() == "got:hi")
        #expect(p.isRunning)
        let t = await p.terminate(grace: .seconds(2))
        #expect(t == .signaled(signal: SIGTERM))
        p.send(signal: SIGKILL) // no-op after exit, must not crash
    }

    @Test func spawnStopContinue() async throws {
        let p = try await runner.spawn(sh("while true; do echo tick; sleep 0.05; done"))
        var it = p.stdoutLines.makeAsyncIterator()
        _ = await it.next()
        p.send(signal: SIGSTOP)
        try await Task.sleep(for: .milliseconds(100))
        // Process state 'T' = stopped.
        let ps = try await runner.run(ProcessRequest("/bin/ps", ["-o", "stat=", "-p", "\(p.pid)"]))
        #expect(ps.trimmedStdout.hasPrefix("T"))
        p.send(signal: SIGCONT)
        let ps2 = try await runner.run(ProcessRequest("/bin/ps", ["-o", "stat=", "-p", "\(p.pid)"]))
        #expect(!ps2.trimmedStdout.hasPrefix("T"))
        p.kill()
        #expect(await p.waitForExit() == .signaled(signal: SIGKILL))
    }

    @Test func executableLocator() {
        #expect(ExecutableLocator.find("sh", environment: ["PATH": "/usr/bin:/bin"])?.path == "/bin/sh")
        #expect(ExecutableLocator.find("definitely-not-here-emuu", environment: ["PATH": "/bin"]) == nil)
        #expect(ExecutableLocator.find("/bin/sh")?.path == "/bin/sh")
    }

    @Test func requestDescription() {
        let r = ProcessRequest("/usr/bin/adb", ["-s", "emulator-5554", "shell", "echo hi"])
        #expect(r.description == "/usr/bin/adb -s emulator-5554 shell 'echo hi'")
        #expect(r.commandSummary == "adb -s emulator-5554 shell …")
        #expect(ProcessRequest(executable: URL(fileURLWithPath: "/x"), environment: ["A": "1"]).resolvedEnvironment(parent: ["A": "0", "B": "2"]) == ["A": "1", "B": "2"])
    }
}

/// Regression: long-lived children (engine, detached supervisor) write to a `.file` log that is now capped in
/// place. That only works when the child's descriptor is O_APPEND; otherwise its next write lands at the old
/// offset and leaves a hole of NUL bytes as large as the old log.
@Suite(.timeLimit(.minutes(1))) struct LogFileCapTests {
    @Test func capInPlaceWhileChildKeepsWriting() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("emuu-logcap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("engine.log")
        let child = try await SystemProcessRunner().spawn(ProcessRequest(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "head -c 4096 /dev/zero | tr '\\0' x; echo; sleep 1; echo after-cap"],
            stdout: .file(log), stderr: .file(log)))
        let deadline = ContinuousClock.now + .seconds(5)
        while (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? NSNumber)?.intValue ?? 0 < 4097,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(LogFileCap.capInPlace(log, limit: 1024))
        #expect(!LogFileCap.capInPlace(log, limit: 1024)) // now small
        _ = await child.waitForExit()
        let data = try Data(contentsOf: log)
        #expect(String(decoding: data, as: UTF8.self) == "after-cap\n")
        #expect(!data.contains(0))
        let rotated = dir.appendingPathComponent("engine.1.log")
        #expect(((try? Data(contentsOf: rotated))?.count ?? 0) == 4097)
    }
}
