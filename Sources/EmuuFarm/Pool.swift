import Foundation
import EmuuBase

/// Engine-level operations the pool needs for one device. `LiveFarmDriver` implements them with real engines;
/// tests use a fake so the pool logic runs at N = 8–16 without emulators.
public protocol FarmDeviceDriver: Sendable {
    /// APFS-clone the golden into `instance` (console port `consolePort`), start the engine (quick boot from the
    /// golden's snapshot) and wait until adb-ready. Returns the engine pid.
    func provision(instance: String, consolePort: Int, golden: GoldenRecord) async throws -> Int32
    /// Back to the golden state in the running engine (console `avd snapshot load default_boot`), adb-ready.
    func reset(instance: String) async throws
    /// Kill the engine (no snapshot save) and delete the clone. Never throws: best effort, logged.
    func destroy(instance: String) async
    func health(_ device: FarmDevice, golden: GoldenRecord, deep: Bool) async -> HealthReport
    func freeze(instance: String) async throws
    func thaw(instance: String) async throws
    func reconnectADB(serial: String) async
    func isPortFree(_ port: Int) -> Bool
    func isAlive(_ pid: Int32) -> Bool
    func hostFacts() -> HostFacts
}

/// Tunables of the pool loop.
public struct PoolTimings: Sendable, Hashable {
    /// Health check interval for idle ready devices.
    public var idleHealthInterval: TimeInterval = 15
    /// Health check interval for leased devices (cheap probes only, so a running test is not disturbed).
    public var leasedHealthInterval: TimeInterval = 15
    /// Consecutive bad checks before a *leased* device is declared lost (a dead engine counts at once): a test
    /// that briefly saturates the guest must not lose its device.
    public var leasedConfirmations: Int = 2
    /// Every Nth idle check also runs the deep (UI) probe.
    public var deepEvery: Int = 4
    /// After a resume/reset the device must still be healthy (same boot id) this long later before it is handed
    /// out: a guest that restarts right after a snapshot load (seen once in 7 resumes before) is caught here.
    public var settle: Duration = .seconds(3)
    /// Provisioning attempts per device before it is marked failed.
    public var maxProvisionAttempts: Int = 3

    public init() {}
}

/// The pool daemon's brain: keeps `size` warm devices, resets released ones, health-checks and heals.
/// `tick()` is one non-blocking scheduling pass; long operations run as tasks (one per device at a time).
public actor PoolController {
    public let store: FarmStateStore
    public let driver: any FarmDeviceDriver
    public let golden: GoldenRecord
    public let cost: DeviceCost
    public let capacityPolicy: CapacityPolicy
    public let healPolicy: SelfHealPolicy
    public let timings: PoolTimings
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async -> Void
    private let log = EmuuLogger(category: "farm.pool")

    private var busy: [String: Task<Void, Never>] = [:]
    private var healState: [String: SelfHealState] = [:]
    private var lastCheck: [String: Date] = [:]
    private var checks: [String: Int] = [:]
    private var detectedAt: [String: Date] = [:]
    private var provisionFailures: [String: Int] = [:]
    private var badStreak: [String: Int] = [:]

    public init(store: FarmStateStore, driver: any FarmDeviceDriver, golden: GoldenRecord, cost: DeviceCost,
                capacityPolicy: CapacityPolicy = .default, healPolicy: SelfHealPolicy = SelfHealPolicy(),
                timings: PoolTimings = PoolTimings(),
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.store = store
        self.driver = driver
        self.golden = golden
        self.cost = cost
        self.capacityPolicy = capacityPolicy
        self.healPolicy = healPolicy
        self.timings = timings
        self.now = now
        self.sleep = sleep
    }

    enum Job: Sendable {
        case provision(port: Int)
        case reset
        case recycle(port: Int)
        case health(deep: Bool)
        case heal(HealStep, reason: String)
        case freeze
    }

    /// One scheduling pass. Returns false once `farm down` was requested and everything is torn down.
    @discardableResult
    public func tick() async -> Bool {
        let t = now()
        var jobs: [(String, Job)] = []
        var stop = false
        do {
            try store.update { s in
                LeaseBook.expire(&s, now: t, isAlive: driver.isAlive)
                if s.stopRequested { stop = true; return }
                addDevicesIfNeeded(&s, now: t)
                jobs = schedule(&s, now: t)
            }
        } catch {
            log.error("pool state update failed: \(describe(error))")
            return true
        }
        if stop {
            await shutdown()
            return false
        }
        for (name, job) in jobs { launch(name, job) }
        return true
    }

    /// Waits until no device operation is running (tests, shutdown).
    public func waitIdle() async {
        while !busy.isEmpty {
            let tasks = Array(busy.values)
            for task in tasks { await task.value }
        }
    }

    /// Destroys every device and removes the pool state.
    public func shutdown() async {
        for task in busy.values { task.cancel() }
        await waitIdle()
        let names = ((try? store.read())?.devices ?? []).map(\.instance)
        await withTaskGroup(of: Void.self) { group in
            for n in names { group.addTask { await self.driver.destroy(instance: n) } }
        }
        store.remove()
    }

    // MARK: scheduling (runs inside the state lock)

    private func addDevicesIfNeeded(_ s: inout FarmState, now t: Date) {
        let live = s.devices.filter { $0.state != .failed }.count
        var missing = s.size - live
        guard missing > 0 else { s.capacityNote = nil; return }
        var running = live
        while missing > 0 {
            let report = CapacityGuard.evaluate(host: driver.hostFacts(), cost: cost, running: running, policy: capacityPolicy)
            if !report.admitNow && !s.policy.overrideCapacity {
                if s.capacityNote != report.admitReason { s.log("capacity", "waiting: \(report.admitReason)", at: t) }
                s.capacityNote = report.admitReason
                return
            }
            let reserved = Set(s.devices.map(\.consolePort))
            guard let port = FarmPorts.allocate(count: 1, reserved: reserved, isFree: driver.isPortFree).first else {
                s.capacityNote = "no free console port in 5554–5584 (adb's scan range; 16 devices max)"
                return
            }
            let used = Set(s.devices.map(\.instance))
            let index = (1...).first { !used.contains(FarmIDs.deviceInstance(pool: s.pool, index: $0)) }!
            let name = FarmIDs.deviceInstance(pool: s.pool, index: index)
            s.devices.append(FarmDevice(instance: name, consolePort: port, state: .starting, since: t))
            s.log("add", device: name, "new device on port \(port)", at: t)
            missing -= 1
            running += 1
        }
        s.capacityNote = nil
    }

    private func schedule(_ s: inout FarmState, now t: Date) -> [(String, Job)] {
        var jobs: [(String, Job)] = []
        for d in s.devices where busy[d.instance] == nil {
            switch d.state {
            case .starting:
                jobs.append((d.instance, .provision(port: d.consolePort)))
            case .resetting:
                jobs.append((d.instance, d.recycleNext ? .recycle(port: d.consolePort) : .reset))
            case .replacing where d.leaseID == nil:
                jobs.append((d.instance, .recycle(port: d.consolePort)))
            case .unhealthy:
                var hs = healState[d.instance] ?? SelfHealState()
                let e = HealthEvaluation(verdict: d.lastHealth?.verdict ?? .hung, reason: d.lastHealth?.reason ?? "unhealthy",
                                         fault: faultOf(d))
                if !s.policy.selfHeal {
                    break
                }
                // Unhealthy idle devices: the pool can always fall back to a fresh clone, so confirmation was
                // already done by the check that marked it; act now.
                var policy = healPolicy
                policy.confirmations = 1
                switch hs.observe(e, farmDevice: true, now: t, policy: policy) {
                case .heal(let step, let reason): jobs.append((d.instance, .heal(step, reason: reason)))
                case .giveUp(let reason):
                    s.withDevice(d.instance) { $0.state = .failed; $0.note = reason }
                    s.log("give-up", device: d.instance, reason, at: t)
                case .none: break
                }
                healState[d.instance] = hs
            case .ready:
                if let after = s.policy.freezeIdleAfter, t.timeIntervalSince(d.since) >= after {
                    jobs.append((d.instance, .freeze))
                } else if due(d.instance, interval: timings.idleHealthInterval, now: t) {
                    let n = (checks[d.instance] ?? 0) + 1
                    jobs.append((d.instance, .health(deep: n % max(1, timings.deepEvery) == 0)))
                }
            case .leased:
                if due(d.instance, interval: timings.leasedHealthInterval, now: t) { jobs.append((d.instance, .health(deep: false))) }
            case .frozen, .failed, .replacing:
                break
            }
        }
        return jobs
    }

    private var lastFault: [String: HealthFault] = [:]
    private func faultOf(_ d: FarmDevice) -> HealthFault? { lastFault[d.instance] ?? .guestUnresponsive }

    private func due(_ name: String, interval: TimeInterval, now t: Date) -> Bool {
        guard let last = lastCheck[name] else { return true }
        return t.timeIntervalSince(last) >= interval
    }

    private func launch(_ name: String, _ job: Job) {
        if case .health = job { lastCheck[name] = now(); checks[name, default: 0] += 1 }
        busy[name] = Task { [weak self] in
            await self?.run(name, job)
            await self?.done(name)
        }
    }

    private func done(_ name: String) { busy[name] = nil }

    // MARK: jobs

    private func run(_ name: String, _ job: Job) async {
        switch job {
        case .provision(let port): await provision(name, port: port, recycled: false)
        case .recycle(let port):
            await driver.destroy(instance: name)
            await provision(name, port: port, recycled: true)
        case .reset: await reset(name)
        case .health(let deep): await health(name, deep: deep)
        case .heal(let step, let reason): await heal(name, step: step, reason: reason)
        case .freeze:
            do {
                try await driver.freeze(instance: name)
                update { s in s.withDevice(name) { if $0.state == .ready { $0.state = .frozen } } }
            } catch {
                update { s in s.withDevice(name) { $0.since = self.now() } }
            }
        }
    }

    private func provision(_ name: String, port: Int, recycled: Bool) async {
        let t0 = now()
        do {
            // The port may have been taken by a non-Emuu emulator since it was planned.
            var p = port
            if !driver.isPortFree(p) || !driver.isPortFree(p + 1) {
                let reserved = Set(((try? store.read())?.devices ?? []).map(\.consolePort))
                guard let alt = FarmPorts.allocate(count: 1, reserved: reserved, isFree: driver.isPortFree).first else {
                    throw EmuuError.engine("no free console port in 5554–5584")
                }
                p = alt
                update { s in s.withDevice(name) { $0.consolePort = alt } }
            }
            let pid = try await driver.provision(instance: name, consolePort: p, golden: golden)
            let ok = await settleCheck(name, port: p, pid: pid)
            guard ok.verdict == .healthy else {
                throw EmuuError.engine("not healthy after resume: \(ok.reason)")
            }
            provisionFailures[name] = nil
            let secs = now().timeIntervalSince(t0)
            update { s in
                s.withDevice(name) { d in
                    d.state = .ready
                    d.enginePID = pid
                    d.since = self.now()
                    d.recycleNext = false
                    d.failedRecoveries = 0
                    d.lastHealth = ok.summary
                    if recycled { d.replacements += 1 }
                }
                if recycled { s.counters.replacements += 1 }
                s.log(recycled ? "recycled" : "ready", device: name, String(format: "adb-ready in %.2f s", secs), at: self.now())
            }
            noteRecovered(name)
        } catch {
            await driver.destroy(instance: name)
            let n = (provisionFailures[name] ?? 0) + 1
            provisionFailures[name] = n
            let msg = describe(error)
            update { s in
                s.withDevice(name) { d in
                    d.state = n >= self.timings.maxProvisionAttempts ? .failed : .starting
                    d.enginePID = nil
                    d.note = msg
                }
                s.log("provision-failed", device: name, "attempt \(n): \(msg)", at: self.now())
            }
            if n < timings.maxProvisionAttempts { await sleep(.seconds(min(30, 2 * n))) }
        }
    }

    private func reset(_ name: String) async {
        let t0 = now()
        do {
            try await driver.reset(instance: name)
            guard let d = (try? store.read())?.device(name), let pid = d.enginePID else { throw EmuuError.engine("device vanished") }
            let ok = await settleCheck(name, port: d.consolePort, pid: pid)
            guard ok.verdict == .healthy else { throw EmuuError.engine("not healthy after reset: \(ok.reason)") }
            let secs = now().timeIntervalSince(t0)
            update { s in
                s.withDevice(name) { d in
                    d.state = .ready
                    d.since = self.now()
                    d.resets += 1
                    d.lastHealth = ok.summary
                }
                s.counters.resets += 1
                s.log("reset", device: name, String(format: "golden state, adb-ready in %.2f s", secs), at: self.now())
            }
            noteRecovered(name)
        } catch {
            let msg = describe(error)
            update { s in
                s.counters.resetFailures += 1
                s.withDevice(name) { d in d.recycleNext = true; d.state = .resetting; d.note = msg }
                s.log("reset-failed", device: name, "\(msg); recycling", at: self.now())
            }
        }
    }

    /// Health right after a resume/reset, and again `settle` later: same boot id as the golden both times.
    private func settleCheck(_ name: String, port: Int, pid: Int32) async -> HealthReport {
        var probe = FarmDevice(instance: name, consolePort: port, state: .starting, since: now())
        probe.enginePID = pid
        let first = await driver.health(probe, golden: golden, deep: false)
        guard first.verdict == .healthy else { return first }
        await sleep(timings.settle)
        let second = await driver.health(probe, golden: golden, deep: false)
        if second.fault == .guestRebooted {
            update { s in
                s.counters.rebootsDetected += 1
                s.log("reboot-detected", device: name, "guest restarted within \(timings.settle) of resume/reset", at: self.now())
            }
        }
        return second
    }

    private func health(_ name: String, deep: Bool) async {
        guard let d = (try? store.read())?.device(name), d.state == .ready || d.state == .leased else { return }
        let report = await driver.health(d, golden: golden, deep: deep)
        let t = now()
        var bad = report.verdict == .hung || report.verdict == .dead || (report.verdict == .degraded && report.fault != .notBooted)
        if let f = report.fault { lastFault[name] = f }
        badStreak[name] = bad ? (badStreak[name] ?? 0) + 1 : 0
        if bad, d.state == .leased, report.verdict != .dead, (badStreak[name] ?? 0) < timings.leasedConfirmations {
            update { s in s.log("suspect", device: name, lease: d.leaseID, "\(report.verdict.rawValue): \(report.reason) (confirming)", at: t) }
            lastCheck[name] = t.addingTimeInterval(-timings.leasedHealthInterval + 5) // re-check in ~5 s
            bad = false
            return
        }
        if bad { badStreak[name] = 0 }
        update { s in
            guard let cur = s.device(name), cur.state == d.state else { return } // changed meanwhile (leased/released)
            s.withDevice(name) { $0.lastHealth = report.summary }
            guard bad else { return }
            s.counters.hangsDetected += 1
            if report.fault == .guestRebooted { s.counters.rebootsDetected += 1 }
            self.detectedAt[name] = t
            s.log("unhealthy", device: name, lease: cur.leaseID, "\(report.verdict.rawValue): \(report.reason)", at: t)
            if cur.state == .leased {
                switch s.policy.healLeased {
                case .report:
                    LeaseBook.markLost(&s, device: name, reason: report.reason, now: t)
                case .replace:
                    LeaseBook.markLost(&s, device: name, reason: report.reason, now: t)
                    s.withDevice(name) { $0.state = .replacing; $0.note = report.reason }
                case .restart:
                    s.withDevice(name) { $0.note = "healing in place: \(report.reason)" }
                }
            } else {
                s.withDevice(name) { $0.state = .unhealthy; $0.since = t; $0.note = report.reason }
            }
        }
        guard bad, d.state == .leased else { return }
        switch (try? store.read())?.policy.healLeased {
        case .replace?:
            // Free the memory now; the fresh clone is made once the holder releases (or its lease expires).
            await driver.destroy(instance: name)
        case .restart?:
            await heal(name, step: HealLadder.steps(for: report.fault, farmDevice: true).first ?? .reset, reason: report.reason, keepLease: true)
        default:
            break
        }
    }

    private func heal(_ name: String, step: HealStep, reason: String, keepLease: Bool = false) async {
        let t0 = now()
        update { s in s.log("heal", device: name, "\(step.rawValue) (\(reason))", at: t0) }
        do {
            switch step {
            case .thaw: try await driver.thaw(instance: name)
            case .reconnectADB:
                if let d = (try? store.read())?.device(name) { await driver.reconnectADB(serial: d.serial) }
            case .reset, .softReboot, .hardRestart, .coldBoot:
                try await driver.reset(instance: name)
            case .replace:
                guard let d = (try? store.read())?.device(name) else { return }
                await driver.destroy(instance: name)
                let pid = try await driver.provision(instance: name, consolePort: d.consolePort, golden: golden)
                update { s in s.withDevice(name) { $0.enginePID = pid; $0.replacements += 1 }; s.counters.replacements += 1 }
            }
            guard let d = (try? store.read())?.device(name), let pid = d.enginePID else { throw EmuuError.engine("device vanished") }
            let ok = await settleCheck(name, port: d.consolePort, pid: pid)
            guard ok.verdict == .healthy else { throw EmuuError.engine("still \(ok.verdict.rawValue): \(ok.reason)") }
            var hs = healState[name] ?? SelfHealState()
            hs.recordOutcome(success: true)
            healState[name] = hs
            let detected = detectedAt.removeValue(forKey: name)
            update { s in
                s.counters.recoveries += 1
                s.withDevice(name) { d in
                    if !keepLease { d.state = .ready }
                    d.since = self.now()
                    d.failedRecoveries = 0
                    d.lastHealth = ok.summary
                    d.note = nil
                }
                let detail = String(format: "%@ fixed it in %.1f s", step.rawValue, self.now().timeIntervalSince(t0))
                    + (detected.map { String(format: " (%.1f s after detection)", self.now().timeIntervalSince($0)) } ?? "")
                s.log("recovered", device: name, detail, at: self.now())
            }
        } catch {
            let msg = describe(error)
            update { s in
                s.withDevice(name) { d in
                    d.failedRecoveries += 1
                    if !keepLease { d.state = .unhealthy }
                    d.note = "\(step.rawValue) failed: \(msg)"
                }
                s.log("heal-failed", device: name, "\(step.rawValue): \(msg)", at: self.now())
            }
        }
    }

    private func noteRecovered(_ name: String) {
        healState[name] = nil
        lastFault[name] = nil
    }

    private func update(_ body: (inout FarmState) -> Void) {
        do { try store.update(body) } catch { log.error("pool state update failed: \(describe(error))") }
    }
}

func describe(_ error: Error) -> String {
    if let e = error as? LocalizedError, let d = e.errorDescription { return d }
    return "\(error)"
}
