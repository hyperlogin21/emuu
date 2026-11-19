import Foundation
import Testing
import EmuuBase
@testable import EmuuFarm

/// Scriptable driver: devices "boot" instantly; health per instance can be set to fail.
final class FakeFarmDriver: FarmDeviceDriver, @unchecked Sendable {
    struct Calls: Sendable { var provision = 0; var reset = 0; var destroy = 0; var freeze = 0; var thaw = 0; var reconnect = 0 }
    let calls = Locked(Calls())
    let unhealthy = Locked<[String: HealthFault]>([:])
    let failReset = Locked<Set<String>>([])
    let failProvision = Locked<Set<String>>([])
    let host: Locked<HostFacts>
    let busyPorts = Locked<Set<Int>>([])
    private let nextPID = Locked<Int32>(1000)
    let pids = Locked<[String: Int32]>([:])

    init(ramGiB: UInt64 = 96, cores: Int = 32) {
        host = Locked(HostFacts(physicalMemoryBytes: ramGiB << 30, cpuCores: cores, availableBytes: (ramGiB << 30) / 2, pressure: .normal))
    }

    func provision(instance: String, consolePort: Int, golden: GoldenRecord) async throws -> Int32 {
        calls.withLock { $0.provision += 1 }
        if failProvision.current.contains(instance) { throw EmuuError.engine("clone did not resume") }
        let pid = nextPID.withLock { p -> Int32 in p += 1; return p }
        pids.withLock { $0[instance] = pid }
        unhealthy.withLock { $0[instance] = nil }
        return pid
    }
    func reset(instance: String) async throws {
        calls.withLock { $0.reset += 1 }
        if failReset.current.contains(instance) { throw EmuuError.engine("snapshot load failed") }
        unhealthy.withLock { $0[instance] = nil }
    }
    func destroy(instance: String) async {
        calls.withLock { $0.destroy += 1 }
        pids.withLock { $0[instance] = nil }
    }
    func health(_ device: FarmDevice, golden: GoldenRecord, deep: Bool) async -> HealthReport {
        let fault = unhealthy.current[device.instance]
        let e: HealthEvaluation = fault.map { HealthEvaluation(verdict: $0 == .engineDead ? .dead : .hung, reason: "\($0.rawValue)", fault: $0) }
            ?? HealthEvaluation(verdict: .healthy, reason: "ok", fault: nil)
        return HealthReport(instance: device.instance, serial: device.serial, verdict: e.verdict, reason: e.reason, fault: e.fault,
                            checkedAt: Date(), probes: [], bootID: golden.bootID, suggestedStep: nil)
    }
    func freeze(instance: String) async throws { calls.withLock { $0.freeze += 1 } }
    func thaw(instance: String) async throws { calls.withLock { $0.thaw += 1 } }
    func reconnectADB(serial: String) async { calls.withLock { $0.reconnect += 1 } }
    func isPortFree(_ port: Int) -> Bool { !busyPorts.current.contains(port) }
    func isAlive(_ pid: Int32) -> Bool { pid < 900 || pid >= 1000 }
    func hostFacts() -> HostFacts { host.current }
}

private let golden = GoldenRecord(name: "g", sealedAt: Date(), bootID: "boot-1", guestUptimeAtSeal: 150, guestRAMMB: 2048, cores: 2,
                                  gpu: "host", image: "img", lean: false, snapshotBytes: 1 << 30, disabledPackages: [])

private var noFreeze: FarmPolicy { var p = FarmPolicy(); p.freezeIdleAfter = nil; return p }

private func makePool(size: Int, driver: FakeFarmDriver, policy: FarmPolicy = noFreeze,
                      clock: Locked<Date> = Locked(Date())) throws -> (PoolController, FarmStateStore, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("emuu-pool-\(UUID().uuidString)")
    let store = FarmStateStore(farm: FarmPaths(paths: EmuuPaths(root: dir)), pool: "t")
    try store.create(FarmState(pool: "t", golden: "g", size: size, policy: policy, now: clock.current))
    var timings = PoolTimings()
    timings.settle = .zero
    timings.idleHealthInterval = 10
    timings.leasedHealthInterval = 10
    let pool = PoolController(store: store, driver: driver, golden: golden, cost: DeviceCost.estimate(guestRAMMB: 2048, cores: 2),
                              timings: timings, now: { clock.current }, sleep: { _ in })
    return (pool, store, dir)
}

private func settle(_ pool: PoolController, rounds: Int = 3) async {
    for _ in 0..<rounds {
        await pool.tick()
        await pool.waitIdle()
    }
}

@Suite struct PoolControllerTests {
    @Test(arguments: [8, 12, 16])
    func warmsNDevicesOnDistinctPorts(n: Int) async throws {
        let driver = FakeFarmDriver(ramGiB: 96) // 48 GiB allows 10 devices of 2048 MB; 16 need more

        let (pool, store, dir) = try makePool(size: n, driver: driver)
        defer { try? FileManager.default.removeItem(at: dir) }
        await settle(pool)
        let s = try store.read()
        #expect(s.devices.count == n)
        #expect(s.devices.allSatisfy { $0.state == .ready })
        #expect(Set(s.devices.map(\.consolePort)).count == n)
        #expect(s.devices.allSatisfy { FarmPorts.consolePorts.contains($0.consolePort) })
        #expect(driver.calls.current.provision == n)
    }

    @Test func fortyEightGigabytesCapAtTen() async throws {
        let driver = FakeFarmDriver(ramGiB: 48)
        let (pool, store, dir) = try makePool(size: 16, driver: driver)
        defer { try? FileManager.default.removeItem(at: dir) }
        await settle(pool)
        let s = try store.read()
        #expect(s.devices.count == 10)
        #expect(s.capacityNote?.contains("at capacity: 10 of 10") == true)
    }

    @Test func capacityGuardLimitsTheWarmCount() async throws {
        let driver = FakeFarmDriver(ramGiB: 16, cores: 10) // ceiling 2 with the 2.83 GiB estimate
        let (pool, store, dir) = try makePool(size: 6, driver: driver)
        defer { try? FileManager.default.removeItem(at: dir) }
        await settle(pool)
        let s = try store.read()
        #expect(s.devices.count < 6)
        #expect(s.capacityNote?.contains("capacity") == true || s.capacityNote?.contains("available") == true)
    }

    @Test func overrideCapacityStartsThemAnyway() async throws {
        let driver = FakeFarmDriver(ramGiB: 16, cores: 10)
        var policy = noFreeze
        policy.overrideCapacity = true
        let (pool, store, dir) = try makePool(size: 6, driver: driver, policy: policy)
        defer { try? FileManager.default.removeItem(at: dir) }
        await settle(pool)
        #expect(try store.read().devices.filter { $0.state == .ready }.count == 6)
    }

    @Test func skipsPortsTakenByOtherEmulators() async throws {
        let driver = FakeFarmDriver()
        driver.busyPorts.set([5554, 5555, 5559])
        let (pool, store, dir) = try makePool(size: 3, driver: driver)
        defer { try? FileManager.default.removeItem(at: dir) }
        await settle(pool)
        #expect(try store.read().devices.map(\.consolePort).sorted() == [5556, 5560, 5562])
    }

    @Test func releaseResetsAndRecycleReplaces() async throws {
        let driver = FakeFarmDriver()
        let (pool, store, dir) = try makePool(size: 12, driver: driver)
        defer { try? FileManager.default.removeItem(at: dir) }
        await settle(pool)
        var leases: [FarmLease] = []
        for _ in 0..<12 {
            leases.append(try store.update { s in try LeaseBook.acquireSync(&s, holderPID: nil, ttl: 600, now: Date()) { _ in
                HealthSummary(verdict: .healthy, reason: "ok", at: Date()) } })
        }
        #expect(Set(leases.map(\.device)).count == 12)
        for (i, l) in leases.enumerated() {
            try store.update { s in _ = LeaseBook.release(&s, leaseID: l.id, recycle: i % 4 == 0, now: Date()) }
        }
        await settle(pool)
        let s = try store.read()
        #expect(s.devices.allSatisfy { $0.state == .ready })
        #expect(s.counters.resets == 9)
        #expect(s.counters.replacements == 3)
        #expect(driver.calls.current.reset == 9)
    }

    @Test func failedResetFallsBackToRecycle() async throws {
        let driver = FakeFarmDriver()
        let (pool, store, dir) = try makePool(size: 1, driver: driver)
        defer { try? FileManager.default.removeItem(at: dir) }
        await settle(pool)
        let l = try store.update { s in try LeaseBook.acquireSync(&s, holderPID: nil, ttl: 60, now: Date()) { _ in
            HealthSummary(verdict: .healthy, reason: "ok", at: Date()) } }
        driver.failReset.set(["farm-t-1"])
        try store.update { s in _ = LeaseBook.release(&s, leaseID: l.id, recycle: false, now: Date()) }
        await settle(pool, rounds: 4)
        let s = try store.read()
        #expect(s.counters.resetFailures == 1)
        #expect(s.counters.replacements == 1)
        #expect(s.device("farm-t-1")?.state == .ready)
    }

    @Test func idleHangIsHealedByReset() async throws {
        let clock = Locked(Date())
        let driver = FakeFarmDriver()
        let (pool, store, dir) = try makePool(size: 2, driver: driver, clock: clock)
        defer { try? FileManager.default.removeItem(at: dir) }
        await settle(pool)
        driver.unhealthy.withLock { $0["farm-t-2"] = .guestUnresponsive }
        clock.withLock { $0 = $0.addingTimeInterval(11) }
        await settle(pool, rounds: 3)
        let s = try store.read()
        #expect(s.device("farm-t-2")?.state == .ready)
        #expect(s.counters.hangsDetected >= 1)
        #expect(s.counters.recoveries == 1)
        #expect(driver.calls.current.reset == 1)
        #expect(s.history.contains { $0.kind == "recovered" && $0.device == "farm-t-2" })
    }

    @Test func deadIdleDeviceIsReplaced() async throws {
        let clock = Locked(Date())
        let driver = FakeFarmDriver()
        let (pool, store, dir) = try makePool(size: 1, driver: driver, clock: clock)
        defer { try? FileManager.default.removeItem(at: dir) }
        await settle(pool)
        driver.unhealthy.withLock { $0["farm-t-1"] = .engineDead }
        clock.withLock { $0 = $0.addingTimeInterval(11) }
        await settle(pool, rounds: 3)
        let s = try store.read()
        #expect(s.device("farm-t-1")?.state == .ready)
        #expect(s.counters.replacements == 1)
        #expect(driver.calls.current.provision == 2)
    }

    @Test(arguments: [HealLeasedPolicy.replace, .report, .restart])
    func leasedDevicePolicy(policy: HealLeasedPolicy) async throws {
        let clock = Locked(Date())
        let driver = FakeFarmDriver()
        var p = noFreeze
        p.healLeased = policy
        let (pool, store, dir) = try makePool(size: 1, driver: driver, policy: p, clock: clock)
        defer { try? FileManager.default.removeItem(at: dir) }
        await settle(pool)
        let l = try store.update { s in try LeaseBook.acquireSync(&s, holderPID: nil, ttl: 600, now: clock.current) { _ in
            HealthSummary(verdict: .healthy, reason: "ok", at: Date()) } }
        driver.unhealthy.withLock { $0["farm-t-1"] = .guestUnresponsive }
        clock.withLock { $0 = $0.addingTimeInterval(11) }
        await settle(pool, rounds: 2)
        // First bad check only makes it a suspect (a busy test must not lose its device on one slow probe).
        var s = try store.read()
        #expect(s.lease(l.id)?.state == .active)
        #expect(s.history.contains { $0.kind == "suspect" })
        clock.withLock { $0 = $0.addingTimeInterval(6) }
        await settle(pool, rounds: 2)
        s = try store.read()
        switch policy {
        case .replace:
            #expect(s.lease(l.id)?.state == .deviceLost)
            #expect(s.device("farm-t-1")?.state == .replacing)
            #expect(driver.calls.current.destroy >= 1)
            // after release a fresh clone takes its place
            try store.update { s in _ = LeaseBook.release(&s, leaseID: l.id, recycle: false, now: clock.current) }
            await settle(pool, rounds: 2)
            s = try store.read()
            #expect(s.device("farm-t-1")?.state == .ready)
            #expect(s.counters.replacements == 1)
        case .report:
            #expect(s.lease(l.id)?.state == .deviceLost)
            #expect(s.device("farm-t-1")?.state == .leased)
            #expect(driver.calls.current.reset == 0)
        case .restart:
            #expect(s.lease(l.id)?.state == .active)
            #expect(s.device("farm-t-1")?.state == .leased)
            #expect(driver.calls.current.reset == 1)
        }
    }

    @Test func expiredLeaseOfDeadHolderIsReclaimed() async throws {
        let driver = FakeFarmDriver()
        let (pool, store, dir) = try makePool(size: 1, driver: driver)
        defer { try? FileManager.default.removeItem(at: dir) }
        await settle(pool)
        _ = try store.update { s in try LeaseBook.acquireSync(&s, holderPID: 950, ttl: 600, now: Date()) { _ in
            HealthSummary(verdict: .healthy, reason: "ok", at: Date()) } } // pid 950: "dead" in the fake
        await settle(pool, rounds: 2)
        let s = try store.read()
        #expect(s.leases.isEmpty)
        #expect(s.device("farm-t-1")?.state == .ready)
        #expect(s.counters.leasesExpired == 1 && s.counters.resets == 1)
    }

    @Test func circuitBreakerMarksFailed() async throws {
        let clock = Locked(Date())
        let driver = FakeFarmDriver()
        let (pool, store, dir) = try makePool(size: 1, driver: driver, clock: clock)
        defer { try? FileManager.default.removeItem(at: dir) }
        await settle(pool)
        driver.unhealthy.withLock { $0["farm-t-1"] = .guestUnresponsive }
        driver.failReset.set(["farm-t-1"])
        driver.failProvision.set(["farm-t-1"])
        for _ in 0..<12 {
            clock.withLock { $0 = $0.addingTimeInterval(120) }
            await settle(pool, rounds: 1)
        }
        let s = try store.read()
        #expect(s.device("farm-t-1")?.state == .failed)
        #expect(s.history.contains { $0.kind == "give-up" } || s.history.contains { $0.kind == "provision-failed" })
    }

    @Test func freezesIdleDevicesWhenAsked() async throws {
        let clock = Locked(Date())
        let driver = FakeFarmDriver()
        var p = FarmPolicy()
        p.freezeIdleAfter = 30
        let (pool, store, dir) = try makePool(size: 2, driver: driver, policy: p, clock: clock)
        defer { try? FileManager.default.removeItem(at: dir) }
        await settle(pool)
        clock.withLock { $0 = $0.addingTimeInterval(31) }
        await settle(pool, rounds: 1)
        #expect(try store.read().devices.allSatisfy { $0.state == .frozen })
        #expect(driver.calls.current.freeze == 2)
    }

    @Test func downTearsEverythingDown() async throws {
        let driver = FakeFarmDriver()
        let (pool, store, dir) = try makePool(size: 4, driver: driver)
        defer { try? FileManager.default.removeItem(at: dir) }
        await settle(pool)
        try store.update { $0.stopRequested = true }
        let keepGoing = await pool.tick()
        #expect(!keepGoing)
        #expect(driver.calls.current.destroy == 4)
        #expect(!store.exists)
    }
}
