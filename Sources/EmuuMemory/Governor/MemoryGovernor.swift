import Foundation
import EmuuBase

/// Snapshot of the governor for UI/CLI.
public struct GovernorStatus: Sendable, Hashable {
    public var instanceID: InstanceID
    public var profile: MemoryProfile
    public var engineState: InstanceState?
    public var level: MemoryPressureLevel
    public var tier: GovernorTier
    public var disabledTiers: Set<GovernorTier>
    public var creepActive: Bool
    public var lastSample: HistoryPoint?
    public var samplesTaken: Int
    public var actionsApplied: Int
    public var actionsFailed: Int
    public var maintenanceRuns: Int
    public var consecutiveGuestSampleFailures: Int
    public var isRunning: Bool
    /// Monotonic time adb activity from other tools was last detected (`ADBActivityDetector`), if ever.
    public var lastADBActivity: Duration?
    public var automationMode: Bool
}

/// Drives sampling → policy → effectors for one instance.
///
/// - Adaptive interval: the policy picks calm/elevated/pressure intervals; while frozen or
///   hibernated no adb traffic happens, only cheap activity polls (to thaw/resume promptly) and a
///   slow host-only sample. `nudge()` wakes the loop immediately (e.g. window shown).
/// - O(1) memory over days: history and recent events are fixed-capacity ring buffers; the policy's
///   trend windows are bounded too.
/// - Events go to every `events()` subscriber (each buffered to the newest 256) and to an optional sink.
public actor MemoryGovernor {
    public let instanceID: InstanceID
    public let engine: any EngineControl
    public let guestSampler: (any GuestMemorySampling)?
    public let hostSampler: any HostMemorySampling
    public let effector: any MemoryEffector
    public let maintenance: MaintenanceRunner?
    public let activity: any GovernorActivitySource
    public let clock: any EmuuClock
    public let csvLog: SampleCSVLog?
    public let sink: (any GovernorEventSink)?

    private var policy: GovernorPolicy
    private var historyBuffer: RingBuffer<HistoryPoint>
    private var recent: RingBuffer<GovernorEvent>
    private var subscribers: [UInt64: AsyncStream<GovernorEvent>.Continuation] = [:]
    private var nextSubscriberID: UInt64 = 0
    private var loopTask: Task<Void, Never>?
    private let wake = WakeSignal()
    private let log = EmuuLogger(category: "memory.governor")

    private var lastSampleAt: Duration?
    private var nextSampleIn: Duration = .zero
    private var lastEngineState: InstanceState?
    private var lastDecision: PolicyDecision?
    private var counters = (samples: 0, applied: 0, failed: 0, maintenance: 0, guestFailures: 0)
    private var adbDetector = ADBActivityDetector()
    private var lastADBActivityAt: Duration?
    /// Guest kernel boot id from the last sample (reboot detection).
    private var lastBootID: String?
    /// The last guest/engine actions with wall-clock times (bounded), logged when the guest reboots.
    private var actionJournal = RingBuffer<String>(capacity: 12)

    public init(instanceID: InstanceID, config: GovernorConfig, engine: any EngineControl,
                guestSampler: (any GuestMemorySampling)?, hostSampler: any HostMemorySampling,
                effector: any MemoryEffector, maintenance: MaintenanceRunner?,
                activity: any GovernorActivitySource, clock: any EmuuClock = SystemClock(),
                historyCapacity: Int = 2880, recentEventCapacity: Int = 256,
                csvLog: SampleCSVLog? = nil, sink: (any GovernorEventSink)? = nil) {
        self.instanceID = instanceID
        self.engine = engine
        self.guestSampler = guestSampler
        self.hostSampler = hostSampler
        self.effector = effector
        self.maintenance = maintenance
        self.activity = activity
        self.clock = clock
        self.csvLog = csvLog
        self.sink = sink
        self.policy = GovernorPolicy(config: config)
        self.historyBuffer = RingBuffer(capacity: max(1, historyCapacity))
        self.recent = RingBuffer(capacity: max(1, recentEventCapacity))
    }

    /// Convenience wiring of the standard samplers/effectors around a `DeviceShell` + `EngineControl`.
    public static func standard(instanceID: InstanceID, config: GovernorConfig, engine: any EngineControl,
                                shell: any DeviceShell, activity: any GovernorActivitySource,
                                clock: any EmuuClock = SystemClock(), hostSampler: (any HostMemorySampling)? = nil,
                                csvLog: SampleCSVLog? = nil, sink: (any GovernorEventSink)? = nil,
                                protected: ProtectedPackages = .default) -> MemoryGovernor {
        let guestEffector = GuestEffector(shell: shell, protected: protected)
        let engineEffector = EngineEffector(engine: engine)
        return MemoryGovernor(
            instanceID: instanceID, config: config, engine: engine,
            guestSampler: GuestSampler(shell: shell, clock: clock),
            hostSampler: hostSampler ?? HostSampler(clock: clock),
            effector: EffectorRouter([guestEffector, engineEffector]),
            maintenance: MaintenanceRunner(guest: guestEffector, engine: engineEffector),
            activity: activity, clock: clock, csvLog: csvLog, sink: sink)
    }

    // MARK: lifecycle

    public var isRunning: Bool { loopTask != nil }

    /// Starts the background loop (idempotent).
    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Stops the loop and waits for it to finish. Subscribers' streams finish.
    public func stop() async {
        let t = loopTask
        loopTask = nil
        t?.cancel()
        await t?.value
        for c in subscribers.values { c.finish() }
        subscribers.removeAll()
        csvLog?.close()
    }

    /// Wakes the loop now (visibility change, user input, host pressure notification).
    public nonisolated func nudge() { wake.signal() }

    private func runLoop() async {
        log.info("governor started for \(instanceID) (\(policy.config.profile.rawValue))")
        while !Task.isCancelled {
            _ = await tick()
            let wait = loopWait()
            await sleepOrWake(wait)
        }
        log.info("governor stopped for \(instanceID)")
    }

    private func loopWait() -> Duration {
        switch lastEngineState {
        case .frozen?, .hibernated?:
            return policy.config.sampling.activityPoll
        default:
            let remaining = nextSampleIn - (clock.monotonicNow() - (lastSampleAt ?? clock.monotonicNow()))
            return max(.milliseconds(100), remaining)
        }
    }

    private func sleepOrWake(_ duration: Duration) async {
        let clock = self.clock
        let wake = self.wake
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await clock.sleep(for: duration) }
            group.addTask { await wake.wait() }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: events

    /// A new event stream. Each subscriber keeps at most the newest 256 undelivered events.
    public func events() -> AsyncStream<GovernorEvent> {
        let id = nextSubscriberID
        nextSubscriberID += 1
        let (stream, cont) = AsyncStream<GovernorEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        subscribers[id] = cont
        cont.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UInt64) { subscribers[id] = nil }

    public var subscriberCount: Int { subscribers.count }

    private func emit(_ kind: GovernorEvent.Kind) {
        let e = GovernorEvent(instanceID: instanceID, timestamp: clock.now(), kind: kind)
        recent.append(e)
        sink?.record(e)
        for c in subscribers.values { c.yield(e) }
    }

    // MARK: queries

    public func history() -> [HistoryPoint] { historyBuffer.elements }
    public var historyCount: Int { historyBuffer.count }
    public func recentEvents() -> [GovernorEvent] { recent.elements }
    public var config: GovernorConfig { policy.config }

    public func status() -> GovernorStatus {
        GovernorStatus(instanceID: instanceID, profile: policy.config.profile, engineState: lastEngineState,
                       level: policy.level, tier: lastDecision?.tier ?? .none, disabledTiers: policy.disabledTiers,
                       creepActive: policy.creepActive, lastSample: historyBuffer.last, samplesTaken: counters.samples,
                       actionsApplied: counters.applied, actionsFailed: counters.failed, maintenanceRuns: counters.maintenance,
                       consecutiveGuestSampleFailures: counters.guestFailures, isRunning: loopTask != nil,
                       lastADBActivity: lastADBActivityAt, automationMode: policy.config.automationMode)
    }

    public func updateConfig(_ config: GovernorConfig) {
        policy.updateConfig(config)
        nudge()
    }

    /// Re-enables tiers previously reported unsupported.
    public func resetCapabilities() { policy.resetCapabilities() }

    /// Expensive per-app breakdown (`dumpsys meminfo -c`), on demand only.
    public func appBreakdown() async throws -> [AppMemoryUsage] {
        guard let g = guestSampler else { throw EmuuError.unsupported("no guest sampler") }
        return try await g.appBreakdown()
    }

    // MARK: one iteration

    /// Runs one governor iteration: sample if due, evaluate the policy, apply actions/maintenance.
    /// Returns nil when nothing was evaluated (running and no sample due yet).
    @discardableResult
    public func tick() async -> PolicyDecision? {
        let now = clock.monotonicNow()
        let state = await engine.state()
        if state != lastEngineState {
            emit(.stateChanged(state))
            if lastEngineState == .hibernated || lastEngineState == .frozen { lastSampleAt = nil }
            lastEngineState = state
        }
        let visible = await activity.isDisplayVisible(instanceID)
        var lastInput = await activity.lastUserInteraction(instanceID)

        let due = lastSampleAt.map { now - $0 >= nextSampleIn } ?? true
        let idleState = state == .frozen || state == .hibernated
        if !due && !idleState { return nil }

        var guest: GuestSnapshot?
        var host: HostSnapshot?
        if due {
            let pid = state.isRunningEngine ? await engine.enginePID() : nil
            host = hostSampler.sample(enginePID: pid)
            if state == .running, let gs = guestSampler {
                do {
                    guest = try await gs.sample()
                    counters.guestFailures = 0
                } catch {
                    counters.guestFailures += 1
                    if counters.guestFailures == 1 || counters.guestFailures % 20 == 0 {
                        log.warning("guest sample failed (\(counters.guestFailures)x): \(error)")
                    }
                }
            }
            lastSampleAt = now
            counters.samples += 1
        }

        if let g = guest, let id = g.bootID {
            if let last = lastBootID, last != id {
                let up = g.uptimeSeconds.map { String(format: "%.0f s", $0) } ?? "?"
                let recentActions = actionJournal.elements
                log.warning("guest rebooted under a running engine (boot id changed; guest uptime \(up)); last governor actions: \(recentActions.isEmpty ? "none" : recentActions.joined(separator: " | "))")
                emit(.guestRebooted(uptime: .seconds(g.uptimeSeconds ?? 0), recentActions: recentActions))
            }
            lastBootID = id
        }
        if let g = guest, adbDetector.update(shellSessions: g.adbShellSessions, lastPID: g.lastPID, at: now) {
            if lastADBActivityAt == nil { log.info("adb activity from other tools detected; counting it as user activity") }
            lastADBActivityAt = now
        }
        // adb traffic from other tools (tests, scripts) counts as activity: no idle freeze while it lasts.
        if let a = lastADBActivityAt { lastInput = max(lastInput ?? a, a) }

        let input = PolicyInput(now: now, engineState: state, guest: guest?.memory,
                                foregroundPackages: guest?.foregroundPackages ?? [], host: host?.hostMemory,
                                isVisible: visible, lastUserInteraction: lastInput)
        var decision = policy.evaluate(input)
        if due {
            nextSampleIn = decision.nextSampleIn
            record(sample: guest, host: host, decision: decision, now: now)
        }
        if let c = decision.tierChange { emit(.tierChanged(from: c.from, to: c.to, reason: c.reason)) }
        if let creep = decision.creep {
            log.notice("memory creep: \(creep.signal.rawValue) \(ByteCount.format(signed: creep.bytesPerHour))/h over \(GovernorPolicy.fmt(creep.window))")
            emit(.creepDetected(bytesPerHour: creep.bytesPerHour, window: creep.window))
        }
        for note in decision.notes { log.debug(note) }

        for planned in decision.actions {
            emit(.actionPlanned(planned.action, reason: planned.reason))
            do {
                let outcome = try await effector.apply(planned.action)
                policy.record(outcome: outcome, for: planned.action)
                counters.applied += outcome.status == .applied ? 1 : 0
                emit(.actionApplied(planned.action, outcome))
                log.info("\(planned.action) → \(outcome.status.rawValue) \(outcome.detail) [\(planned.reason)]")
                actionJournal.append("\(ISO8601DateFormatter().string(from: clock.now())) \(planned.action) → \(outcome.status.rawValue) \(outcome.detail)")
            } catch {
                policy.recordFailure(for: planned.action)
                counters.failed += 1
                let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                emit(.actionFailed(planned.action, message: msg))
                actionJournal.append("\(ISO8601DateFormatter().string(from: clock.now())) \(planned.action) failed: \(msg)")
                log.warning("\(planned.action) failed: \(msg)")
            }
        }
        // The governor's own guest commands fork processes; never count them as other tools' adb traffic.
        if !decision.actions.isEmpty || decision.maintenance != nil { adbDetector.rebaseline() }
        if decision.actions.contains(where: { [.freeze, .thaw, .hibernate, .resume].contains($0.action) }) {
            // The engine state changed; re-sample right away on the next tick.
            lastSampleAt = nil
        }

        if let plan = decision.maintenance {
            if let runner = maintenance {
                let report = await runner.run(plan)
                policy.recordMaintenance(unsupportedReclaim: report.reclaimUnsupported)
                counters.maintenance += 1
                emit(.maintenanceRan(summary: "\(plan.reason): \(report.summary)"))
                actionJournal.append("\(ISO8601DateFormatter().string(from: clock.now())) maintenance: \(report.summary)")
                log.info("maintenance: \(report.summary)")
            } else {
                decision.maintenance = nil
            }
        }
        lastDecision = decision
        return decision
    }

    private func record(sample guest: GuestSnapshot?, host: HostSnapshot?, decision: PolicyDecision, now: Duration) {
        var p = HistoryPoint(timestamp: clock.now(), monotonic: now, level: decision.level, tier: decision.tier)
        if let g = guest {
            p.guestTotalBytes = g.memory.totalBytes
            p.guestAvailableBytes = g.memory.availableBytes
            p.guestSwapUsedBytes = g.memory.swapUsedBytes
            p.psiSomeAvg10 = g.memory.pressureStall?.someAvg10
            p.cachedProcessCount = g.memory.cachedProcessCount
            p.sampleRoundTrip = g.roundTrip
        }
        if let h = host {
            p.engineFootprintBytes = h.engine?.footprintBytes
            p.engineLifetimeMaxFootprintBytes = h.engine?.lifetimeMaxFootprintBytes
            p.engineCPUPercent = h.engine?.cpuPercent
            p.hostPressure = h.system.pressure
            p.hostFreeBytes = h.system.freeBytes
            p.hostCompressedBytes = h.system.compressedBytes
            p.hostSwapUsedBytes = h.system.swapUsedBytes
        }
        historyBuffer.append(p)
        if let csv = csvLog {
            do { try csv.append(p) } catch { log.warning("CSV log write failed: \(error)") }
        }
        let sample = MemorySample(instanceID: instanceID, timestamp: p.timestamp, monotonic: now,
                                  guest: guest?.memory, host: host?.hostMemory)
        emit(.sampled(sample))
    }
}
