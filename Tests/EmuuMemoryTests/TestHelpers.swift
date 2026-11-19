import Foundation
import EmuuBase
import EmuuTestSupport
@testable import EmuuMemory

let testID = InstanceID(rawValue: "emuu-test")!
let gib = ByteCount.gib
let mib = ByteCount.mib

/// Guest with a given available fraction of a 2 GiB guest.
func guest(available fraction: Double, total: UInt64 = 2 * ByteCount.gib, psiSome10: Double? = nil, psiFull10: Double = 0) -> GuestMemory {
    let avail = UInt64(Double(total) * fraction)
    var g = GuestMemory(totalBytes: total, freeBytes: avail / 4, availableBytes: avail, cachedBytes: avail / 2)
    if let p = psiSome10 {
        g.pressureStall = PressureStall(someAvg10: p, someAvg60: p, someAvg300: p, fullAvg10: psiFull10, fullAvg60: 0, fullAvg300: 0)
    }
    return g
}

func host(footprint: UInt64 = 2 * ByteCount.gib, pressure: MemoryPressureLevel = .normal) -> HostMemory {
    HostMemory(engineFootprintBytes: footprint, engineResidentBytes: footprint, systemPressure: pressure, physicalMemoryBytes: 16 * ByteCount.gib)
}

/// Drives a policy with a simple timeline.
struct PolicyDriver {
    var policy: GovernorPolicy
    var log: [(t: Int, action: GovernorAction)] = []
    var decisions: [PolicyDecision] = []
    var state: InstanceState = .running

    /// Scenario tests exercise escalation logic, so the post-boot grace period is off unless given.
    init(_ config: GovernorConfig, grace: Duration = .zero) {
        var c = config
        c.guestActionGraceAfterStart = grace
        policy = GovernorPolicy(config: c)
    }

    /// t in seconds since start (monotonic epoch 1000 s like FakeClock).
    @discardableResult
    mutating func step(_ t: Int, guest g: GuestMemory?, host h: HostMemory? = host(), visible: Bool = true, interaction: Int? = nil,
                       foreground: [String] = [],
                       outcome: (GovernorAction) -> EffectorOutcome = { _ in .applied() }) -> PolicyDecision {
        let input = PolicyInput(now: .seconds(1000 + t), engineState: state, guest: g, foregroundPackages: foreground, host: h,
                                isVisible: visible, lastUserInteraction: interaction.map { .seconds(1000 + $0) })
        let d = policy.evaluate(input)
        for a in d.actions {
            log.append((t, a.action))
            let o = outcome(a.action)
            policy.record(outcome: o, for: a.action)
            switch a.action {
            case .freeze: state = .frozen
            case .thaw, .resume: state = .running
            case .hibernate: state = .hibernated
            default: break
            }
        }
        decisions.append(d)
        return d
    }

    var actions: [GovernorAction] { log.map(\.action) }
    func times(of tier: GovernorTier) -> [Int] { log.filter { $0.action.tier == tier }.map(\.t) }
}

final class FakeActivity: GovernorActivitySource, @unchecked Sendable {
    private let s = Locked((visible: true, last: Duration?.none))
    init(visible: Bool = true) { s.withLock { $0.visible = visible } }
    func set(visible: Bool) { s.withLock { $0.visible = visible } }
    func interact(at t: Duration) { s.withLock { $0.last = t } }
    func isDisplayVisible(_ id: InstanceID) async -> Bool { s.withLock { $0.visible } }
    func lastUserInteraction(_ id: InstanceID) async -> Duration? { s.withLock { $0.last } }
}

final class ScriptedGuestSampler: GuestMemorySampling, @unchecked Sendable {
    let make: @Sendable () throws -> GuestSnapshot
    let count = Locked(0)
    init(_ make: @escaping @Sendable () throws -> GuestSnapshot) { self.make = make }
    func sample() async throws -> GuestSnapshot {
        count.withLock { $0 += 1 }
        return try make()
    }
    func appBreakdown() async throws -> [AppMemoryUsage] { [AppMemoryUsage(packageName: "com.example", pssBytes: 1)] }
}

final class ScriptedHostSampler: HostMemorySampling, @unchecked Sendable {
    let make: @Sendable (Int32?) -> HostSnapshot
    init(_ make: @escaping @Sendable (Int32?) -> HostSnapshot) { self.make = make }
    func sample(enginePID: Int32?) -> HostSnapshot { make(enginePID) }
}

final class RecordingEffector: MemoryEffector, @unchecked Sendable {
    let applied = Locked<[GovernorAction]>([])
    let respond: @Sendable (GovernorAction) -> EffectorOutcome
    init(_ respond: @escaping @Sendable (GovernorAction) -> EffectorOutcome = { _ in .applied() }) { self.respond = respond }
    func handles(_ action: GovernorAction) -> Bool { true }
    func apply(_ action: GovernorAction) async throws -> EffectorOutcome {
        applied.withLock { $0.append(action) }
        return respond(action)
    }
}

func hostSnapshot(footprint: UInt64?, pressure: MemoryPressureLevel = .normal) -> HostSnapshot {
    HostSnapshot(
        engine: footprint.map { EngineProcessStats(pid: 4242, processCount: 1, footprintBytes: $0, lifetimeMaxFootprintBytes: $0, residentBytes: $0, cpuSeconds: 1, cpuPercent: 5) },
        system: HostSystemStats(physicalBytes: 16 * gib, freeBytes: gib, compressedBytes: gib, swapUsedBytes: 0, swapTotalBytes: 0, kernelPressureLevel: 1, pressure: pressure))
}
