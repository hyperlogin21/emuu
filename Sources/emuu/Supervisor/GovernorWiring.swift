import Foundation
import EmuuBase
import EmuuADB
import EmuuMemory

/// Visibility and user activity as the CLI knows them, for the memory governor.
///
/// Headless there is no window: the instance counts as hidden, and "user activity" is any Emuu command
/// that touches the device (install, launch, shell, `wake`, …). In `--window` mode the display's own
/// tracker is consulted as well.
final class SupervisorActivity: GovernorActivitySource, @unchecked Sendable {
    private let display: (any GovernorActivitySource)?
    /// Visibility reported over the control socket and when it was reported.
    private let visibleOverride = Locked<(visible: Bool, at: Duration)?>(nil)
    private let lastTouch = Locked<Duration?>(nil)
    private let clock: any EmuuClock
    /// A reported visibility expires unless the front end repeats it within this time, so a front end that
    /// crashes or is force-quit while "visible" cannot pin the instance as visible (no freeze, no T5, capped
    /// tiers) for the rest of the supervisor's life. The app re-sends it every 20 s while attached.
    let visibilityTTL: Duration

    init(display: (any GovernorActivitySource)? = nil, clock: any EmuuClock = SystemClock(), visibilityTTL: Duration = .seconds(60)) {
        self.display = display
        self.clock = clock
        self.visibilityTTL = visibilityTTL
    }

    /// Visibility reported by a front end over the control socket (nil = use the display / hidden).
    func setVisible(_ visible: Bool?) {
        visibleOverride.set(visible.map { ($0, clock.monotonicNow()) })
    }

    func noteInteraction() { lastTouch.set(clock.monotonicNow()) }

    func isDisplayVisible(_ id: InstanceID) async -> Bool {
        if let o = visibleOverride.current {
            if clock.monotonicNow() - o.at <= visibilityTTL { return o.visible }
            visibleOverride.withLock { if let cur = $0, cur.at == o.at { $0 = nil } }
        }
        if let display { return await display.isDisplayVisible(id) }
        return false
    }

    func lastUserInteraction(_ id: InstanceID) async -> Duration? {
        let mine = lastTouch.current
        let theirs = await display?.lastUserInteraction(id)
        switch (mine, theirs) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }
}

/// A `DeviceShell` whose serial follows the engine: after hibernate/resume the engine may come back on
/// other ports, and the governor's samplers/effectors must follow without being rebuilt.
final class FollowingShell: DeviceShell, @unchecked Sendable {
    private let client: Locked<ADBClient>
    private let server: ADBServer

    init(serial: DeviceSerial, server: ADBServer) {
        self.server = server
        self.client = Locked(ADBClient(serial: serial, server: server))
    }

    var serial: DeviceSerial { client.current.serial }

    func follow(_ serial: DeviceSerial) {
        client.withLock { c in
            if c.serial != serial { c = ADBClient(serial: serial, server: server) }
        }
    }

    func shell(_ command: String, timeout: Duration?) async throws -> ProcessResult {
        try await client.current.shell(command, timeout: timeout)
    }

    func adb(_ arguments: [String], timeout: Duration?) async throws -> ProcessResult {
        try await client.current.adb(arguments, timeout: timeout)
    }
}

/// Options that shape the governor for a CLI session.
struct GovernorOptions: Sendable, Hashable {
    var profile: MemoryProfile
    var guestRAMMB: Int
    /// Headless: no window, so "hidden" is permanent. Freeze-on-idle then only happens when asked.
    var headless: Bool
    /// Freeze after this much idle time (headless only; nil = never freeze on idle).
    var idleFreezeAfter: Duration?
    /// Automation mode: never freeze/hibernate, T1/T2 on background apps only.
    var automation = false

    /// The preset for the profile, adjusted for headless use:
    /// * Freezing after "hidden + idle" is disabled unless `idleFreezeAfter` is set, because a headless
    ///   engine is often driven by tools Emuu cannot see (adb, Android Studio), and a frozen engine
    ///   makes adb hang.
    /// * Auto-resume stays on, but headless it only fires on Emuu commands (there is no window to show).
    func config() -> GovernorConfig {
        var c = GovernorConfig.preset(profile, guestRAMMB: guestRAMMB)
        if headless {
            c.freezeWhenHiddenAfter = idleFreezeAfter
        }
        c.automationMode = automation
        return c
    }
}

/// The governor plus the effectors the CLI also uses for manual tiers.
struct GovernorBundle: Sendable {
    let governor: MemoryGovernor
    let guest: GuestEffector
    let engineEffector: EngineEffector
    let pressure: HostPressureMonitor
}

enum GovernorFactory {
    static func make(instanceID: InstanceID, options: GovernorOptions, engine: any EngineControl, shell: any DeviceShell,
                     activity: any GovernorActivitySource, csv: SampleCSVLog?) -> GovernorBundle {
        let pressure = HostPressureMonitor()
        let host = HostSampler(pressureHint: { pressure.latest })
        let guest = GuestEffector(shell: shell)
        let engineEffector = EngineEffector(engine: engine)
        let governor = MemoryGovernor(
            instanceID: instanceID, config: options.config(), engine: engine,
            guestSampler: GuestSampler(shell: shell), hostSampler: host,
            effector: EffectorRouter([guest, engineEffector]),
            maintenance: MaintenanceRunner(guest: guest, engine: engineEffector),
            activity: activity, csvLog: csv)
        pressure.onChange { _ in governor.nudge() }
        return GovernorBundle(governor: governor, guest: guest, engineEffector: engineEffector, pressure: pressure)
    }
}

/// Manual tiers (`emuu mem trim|reclaim`), shared by the supervisor and the no-supervisor path.
enum ManualTiers {
    static func trim(guest: GuestEffector, level: TrimMemoryLevel, kill: Bool, caches: UInt64?) async -> [TierReport] {
        var out: [TierReport] = []
        do {
            out.append(TierReport(step: "T1 send-trim-memory \(level.rawValue)", outcome: try await guest.trim(level: level, packages: [])))
        } catch {
            out.append(TierReport(step: "T1 send-trim-memory \(level.rawValue)", error: describe(error)))
        }
        if let caches {
            do {
                out.append(TierReport(step: "T1 trim-caches", outcome: try await guest.trimCaches(desiredFreeBytes: caches)))
            } catch {
                out.append(TierReport(step: "T1 trim-caches", error: describe(error)))
            }
        }
        if kill {
            do {
                out.append(TierReport(step: "T2 kill cached apps", outcome: try await guest.killBackground(packages: [])))
            } catch {
                out.append(TierReport(step: "T2 kill cached apps", error: describe(error)))
            }
        }
        return out
    }

    static func reclaim(guest: GuestEffector, engine: EngineEffector) async -> [TierReport] {
        var out: [TierReport] = []
        do {
            out.append(TierReport(step: "T3 reclaim guest RAM to host", outcome: try await engine.apply(.reclaimGuestMemory(targetBytes: nil))))
        } catch {
            out.append(TierReport(step: "T3 reclaim guest RAM to host", error: describe(error)))
        }
        do {
            out.append(TierReport(step: "guest compaction (compact system)", outcome: try await guest.compactSystem()))
        } catch {
            out.append(TierReport(step: "guest compaction (compact system)", error: describe(error)))
        }
        return out
    }

    static func render(_ reports: [TierReport]) -> String {
        reports.map { r in
            var s = "\(r.step): \(r.status)"
            if !r.detail.isEmpty { s += " — \(r.detail)" }
            if let b = r.reclaimedBytes { s += " (guest MemAvailable +\(ByteCount.format(b)))" }
            return s
        }.joined(separator: "\n")
    }
}
