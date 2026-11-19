import Foundation
import Testing
import EmuuBase
import EmuuTestSupport
@testable import EmuuMemory

@Suite struct GovernorTests {
    struct Rig {
        let clock = FakeClock()
        let engine = FakeEngineControl(instanceID: testID)
        let activity = FakeActivity()
        let effector: RecordingEffector
        let governor: MemoryGovernor
        let guestAvail: Locked<Double>
        let footprint: Locked<UInt64>
        let hostPressure: Locked<MemoryPressureLevel>

        init(config: GovernorConfig = .preset(.balanced), historyCapacity: Int = 100, csv: SampleCSVLog? = nil, sink: (any GovernorEventSink)? = nil) {
            let guestAvail = Locked(0.5)
            let footprint = Locked(2 * gib)
            let hostPressure = Locked(MemoryPressureLevel.normal)
            self.guestAvail = guestAvail
            self.footprint = footprint
            self.hostPressure = hostPressure
            let engine = self.engine
            var config = config
            config.guestActionGraceAfterStart = .zero
            effector = RecordingEffector()
            let router = EffectorRouter([effector])
            governor = MemoryGovernor(
                instanceID: testID, config: config, engine: engine,
                guestSampler: ScriptedGuestSampler { GuestSnapshot(memory: guest(available: guestAvail.current), foregroundProcesses: ["com.game"]) },
                hostSampler: ScriptedHostSampler { pid in hostSnapshot(footprint: pid == nil ? nil : footprint.current, pressure: hostPressure.current) },
                effector: EngineAwareEffector(recorder: router, engine: engine),
                maintenance: nil, activity: activity, clock: clock,
                historyCapacity: historyCapacity, recentEventCapacity: 50, csvLog: csv, sink: sink)
        }
    }

    /// Records actions and applies lifecycle ones to the fake engine.
    struct EngineAwareEffector: MemoryEffector {
        let recorder: EffectorRouter
        let engine: FakeEngineControl
        func handles(_ action: GovernorAction) -> Bool { true }
        func apply(_ action: GovernorAction) async throws -> EffectorOutcome {
            let o = try await recorder.apply(action)
            if [.freeze, .thaw, .hibernate, .resume].contains(action) { return try await EngineEffector(engine: engine).apply(action) }
            return o
        }
    }

    @Test func tickSamplesEvaluatesAndEmitsEvents() async throws {
        let rig = Rig()
        let stream = await rig.governor.events()
        rig.guestAvail.set(0.05)
        let d = try #require(await rig.governor.tick())
        #expect(d.level == .critical)
        #expect(rig.effector.applied.current == [.trimMemory(level: .complete, packages: [])])
        // Not due yet → nothing evaluated.
        #expect(await rig.governor.tick() == nil)
        rig.clock.advance(by: .seconds(5))
        #expect(await rig.governor.tick() != nil)
        await rig.governor.stop()
        var kinds: [String] = []
        for await e in stream {
            switch e.kind {
            case .sampled: kinds.append("sampled")
            case .stateChanged: kinds.append("state")
            case .tierChanged: kinds.append("tier")
            case .actionPlanned: kinds.append("planned")
            case .actionApplied: kinds.append("applied")
            default: kinds.append("other")
            }
        }
        #expect(kinds.prefix(5) == ["state", "sampled", "tier", "planned", "applied"])
        #expect(kinds.filter { $0 == "sampled" }.count == 2)
        let status = await rig.governor.status()
        #expect(status.samplesTaken == 2)
        #expect(status.actionsApplied == 1)
        #expect(status.level == .critical)
        #expect(status.lastSample?.guestAvailableBytes != nil)
    }

    @Test func effectorErrorsAreReportedAndBackedOff() async throws {
        struct Failing: MemoryEffector {
            func handles(_ action: GovernorAction) -> Bool { true }
            func apply(_ action: GovernorAction) async throws -> EffectorOutcome { throw EmuuError.deviceNotReady(.emulator(consolePort: 5580)) }
        }
        let clock = FakeClock()
        var cfg = GovernorConfig.preset(.balanced)
        cfg.escalationConfirmSamples = 1
        let sink = RingBufferEventSink(capacity: 1000)
        let g = MemoryGovernor(instanceID: testID, config: cfg, engine: FakeEngineControl(instanceID: testID),
                               guestSampler: ScriptedGuestSampler { GuestSnapshot(memory: guest(available: 0.20)) },
                               hostSampler: ScriptedHostSampler { _ in hostSnapshot(footprint: gib) },
                               effector: Failing(), maintenance: nil, activity: FakeActivity(), clock: clock, sink: sink)
        for _ in 0..<(6 * 60) { // 1 h in 10 s steps
            await g.tick()
            clock.advance(by: .seconds(10))
        }
        let failures = sink.events.filter { if case .actionFailed = $0.kind { return true } else { return false } }
        // trim cooldown 3 min doubling per failure: 0, 6, 18, 42 min… → 4 attempts within the hour.
        #expect(failures.count == 4)
        #expect(await g.status().actionsFailed == 4)
    }

    @Test func guestSampleFailureStillSamplesHost() async throws {
        let clock = FakeClock()
        let g = MemoryGovernor(instanceID: testID, config: .preset(.balanced), engine: FakeEngineControl(instanceID: testID),
                               guestSampler: ScriptedGuestSampler { throw EmuuError.deviceNotReady(.emulator(consolePort: 5580)) },
                               hostSampler: ScriptedHostSampler { _ in hostSnapshot(footprint: 12 * gib) },
                               effector: RecordingEffector(), maintenance: nil, activity: FakeActivity(), clock: clock)
        let first = try #require(await g.tick())
        #expect(first.level == .normal)          // guest level: no guest data
        #expect(first.hostLevel == .elevated)    // footprint signal alone is capped at elevated (host level)
        clock.advance(by: .seconds(30))
        let d = try #require(await g.tick())
        #expect(d.level == .normal)
        #expect(d.hostLevel == .elevated)
        #expect(d.actions.isEmpty)        // host pressure never drives guest actions; no guest → tiers paused
        let s = await g.status()
        #expect(s.consecutiveGuestSampleFailures == 2)
        #expect(s.lastSample?.engineFootprintBytes == 12 * gib)
    }

    @Test func loopRunsWithAdaptiveIntervalAndNudge() async throws {
        let rig = Rig()
        rig.activity.set(visible: true)
        await rig.governor.start()
        #expect(await rig.governor.isRunning)
        #expect(await rig.clock.waitForSleepers(1))
        #expect(await rig.governor.status().samplesTaken == 1)
        // Calm → 30 s interval: 29 s is not enough.
        rig.clock.advance(by: .seconds(29))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await rig.governor.status().samplesTaken == 1)
        rig.clock.advance(by: .seconds(1))
        #expect(await waitUntil { await rig.governor.status().samplesTaken == 2 })
        // Hide + freeze via engine; nudge wakes the loop without advancing time.
        rig.activity.set(visible: false)
        try await rig.engine.freeze()
        rig.governor.nudge()
        #expect(await waitUntil { await rig.governor.status().engineState == .frozen })
        // While frozen, the loop polls activity every 1 s and thaws when visible.
        let samples = await rig.governor.status().samplesTaken
        #expect(!rig.effector.applied.current.contains(.thaw))
        rig.activity.set(visible: true)
        #expect(await rig.clock.waitForSleepers(1))
        rig.clock.advance(by: .seconds(1))
        #expect(await waitUntil { rig.effector.applied.current.contains(.thaw) })
        #expect(await rig.engine.state() == .running)
        #expect(await rig.governor.status().samplesTaken >= samples)
        await rig.governor.stop()
        #expect(await rig.governor.isRunning == false)
        #expect(await rig.governor.subscriberCount == 0)
    }

    @Test func eventSubscribersAreRemovedWhenCancelled() async throws {
        let rig = Rig()
        let t = Task { for await _ in await rig.governor.events() {} }
        #expect(await waitUntil { await rig.governor.subscriberCount == 1 })
        t.cancel()
        #expect(await waitUntil { await rig.governor.subscriberCount == 0 })
    }

    /// Three simulated days: daytime use with pressure waves, nights hidden (freeze → hibernate),
    /// mornings resume. Checks bounded memory, sane action counts and no action storms.
    @Test func multiDaySimulationIsBoundedAndCalm() async throws {
        let sink = RingBufferEventSink(capacity: 100_000)
        let rig = Rig(historyCapacity: 500, sink: sink)
        let start = rig.clock.monotonicNow()
        let step: Duration = .seconds(10)
        let days = 3
        var ticks = 0
        while rig.clock.monotonicNow() - start < .hours(24 * days) {
            let t = rig.clock.monotonicNow() - start
            let hourOfDay = Int(t.timeInterval / 3600) % 24
            let day = hourOfDay >= 8 && hourOfDay < 23
            rig.activity.set(visible: day)
            if day { rig.activity.interact(at: rig.clock.monotonicNow()) }
            // Pressure wave 14:00–15:00 every day; slow footprint creep during the day.
            let minuteOfDay = Int(t.timeInterval / 60) % (24 * 60)
            rig.guestAvail.set(hourOfDay == 14 ? (minuteOfDay % 60 < 30 ? 0.10 : 0.18) : 0.45)
            rig.footprint.set(2 * gib + UInt64(minuteOfDay) * 64 * 1024)
            await rig.governor.tick()
            ticks += 1
            rig.clock.advance(by: step)
        }
        #expect(ticks == days * 24 * 360)
        let history = await rig.governor.history()
        #expect(history.count == 500)
        #expect(await rig.governor.recentEvents().count == 50)

        let actions = rig.effector.applied.current
        let freezes = actions.filter { $0 == .freeze }.count
        let hibernates = actions.filter { $0 == .hibernate }.count
        let resumes = actions.filter { $0 == .resume }.count
        // The run starts at 00:00 (hidden): freezes at 00:05 and every 23:05 → days + 1 within 72 h;
        // hibernate 2 h after each freeze except the last (would be at 73 h); resume every 08:00.
        #expect(freezes == days + 1)
        #expect(hibernates == days)
        #expect(resumes == days)
        let pressure = actions.filter { [.trim, .killBackground, .reclaim].contains($0.tier) }
        #expect(pressure.count >= days)   // each wave handled
        #expect(pressure.count <= days * 24)

        // No storms: at most maxActionsPerHour escalating actions in any rolling hour.
        let applied = sink.events.compactMap { e -> Date? in
            if case .actionPlanned(let a, _) = e.kind, !a.isReversal { return e.timestamp } else { return nil }
        }
        let maxPerHour = GovernorConfig.preset(.balanced).maxActionsPerHour
        for (i, d) in applied.enumerated() {
            let inWindow = applied[i...].prefix { $0.timeIntervalSince(d) < 3600 }.count
            #expect(inWindow <= maxPerHour)
        }
        // Adaptive interval: calm 30 s, frozen/hibernated host-only 60 s → far fewer samples than 10 s ticks.
        #expect(await rig.governor.status().samplesTaken < ticks / 2)
    }

    @Test func csvLogReceivesSamples() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("emuu-gov-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let csv = SampleCSVLog(url: dir.appendingPathComponent("m.csv"))
        let rig = Rig(csv: csv)
        for _ in 0..<3 {
            await rig.governor.tick()
            rig.clock.advance(by: .seconds(30))
        }
        await rig.governor.stop()
        let lines = try String(contentsOf: dir.appendingPathComponent("m.csv"), encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 4)
        #expect(lines[1].contains(",normal,0,"))
    }

    @Test func appBreakdownIsOnDemand() async throws {
        let rig = Rig()
        #expect(try await rig.governor.appBreakdown().first?.packageName == "com.example")
    }
}

/// Polls `condition` (real time) for up to 5 s.
func waitUntil(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<500 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
