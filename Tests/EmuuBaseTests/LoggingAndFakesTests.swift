import Foundation
import Testing
@testable import EmuuBase
import EmuuTestSupport

@Suite struct LogFileSinkTests {
    @Test func rotatesAndBoundsFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("emuu-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = LogFileSink(url: dir.appendingPathComponent("emuu.log"), maxBytes: 1024, maxFiles: 3)
        let msg = String(repeating: "x", count: 100)
        for i in 0..<100 { sink.write(level: .info, category: "t", message: "\(i) \(msg)") }
        sink.flush()
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["emuu.1.log", "emuu.2.log", "emuu.log"])
        for name in names {
            let size = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.size] as! UInt64
            #expect(size <= 1024)
        }
        let live = try String(contentsOf: dir.appendingPathComponent("emuu.log"), encoding: .utf8)
        #expect(live.contains("99 xxx"))
        #expect(live.contains("[info] [t]"))
        #expect(sink.rotatedURL(2).lastPathComponent == "emuu.2.log")
    }

    @Test func loggerWritesThroughBootstrappedSinkRespectingLevel() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("emuu-log-\(UUID().uuidString)")
        defer {
            EmuuLogging.bootstrap(fileSink: nil)
            try? FileManager.default.removeItem(at: dir)
        }
        let sink = LogFileSink(url: dir.appendingPathComponent("emuu.log"))
        EmuuLogging.bootstrap(fileSink: sink, minimumFileLevel: .notice)
        let log = EmuuLogger(category: "unit")
        log.info("hidden-info")
        log.warning("shown-warning")
        log.error("shown-error")
        sink.flush()
        let text = try String(contentsOf: sink.url, encoding: .utf8)
        #expect(!text.contains("hidden-info"))
        #expect(text.contains("[warning] [unit] shown-warning"))
        #expect(text.contains("[error] [unit] shown-error"))
    }
}

@Suite(.timeLimit(.minutes(1))) struct FakeTests {
    @Test func fakeClockWakesSleepersInOrder() async throws {
        let clock = FakeClock()
        let t0 = clock.monotonicNow()
        let order = Locked<[Int]>([])
        let a = Task { try await clock.sleep(for: .seconds(10)); order.withLock { $0.append(10) } }
        let b = Task { try await clock.sleep(for: .seconds(5)); order.withLock { $0.append(5) } }
        #expect(await clock.waitForSleepers(2))
        clock.advance(by: .seconds(4))
        #expect(clock.sleeperCount == 2)
        clock.advance(by: .seconds(1))
        try await b.value
        #expect(order.current == [5])
        clock.advance(by: .seconds(5))
        try await a.value
        #expect(order.current == [5, 10])
        #expect(clock.monotonicNow() - t0 == .seconds(10))
    }

    @Test func fakeClockCancellation() async throws {
        let clock = FakeClock()
        let t = Task { try await clock.sleep(for: .hours(1)) }
        #expect(await clock.waitForSleepers(1))
        t.cancel()
        await #expect(throws: CancellationError.self) { try await t.value }
        #expect(clock.sleeperCount == 0)
    }

    @Test func fakeRunnerRulesSequencesAndRecording() async throws {
        let runner = FakeProcessRunner()
        runner.on(executable: "adb", argumentsPrefix: ["devices"], respond: .success("List\n"))
        runner.on(executable: "adb", arguments: ["get-state"], respond: .failure(1, stderr: "offline"), .success("device"))
        let adb = URL(fileURLWithPath: "/sdk/platform-tools/adb")
        let r1 = try await runner.run(ProcessRequest(executable: adb, arguments: ["devices", "-l"]))
        #expect(r1.stdoutString == "List\n")
        let s1 = try await runner.run(ProcessRequest(executable: adb, arguments: ["get-state"]))
        let s2 = try await runner.run(ProcessRequest(executable: adb, arguments: ["get-state"]))
        let s3 = try await runner.run(ProcessRequest(executable: adb, arguments: ["get-state"]))
        #expect(s1.exitCode == 1 && s2.trimmedStdout == "device" && s3.trimmedStdout == "device")
        await #expect(throws: EmuuError.self) { _ = try await runner.run(ProcessRequest("/bin/other")) }
        #expect(runner.commandLines.first == ["adb", "devices", "-l"])
        #expect(runner.invocations.count == 5)

        runner.unmatchedResponse = .success("fallback")
        #expect(try await runner.run(ProcessRequest("/bin/other")).stdoutString == "fallback")
    }

    @Test func fakeRunnerSimulatesTimeout() async {
        let runner = FakeProcessRunner()
        runner.on({ _ in true }, respond: .success(), delay: .seconds(30))
        await #expect(throws: EmuuError.processTimedOut(command: "x", timeout: .milliseconds(50))) {
            _ = try await runner.run(ProcessRequest("/bin/x", [], timeout: .milliseconds(50)))
        }
    }

    @Test func fakeSpawnedProcess() async throws {
        let runner = FakeProcessRunner()
        let p = try await runner.spawn(ProcessRequest("/sdk/emulator/emulator", ["-avd", "a"]))
        let fake = try #require(p as? FakeSpawnedProcess)
        fake.emit(stdout: "INFO boot")
        var it = p.stdoutLines.makeAsyncIterator()
        #expect(await it.next() == "INFO boot")
        fake.exitsOnTerminate = false
        p.terminate()
        #expect(p.isRunning)
        p.send(signal: SIGSTOP)
        p.kill()
        #expect(await p.waitForExit() == .signaled(signal: SIGKILL))
        #expect(fake.receivedSignals == [SIGTERM, SIGSTOP, SIGKILL])
        #expect(runner.spawnedProcesses.count == 1)
    }

    @Test func fakeDeviceShell() async throws {
        let dev = FakeDeviceShell()
        dev.onShell("getprop sys.boot_completed", reply: .ok(""), .ok("1\n"))
        dev.onADB(prefix: ["install"], reply: .ok("Success\n"))
        #expect(try await dev.getprop("sys.boot_completed") == "")
        #expect(try await dev.getprop("sys.boot_completed") == "1")
        #expect(try await dev.adb(["install", "-r", "a.apk"], timeout: nil).trimmedStdout == "Success")
        #expect(try await dev.shell("unknown").exitCode == 127)
        dev.throwOnUnmatched = true
        await #expect(throws: EmuuError.self) { _ = try await dev.shell("unknown") }
        #expect(dev.shellCommands.count == 4)
    }

    @Test func fakeEngineStateMachine() async throws {
        let engine = FakeEngineControl(instanceID: InstanceID(rawValue: "e")!)
        try await engine.freeze()
        #expect(await engine.state() == .frozen)
        await #expect(throws: EmuuError.invalidStateTransition(from: .frozen, action: "save snapshot")) {
            try await engine.saveSnapshot(named: "s")
        }
        try await engine.thaw()
        try await engine.saveSnapshot(named: "s")
        engine.reclaimOutcome = .reclaimed(bytes: 100, detail: "balloon")
        #expect(try await engine.reclaimGuestMemory(targetBytes: nil) == .reclaimed(bytes: 100, detail: "balloon"))
        engine.failNext(.hibernate, with: .engine("boom"))
        await #expect(throws: EmuuError.engine("boom")) { try await engine.hibernate() }
        try await engine.hibernate()
        #expect(await engine.state() == .hibernated)
        #expect(await engine.enginePID() == nil)
        try await engine.resume()
        try await engine.stop(.graceful(saveQuickBoot: true))
        #expect(engine.calls == ["freeze", "saveSnapshot(s)", "thaw", "saveSnapshot(s)", "reclaim(max)", "hibernate", "hibernate", "resume", "stop(graceful,save)"])
    }
}
