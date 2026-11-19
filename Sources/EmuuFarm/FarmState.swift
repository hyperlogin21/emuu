import Foundation
import EmuuBase

/// The persisted state of one device pool (`<EMUU_HOME>/farm/<pool>/state.json`), shared by the pool daemon and
/// every `emuu farm …` / `emuu run` process. All changes go through `FarmStateStore.update`, which holds an
/// exclusive `flock` for the read-modify-write, so two `acquire` calls can never lease the same device.
///
/// This struct is also the `--json` schema of `emuu farm status` (format version 1, see README "Automation farm").
public struct FarmState: Codable, Sendable, Hashable {
    public static let formatVersion = 1

    public var formatVersion: Int = FarmState.formatVersion
    public var pool: String
    public var golden: String
    /// Warm devices the daemon keeps.
    public var size: Int
    public var daemonPID: Int32?
    public var createdAt: Date
    public var updatedAt: Date
    public var policy: FarmPolicy
    public var devices: [FarmDevice] = []
    public var leases: [FarmLease] = []
    public var counters = FarmCounters()
    /// Most recent events, newest last (bounded to `historyLimit`).
    public var history: [FarmEvent] = []
    /// Set by `emuu farm down`; the daemon tears everything down and exits.
    public var stopRequested: Bool = false
    /// Why the pool cannot reach `size` right now (capacity guard), nil when it can.
    public var capacityNote: String?

    public static let historyLimit = 300

    public init(pool: String, golden: String, size: Int, policy: FarmPolicy, now: Date) {
        self.pool = pool
        self.golden = golden
        self.size = size
        self.policy = policy
        self.createdAt = now
        self.updatedAt = now
    }

    public mutating func log(_ kind: String, device: String? = nil, lease: String? = nil, _ detail: String, at now: Date) {
        history.append(FarmEvent(at: now, kind: kind, device: device, lease: lease, detail: detail))
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
    }

    public func device(_ name: String) -> FarmDevice? { devices.first { $0.instance == name } }

    public mutating func withDevice(_ name: String, _ change: (inout FarmDevice) -> Void) {
        guard let i = devices.firstIndex(where: { $0.instance == name }) else { return }
        change(&devices[i])
    }

    public func lease(_ id: String) -> FarmLease? { leases.first { $0.id == id } }
}

public struct FarmPolicy: Codable, Sendable, Hashable {
    /// What happens to a device after release: `reset` (snapshot load in the running engine, default) or
    /// `recycle` (kill the engine, new clone from the golden, resume).
    public var releaseMode: ReleaseMode = .reset
    /// What the daemon does when a *leased* device becomes unhealthy.
    public var healLeased: HealLeasedPolicy = .replace
    /// Lease lifetime without a heartbeat (seconds).
    public var defaultTTL: TimeInterval = 1800
    /// Idle (not leased) ready devices are SIGSTOPped after this many seconds (nil = never). Measured: an idle
    /// warm device used 47–113 % of a core after its resume, 0 % frozen; acquire from frozen (SIGCONT + health
    /// check) took 0.07–0.18 s and adb answered at once.
    public var freezeIdleAfter: TimeInterval? = 60
    /// Allow more devices than the capacity guard's ceiling.
    public var overrideCapacity: Bool = false
    /// Self-heal pool devices (health checks + automatic recovery).
    public var selfHeal: Bool = true

    public init() {}
}

public enum ReleaseMode: String, Codable, Sendable, Hashable, CaseIterable {
    case reset, recycle
}

public enum HealLeasedPolicy: String, Codable, Sendable, Hashable, CaseIterable {
    /// Heal in place (reset/restart); the lease stays valid but the device state is lost.
    case restart
    /// Mark the lease `device_lost` and replace the device with a fresh clone (default).
    case replace
    /// Only mark the lease `device_lost`; the device is replaced after release.
    case report
}

public enum FarmDeviceState: String, Codable, Sendable, Hashable {
    /// Clone being created and engine resuming.
    case starting
    /// Health-checked, idle, can be leased.
    case ready
    /// Ready but SIGSTOPped to save CPU while idle (thawed on acquire).
    case frozen
    case leased
    /// Released; waiting for / undergoing a reset to the golden state.
    case resetting
    /// Health check failed; the daemon is recovering it.
    case unhealthy
    /// Being destroyed and replaced with a fresh clone.
    case replacing
    /// Recovery gave up (circuit breaker); needs `emuu farm gc` or `farm down`.
    case failed
}

public struct FarmDevice: Codable, Sendable, Hashable {
    public var instance: String
    public var consolePort: Int
    public var serial: String { "emulator-\(consolePort)" }
    public var state: FarmDeviceState
    public var enginePID: Int32?
    public var leaseID: String?
    public var since: Date
    public var resets: Int = 0
    public var replacements: Int = 0
    /// Consecutive failed recoveries (circuit breaker input).
    public var failedRecoveries: Int = 0
    public var lastHealth: HealthSummary?
    /// Next reset should recycle instead of snapshot-load (set after a failed reset or by `release --recycle`).
    public var recycleNext: Bool = false
    public var note: String?

    public init(instance: String, consolePort: Int, state: FarmDeviceState, since: Date) {
        self.instance = instance
        self.consolePort = consolePort
        self.state = state
        self.since = since
    }

    enum CodingKeys: String, CodingKey {
        case instance, consolePort, serial, state, enginePID, leaseID, since, resets, replacements, failedRecoveries,
             lastHealth, recycleNext, note
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(instance, forKey: .instance)
        try c.encode(consolePort, forKey: .consolePort)
        try c.encode(serial, forKey: .serial)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(enginePID, forKey: .enginePID)
        try c.encodeIfPresent(leaseID, forKey: .leaseID)
        try c.encode(since, forKey: .since)
        try c.encode(resets, forKey: .resets)
        try c.encode(replacements, forKey: .replacements)
        try c.encode(failedRecoveries, forKey: .failedRecoveries)
        try c.encodeIfPresent(lastHealth, forKey: .lastHealth)
        try c.encode(recycleNext, forKey: .recycleNext)
        try c.encodeIfPresent(note, forKey: .note)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        instance = try c.decode(String.self, forKey: .instance)
        consolePort = try c.decode(Int.self, forKey: .consolePort)
        state = try c.decode(FarmDeviceState.self, forKey: .state)
        enginePID = try c.decodeIfPresent(Int32.self, forKey: .enginePID)
        leaseID = try c.decodeIfPresent(String.self, forKey: .leaseID)
        since = try c.decode(Date.self, forKey: .since)
        resets = try c.decodeIfPresent(Int.self, forKey: .resets) ?? 0
        replacements = try c.decodeIfPresent(Int.self, forKey: .replacements) ?? 0
        failedRecoveries = try c.decodeIfPresent(Int.self, forKey: .failedRecoveries) ?? 0
        lastHealth = try c.decodeIfPresent(HealthSummary.self, forKey: .lastHealth)
        recycleNext = try c.decodeIfPresent(Bool.self, forKey: .recycleNext) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }
}

public enum LeaseState: String, Codable, Sendable, Hashable {
    case active
    /// The device became unhealthy or vanished while leased; the holder's test should fail.
    case deviceLost = "device_lost"
}

public struct FarmLease: Codable, Sendable, Hashable {
    public var id: String
    public var device: String
    public var serial: String
    /// The lease ends when this process exits (nil: TTL only).
    public var holderPID: Int32?
    public var acquiredAt: Date
    public var expiresAt: Date
    public var ttlSeconds: TimeInterval
    public var state: LeaseState
    public var lostReason: String?
}

public struct FarmCounters: Codable, Sendable, Hashable {
    public var acquires = 0
    public var releases = 0
    public var resets = 0
    public var resetFailures = 0
    public var recycles = 0
    public var replacements = 0
    public var leasesExpired = 0
    public var hangsDetected = 0
    public var recoveries = 0
    public var rebootsDetected = 0
    public init() {}
}

public struct FarmEvent: Codable, Sendable, Hashable {
    public var at: Date
    public var kind: String
    public var device: String?
    public var lease: String?
    public var detail: String
}

/// Lease bookkeeping (pure; every function works on a `FarmState` value).
public enum LeaseBook {
    public enum AcquireError: Error, Equatable {
        case noReadyDevice
    }

    /// Picks the longest-idle ready (or frozen) device that passes `isHealthy` and leases it. Devices that fail
    /// the check are marked `unhealthy` (the daemon recovers them) and the next one is tried.
    public static func acquire(_ state: inout FarmState, holderPID: Int32?, ttl: TimeInterval?, now: Date,
                               leaseID: String = FarmIDs.newLeaseID(),
                               isHealthy: (FarmDevice) async -> HealthSummary) async throws -> FarmLease {
        for index in candidates(state) {
            let health = await isHealthy(state.devices[index])
            if let lease = take(&state, index: index, health: health, holderPID: holderPID, ttl: ttl, now: now, leaseID: leaseID) {
                return lease
            }
        }
        throw AcquireError.noReadyDevice
    }

    /// Synchronous `acquire` (same rules) for health checks that do not await (tests, tools).
    public static func acquireSync(_ state: inout FarmState, holderPID: Int32?, ttl: TimeInterval?, now: Date,
                                   leaseID: String = FarmIDs.newLeaseID(),
                                   isHealthy: (FarmDevice) -> HealthSummary) throws -> FarmLease {
        for index in candidates(state) {
            let health = isHealthy(state.devices[index])
            if let lease = take(&state, index: index, health: health, holderPID: holderPID, ttl: ttl, now: now, leaseID: leaseID) {
                return lease
            }
        }
        throw AcquireError.noReadyDevice
    }

    /// Indices of leasable devices, longest idle first.
    static func candidates(_ state: FarmState) -> [Int] {
        state.devices.indices
            .filter { state.devices[$0].state == .ready || state.devices[$0].state == .frozen }
            .sorted { state.devices[$0].since < state.devices[$1].since }
    }

    private static func take(_ state: inout FarmState, index: Int, health: HealthSummary, holderPID: Int32?, ttl: TimeInterval?,
                             now: Date, leaseID: String) -> FarmLease? {
        let device = state.devices[index]
        state.devices[index].lastHealth = health
        guard health.verdict == .healthy else {
            state.devices[index].state = .unhealthy
            state.devices[index].since = now
            state.counters.hangsDetected += 1
            state.log("unhealthy", device: device.instance, "failed the pre-lease health check: \(health.reason)", at: now)
            return nil
        }
        let t = ttl ?? state.policy.defaultTTL
        let lease = FarmLease(id: leaseID, device: device.instance, serial: device.serial, holderPID: holderPID,
                              acquiredAt: now, expiresAt: now.addingTimeInterval(t), ttlSeconds: t, state: .active)
        state.devices[index].state = .leased
        state.devices[index].leaseID = lease.id
        state.devices[index].since = now
        state.leases.append(lease)
        state.counters.acquires += 1
        state.log("acquire", device: device.instance, lease: lease.id, "leased \(device.serial)" + (holderPID.map { " to pid \($0)" } ?? ""), at: now)
        return lease
    }

    /// Ends a lease; the device goes to `resetting` (the daemon resets it, or recycles it with `recycle`).
    /// Returns false for an unknown (or already released) lease id.
    @discardableResult
    public static func release(_ state: inout FarmState, leaseID: String, recycle: Bool, now: Date, reason: String = "released") -> Bool {
        guard let i = state.leases.firstIndex(where: { $0.id == leaseID }) else { return false }
        let lease = state.leases.remove(at: i)
        state.counters.releases += 1
        let recycleByPolicy = state.policy.releaseMode == .recycle
        state.withDevice(lease.device) { d in
            guard d.leaseID == leaseID else { return }
            d.leaseID = nil
            d.since = now
            if lease.state == .deviceLost || d.state == .replacing || d.state == .unhealthy || d.state == .failed {
                // Already being replaced/recovered (or given up on): leave it to the daemon.
                if d.state == .leased { d.state = .replacing }
            } else {
                d.state = .resetting
                d.recycleNext = d.recycleNext || recycle || recycleByPolicy
            }
        }
        state.log("release", device: lease.device, lease: leaseID, reason, at: now)
        return true
    }

    /// Extends a lease by its TTL (or `ttl`). Returns the updated lease, nil when unknown.
    public static func heartbeat(_ state: inout FarmState, leaseID: String, ttl: TimeInterval? = nil, now: Date) -> FarmLease? {
        guard let i = state.leases.firstIndex(where: { $0.id == leaseID }) else { return nil }
        if let ttl { state.leases[i].ttlSeconds = ttl }
        state.leases[i].expiresAt = now.addingTimeInterval(state.leases[i].ttlSeconds)
        return state.leases[i]
    }

    /// Releases leases whose TTL ran out or whose holder process is gone. Returns the released lease ids.
    @discardableResult
    public static func expire(_ state: inout FarmState, now: Date, isAlive: (Int32) -> Bool) -> [String] {
        let dead = state.leases.filter { lease in
            lease.expiresAt <= now || (lease.holderPID.map { !isAlive($0) } ?? false)
        }
        for lease in dead {
            let why = lease.expiresAt <= now ? "lease expired (TTL \(Int(lease.ttlSeconds)) s, no heartbeat)"
                                             : "holder pid \(lease.holderPID!) exited"
            state.counters.leasesExpired += 1
            release(&state, leaseID: lease.id, recycle: false, now: now, reason: why)
        }
        return dead.map(\.id)
    }

    /// A leased device became unhealthy: mark the lease lost (the holder sees `device_lost`).
    public static func markLost(_ state: inout FarmState, device: String, reason: String, now: Date) {
        for i in state.leases.indices where state.leases[i].device == device && state.leases[i].state == .active {
            state.leases[i].state = .deviceLost
            state.leases[i].lostReason = reason
            state.log("device_lost", device: device, lease: state.leases[i].id, reason, at: now)
        }
    }
}

public enum FarmIDs {
    public static func newLeaseID() -> String {
        "L-" + UUID().uuidString.prefix(8).lowercased()
    }

    /// Instance id of pool device number `n`, e.g. `farm-default-3`.
    public static func deviceInstance(pool: String, index: Int) -> String { "farm-\(pool)-\(index)" }
}
