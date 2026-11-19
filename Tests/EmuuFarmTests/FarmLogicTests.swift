import Foundation
import Testing
import EmuuBase
@testable import EmuuFarm

private let gib: UInt64 = 1 << 30
private let mib: UInt64 = 1 << 20
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func state(devices n: Int, ready: Bool = true) -> FarmState {
    var s = FarmState(pool: "p", golden: "g", size: n, policy: FarmPolicy(), now: t0)
    for i in 0..<n {
        s.devices.append(FarmDevice(instance: "farm-p-\(i + 1)", consolePort: 5554 + 2 * i, state: ready ? .ready : .starting,
                                    since: t0.addingTimeInterval(Double(i))))
    }
    return s
}

private let healthy: @Sendable (FarmDevice) -> HealthSummary = { _ in HealthSummary(verdict: .healthy, reason: "ok", at: t0) }

@Suite struct PortTests {
    @Test func allocatesWithinADBRangeSkippingBusyAndReserved() {
        #expect(FarmPorts.consolePorts.count == 16)
        #expect(FarmPorts.consolePorts.first == 5554 && FarmPorts.consolePorts.last == 5584)
        let busy: Set<Int> = [5556, 5561] // console 5556 bound; adb port of 5560 bound (non-Emuu emulator)
        let got = FarmPorts.allocate(count: 4, reserved: [5554], isFree: { !busy.contains($0) })
        #expect(got == [5558, 5562, 5564, 5566])
    }

    @Test func runsOutAtSixteen() {
        let all = FarmPorts.allocate(count: 20, reserved: [], isFree: { _ in true })
        #expect(all.count == 16)
        #expect(Set(all).count == 16)
        #expect(FarmPorts.allocate(count: 1, reserved: Set(all), isFree: { _ in true }).isEmpty)
    }
}

@Suite struct CapacityTests {
    let cost = DeviceCost(guestRAMMB: 2048, cores: 2, perDeviceBytes: 2800 * mib, footprintBytes: 4800 * mib, diskBytes: 600 * mib)

    func host(_ ram: UInt64, cores: Int = 10, avail: UInt64? = nil, pressure: MemoryPressureLevel = .normal) -> HostFacts {
        HostFacts(physicalMemoryBytes: ram * gib, cpuCores: cores, availableBytes: avail, pressure: pressure)
    }

    @Test func ceilingFromMemoryCPUAndPorts() {
        // reserve = max(8 GiB, 40 %): 16 → 8 GiB, 24 → 9.6, 32 → 12.8, 48 → 19.2; 2800 MiB per device
        #expect(CapacityGuard.evaluate(host: host(16), cost: cost).ceiling == 2)
        #expect(CapacityGuard.evaluate(host: host(24), cost: cost).byMemory == 5)
        #expect(CapacityGuard.evaluate(host: host(32), cost: cost).byMemory == 7)
        let r48 = CapacityGuard.evaluate(host: host(48, cores: 12), cost: cost)
        #expect(r48.byMemory == 10)
        #expect(r48.byCPU == 6)
        #expect(r48.ceiling == 6 && r48.limitedBy == "cpu")
        let huge = CapacityGuard.evaluate(host: host(512, cores: 128), cost: cost)
        #expect(huge.ceiling == 16 && huge.limitedBy == "ports")
    }

    @Test func liveAdmission() {
        let ok = CapacityGuard.evaluate(host: host(16, avail: 9 * gib), cost: cost, running: 1)
        #expect(ok.admitNow)
        let full = CapacityGuard.evaluate(host: host(16, avail: 9 * gib), cost: cost, running: 2)
        #expect(!full.admitNow && full.admitReason.contains("at capacity"))
        let pressured = CapacityGuard.evaluate(host: host(16, avail: 9 * gib, pressure: .high), cost: cost, running: 0)
        #expect(!pressured.admitNow && pressured.admitReason.contains("pressure"))
        // 3 GiB available < 2.73 GiB + 1.6 GiB floor
        let tight = CapacityGuard.evaluate(host: host(16, avail: 3 * gib), cost: cost, running: 0)
        #expect(!tight.admitNow && tight.admitReason.contains("available"))
    }

    @Test func estimateAddsEngineOverhead() {
        let e = DeviceCost.estimate(guestRAMMB: 1536, cores: 2)
        #expect(e.perDeviceBytes == 1536 * mib + DeviceCost.engineOverheadBytes)
    }
}

@Suite struct LeaseTests {
    @Test func acquirePicksLongestIdleAndRecordsLease() throws {
        var s = state(devices: 3)
        let l = try LeaseBook.acquireSync(&s, holderPID: 42, ttl: 60, now: t0.addingTimeInterval(10), leaseID: "L-1", isHealthy: healthy)
        #expect(l.device == "farm-p-1" && l.serial == "emulator-5554")
        #expect(s.device("farm-p-1")?.state == .leased)
        #expect(s.device("farm-p-1")?.leaseID == "L-1")
        #expect(l.expiresAt == t0.addingTimeInterval(70))
        #expect(s.counters.acquires == 1)
    }

    @Test func unhealthyCandidatesAreSkippedAndMarked() throws {
        var s = state(devices: 3)
        let l = try LeaseBook.acquireSync(&s, holderPID: nil, ttl: nil, now: t0, isHealthy: { d in
            HealthSummary(verdict: d.instance == "farm-p-3" ? .healthy : .hung, reason: "adb shell timeout", at: t0)
        })
        #expect(l.device == "farm-p-3")
        #expect(s.device("farm-p-1")?.state == .unhealthy && s.device("farm-p-2")?.state == .unhealthy)
        #expect(l.ttlSeconds == FarmPolicy().defaultTTL)
    }

    @Test func noReadyDevice() {
        var s = state(devices: 2, ready: false)
        #expect(throws: LeaseBook.AcquireError.noReadyDevice) {
            try LeaseBook.acquireSync(&s, holderPID: nil, ttl: nil, now: t0, isHealthy: healthy)
        }
    }

    @Test func releaseResetsOrRecycles() throws {
        var s = state(devices: 2)
        let a = try LeaseBook.acquireSync(&s, holderPID: nil, ttl: nil, now: t0, isHealthy: healthy)
        let b = try LeaseBook.acquireSync(&s, holderPID: nil, ttl: nil, now: t0, isHealthy: healthy)
        #expect(LeaseBook.release(&s, leaseID: a.id, recycle: false, now: t0))
        #expect(s.device(a.device)?.state == .resetting && s.device(a.device)?.recycleNext == false)
        #expect(LeaseBook.release(&s, leaseID: b.id, recycle: true, now: t0))
        #expect(s.device(b.device)?.recycleNext == true)
        #expect(!LeaseBook.release(&s, leaseID: a.id, recycle: false, now: t0)) // twice
        #expect(s.leases.isEmpty)
    }

    @Test func ttlExpiryAndHolderDeath() throws {
        var s = state(devices: 3)
        let a = try LeaseBook.acquireSync(&s, holderPID: nil, ttl: 30, now: t0, isHealthy: healthy)
        let b = try LeaseBook.acquireSync(&s, holderPID: 777, ttl: 3600, now: t0, isHealthy: healthy)
        let c = try LeaseBook.acquireSync(&s, holderPID: 888, ttl: 3600, now: t0, isHealthy: healthy)
        // heartbeat keeps a alive past its first TTL
        _ = LeaseBook.heartbeat(&s, leaseID: a.id, now: t0.addingTimeInterval(25))
        var expired = LeaseBook.expire(&s, now: t0.addingTimeInterval(40), isAlive: { $0 != 777 })
        #expect(expired == [b.id])
        #expect(s.device(b.device)?.state == .resetting)
        expired = LeaseBook.expire(&s, now: t0.addingTimeInterval(60), isAlive: { _ in true })
        #expect(expired == [a.id])
        #expect(s.lease(c.id) != nil)
        #expect(s.counters.leasesExpired == 2)
        #expect(s.history.contains { $0.detail.contains("holder pid 777 exited") })
    }

    @Test func lostLeaseIsReplacedOnRelease() throws {
        var s = state(devices: 1)
        let a = try LeaseBook.acquireSync(&s, holderPID: nil, ttl: nil, now: t0, isHealthy: healthy)
        LeaseBook.markLost(&s, device: a.device, reason: "adb shell timeout", now: t0)
        #expect(s.lease(a.id)?.state == .deviceLost)
        LeaseBook.release(&s, leaseID: a.id, recycle: false, now: t0)
        #expect(s.device(a.device)?.state == .replacing)
    }

    /// N = 12 devices, 40 concurrent acquirers, each through the real flock-guarded store in its own thread:
    /// every device is leased exactly once and the rest get noReadyDevice.
    @Test func concurrentAcquireNeverDoubleLeases() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("emuu-farm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let farm = FarmPaths(paths: EmuuPaths(root: dir))
        let store = FarmStateStore(farm: farm, pool: "p")
        try store.create(state(devices: 12))
        let results = Locked<[String]>([])
        let failures = Locked(0)
        DispatchQueue.concurrentPerform(iterations: 40) { i in
            do {
                let lease = try store.update { s in
                    try LeaseBook.acquireSync(&s, holderPID: Int32(1000 + i), ttl: 60, now: Date(), isHealthy: healthy)
                }
                results.withLock { $0.append(lease.device) }
            } catch {
                failures.withLock { $0 += 1 }
            }
        }
        #expect(results.current.count == 12)
        #expect(Set(results.current).count == 12)
        #expect(failures.current == 28)
        let final = try store.read()
        #expect(final.leases.count == 12)
        #expect(final.devices.allSatisfy { $0.state == .leased })
    }

    @Test func historyIsBounded() {
        var s = state(devices: 1)
        for i in 0..<(FarmState.historyLimit + 50) { s.log("x", "\(i)", at: t0) }
        #expect(s.history.count == FarmState.historyLimit)
        #expect(s.history.last?.detail == "\(FarmState.historyLimit + 49)")
    }
}

@Suite struct JSONSchemaTests {
    @Test func farmStateRoundTripsWithStableKeys() throws {
        var s = state(devices: 2)
        _ = try LeaseBook.acquireSync(&s, holderPID: 5, ttl: 60, now: t0, leaseID: "L-x", isHealthy: healthy)
        let data = try FarmJSON.encoder.encode(s)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["formatVersion", "pool", "golden", "size", "policy", "devices", "leases", "counters", "history", "createdAt", "updatedAt"] {
            #expect(obj[key] != nil, "missing \(key)")
        }
        let dev = try #require((obj["devices"] as? [[String: Any]])?.first)
        for key in ["instance", "serial", "consolePort", "state", "since", "leaseID", "resets", "replacements"] {
            #expect(dev[key] != nil, "device missing \(key)")
        }
        #expect(dev["serial"] as? String == "emulator-5554")
        let lease = try #require((obj["leases"] as? [[String: Any]])?.first)
        for key in ["id", "device", "serial", "holderPID", "acquiredAt", "expiresAt", "ttlSeconds", "state"] {
            #expect(lease[key] != nil, "lease missing \(key)")
        }
        #expect(lease["state"] as? String == "active")
        let back = try FarmJSON.decoder.decode(FarmState.self, from: data)
        #expect(back == s)
    }

    @Test func leaseStateAndPoliciesUseDocumentedStrings() throws {
        #expect(LeaseState.deviceLost.rawValue == "device_lost")
        #expect(HealLeasedPolicy.allCases.map(\.rawValue) == ["restart", "replace", "report"])
        #expect(HealStep.allCases.map(\.rawValue) == ["thaw", "reconnect-adb", "reset", "soft-reboot", "hard-restart", "cold-boot", "replace"])
        let report = HealthReport(instance: "a", serial: "emulator-5554", verdict: .hung, reason: "r", fault: .guestUnresponsive,
                                  checkedAt: t0, probes: [ProbeResult(name: "shell", status: .fail, detail: "x", millis: 10000)],
                                  bootID: nil, suggestedStep: .hardRestart)
        let obj = try #require(try JSONSerialization.jsonObject(with: FarmJSON.encoder.encode(report)) as? [String: Any])
        #expect(obj["verdict"] as? String == "hung")
        #expect(obj["fault"] as? String == "guest-unresponsive")
        #expect(obj["suggestedStep"] as? String == "hard-restart")
        #expect(((obj["probes"] as? [[String: Any]])?.first?["status"]) as? String == "fail")
    }
}
