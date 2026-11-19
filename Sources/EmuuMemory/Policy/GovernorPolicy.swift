import Foundation
import EmuuBase

/// Everything the policy looks at for one decision. Built by `MemoryGovernor` each tick.
public struct PolicyInput: Sendable, Hashable {
    /// Monotonic time of this evaluation.
    public var now: Duration
    public var engineState: InstanceState
    /// Guest view; nil when the guest was not sampled (frozen, adb unreachable).
    public var guest: GuestMemory?
    /// Foreground package(s) at sample time (informational for the policy; effectors re-check).
    public var foregroundPackages: [String]
    public var host: HostMemory?
    public var isVisible: Bool
    /// Monotonic time of the last user input, if any.
    public var lastUserInteraction: Duration?

    public init(now: Duration, engineState: InstanceState, guest: GuestMemory? = nil, foregroundPackages: [String] = [],
                host: HostMemory? = nil, isVisible: Bool, lastUserInteraction: Duration? = nil) {
        self.now = now
        self.engineState = engineState
        self.guest = guest
        self.foregroundPackages = foregroundPackages
        self.host = host
        self.isVisible = isVisible
        self.lastUserInteraction = lastUserInteraction
    }
}

/// One action with the reason the policy chose it.
public struct PlannedAction: Sendable, Hashable {
    public var action: GovernorAction
    public var reason: String
}

/// Steps of an idle maintenance run, executed by `MaintenanceRunner` in this order.
public enum MaintenanceStep: String, Codable, Sendable, Hashable, CaseIterable {
    /// `am send-trim-memory <pkg> COMPLETE` to cached/background apps.
    case trimBackground
    /// `am kill-all` (only processes that are safe to kill).
    case killCached
    /// `pm trim-caches` (app cache files; keeps the userdata image from growing).
    case trimCaches
    /// `am compact system` / per-process compaction, when this Android build offers it.
    case compact
    /// Return freed guest memory to the host (engine T3 mechanism), when supported.
    case reclaim
}

public struct MaintenancePlan: Sendable, Hashable {
    public var steps: [MaintenanceStep]
    public var trimCachesDesiredFreeBytes: UInt64
    public var reason: String
}

/// Long-run creep finding.
public struct CreepReport: Sendable, Hashable {
    public enum Signal: String, Codable, Sendable, Hashable {
        /// Host engine footprint rising.
        case engineFootprint
        /// Guest MemAvailable falling.
        case guestAvailable
    }

    public var signal: Signal
    /// Slope (bytes per hour); negative for a shrinking guest MemAvailable.
    public var bytesPerHour: Int64
    public var r2: Double
    public var window: Duration
}

public struct TierChange: Sendable, Hashable {
    public var from: GovernorTier
    public var to: GovernorTier
    public var reason: String
}

/// Output of one evaluation.
public struct PolicyDecision: Sendable, Hashable {
    /// **Guest** pressure (MemAvailable, PSI): the only input of the guest-side tiers T1–T3.
    public var level: MemoryPressureLevel
    /// Why the level is what it is (dominant signal).
    public var levelReason: String
    /// **Host** pressure (macOS memory pressure, engine footprint vs budget): only shortens the way to
    /// freeze/hibernate of a hidden, idle instance. Never triggers guest-side trim/kill.
    public var hostLevel: MemoryPressureLevel = .normal
    public var hostLevelReason: String = "calm"
    /// Effective tier: the active pressure tier, or `.freeze`/`.hibernate` while frozen/hibernated.
    public var tier: GovernorTier
    public var tierChange: TierChange?
    public var actions: [PlannedAction]
    public var maintenance: MaintenancePlan?
    public var creep: CreepReport?
    /// When the governor should sample next.
    public var nextSampleIn: Duration
    /// Human-readable notes (e.g. suppressed by rate limit), for logs.
    public var notes: [String]
}

/// Pure, deterministic memory-governor state machine. No I/O, no clocks: time comes in
/// `PolicyInput.now`, and effector results come back through `record(...)`.
///
/// Memory: O(1) — trend windows and the action-rate window are fixed-capacity ring buffers.
public struct GovernorPolicy: Sendable {
    public private(set) var config: GovernorConfig

    // Pressure level with hysteresis.
    public private(set) var level: MemoryPressureLevel = .normal
    /// Host pressure (no hysteresis needed for the kernel level; the footprint ratio uses its margins).
    public private(set) var hostLevel: MemoryPressureLevel = .normal
    private var pendingLevel: MemoryPressureLevel = .normal
    private var pendingCount = 0

    // Pressure tiers (T1–T3).
    public private(set) var pressureTier: GovernorTier = .none
    private var calmSince: Duration?
    private var lastActionAt: [Duration?] = Array(repeating: nil, count: GovernorTier.allCases.count)
    private var baselineAvailable: [Double?] = Array(repeating: nil, count: GovernorTier.allCases.count)
    private var baselineLevel: [MemoryPressureLevel] = Array(repeating: .normal, count: GovernorTier.allCases.count)
    private var lastNoop: [Bool] = Array(repeating: false, count: GovernorTier.allCases.count)
    private var failures: [Int] = Array(repeating: 0, count: GovernorTier.allCases.count)
    /// Tiers whose mechanism reported `.unsupported`; never requested again.
    public private(set) var disabledTiers: Set<GovernorTier> = []
    private var actionTimes: RingBuffer<Duration>

    // Lifecycle (T4/T5).
    private var startedAt: Duration?
    private var hiddenSince: Duration?
    private var frozenSince: Duration?
    private var hibernatedSince: Duration?
    private var lastReversalAt: Duration?
    /// Consecutive failed thaw/resume attempts, when the last one was planned, and (after giving up) the time
    /// of giving up: only user input newer than that re-arms automatic retries.
    private var reversalFailures = 0
    private var lastReversalPlannedAt: Duration?
    private var reversalGaveUpAt: Duration?
    /// First retry delay after a failed thaw/resume; doubles per failure.
    public static let reversalRetryBase: Duration = .seconds(5)
    /// After this many consecutive failures, thaw/resume wait for new user input.
    public static let maxReversalFailures = 5
    private var lastEngineState: InstanceState?
    /// When the engine last entered `.running` (boot, resume, thaw): start of the guest-action grace period.
    private var runningSince: Duration?
    private var reportedTier: GovernorTier = .none

    // Long horizon.
    private var footprintTrend: TrendWindow
    private var availableTrend: TrendWindow
    public private(set) var smoothedAvailableFraction = EWMA(timeConstant: .minutes(5))
    public private(set) var creepActive = false
    private var lastCreepReportAt: Duration?
    public private(set) var lastMaintenanceAt: Duration?

    public init(config: GovernorConfig) {
        self.config = config
        self.actionTimes = RingBuffer(capacity: max(1, config.maxActionsPerHour))
        self.footprintTrend = TrendWindow(capacity: config.longHorizon.trendCapacity, minSpacing: config.longHorizon.trendPointSpacing)
        self.availableTrend = TrendWindow(capacity: config.longHorizon.trendCapacity, minSpacing: config.longHorizon.trendPointSpacing)
    }

    /// Replaces the configuration, keeping learned state (disabled tiers, timers).
    public mutating func updateConfig(_ newConfig: GovernorConfig) {
        if newConfig.maxActionsPerHour != config.maxActionsPerHour {
            var rb = RingBuffer<Duration>(capacity: max(1, newConfig.maxActionsPerHour))
            actionTimes.forEach { rb.append($0) }
            actionTimes = rb
        }
        config = newConfig
    }

    // MARK: - Evaluate

    public mutating func evaluate(_ input: PolicyInput) -> PolicyDecision {
        let now = input.now
        if startedAt == nil { startedAt = now }
        var notes: [String] = []
        var actions: [PlannedAction] = []
        var maintenance: MaintenancePlan?

        // Visibility / idleness.
        if input.isVisible { hiddenSince = nil } else if hiddenSince == nil { hiddenSince = now }
        let idleFor = now - max(input.lastUserInteraction ?? startedAt!, startedAt!)

        // Lifecycle bookkeeping.
        trackEngineState(input.engineState, now: now)

        // Long-horizon trends.
        let creep = updateTrends(input, now: now)

        // Guest pressure level (drives T1–T3) and host pressure level (drives only freeze/hibernate).
        let (lvl, lvlReason) = updateLevel(guest: input.guest)
        let (hostLvl, hostReason) = Self.classifyHost(input.host, config: config, relaxed: hostLevel > .normal)
        hostLevel = hostLvl

        switch input.engineState {
        case .frozen:
            let since = frozenSince ?? now
            if input.isVisible || interacted(input, after: since) {
                if reversalAllowed(input, now: now, notes: &notes) {
                    actions.append(PlannedAction(action: .thaw, reason: input.isVisible ? "display visible" : "user input"))
                    lastReversalAt = now
                    lastReversalPlannedAt = now
                }
            } else if !config.automationMode, let reason = hibernateReason(input, frozenFor: now - since) {
                if allowEscalation(.hibernate, now: now, notes: &notes) {
                    actions.append(PlannedAction(action: .hibernate, reason: reason))
                    noteIssued(.hibernate, now: now, guest: nil)
                }
            }
        case .hibernated:
            let since = hibernatedSince ?? now
            if config.autoResume, input.isVisible || interacted(input, after: since),
               reversalAllowed(input, now: now, notes: &notes) {
                actions.append(PlannedAction(action: .resume, reason: input.isVisible ? "display visible" : "user input"))
                lastReversalAt = now
                lastReversalPlannedAt = now
            }
        case .running:
            if let reason = freezeReason(input, idleFor: idleFor, now: now) {
                actions.append(PlannedAction(action: .freeze, reason: reason))
                noteIssued(.freeze, now: now, guest: nil)
            } else {
                if let blocked = guestActionsBlocked(input, now: now) {
                    notes.append("guest actions held: \(blocked)")
                } else if let guest = input.guest {
                    if let a = pressureStep(guest: guest, visible: input.isVisible, now: now, notes: &notes) {
                        actions.append(a)
                    }
                    if actions.isEmpty, let plan = maintenancePlan(input, idleFor: idleFor, now: now, notes: &notes) {
                        maintenance = plan
                    }
                } else {
                    notes.append("no guest sample; pressure tiers paused")
                }
            }
        case .booting, .stopping, .hibernating, .stopped, .crashed:
            // Nothing to act on; forget the pressure tier so a new run starts clean.
            if pressureTier != .none {
                pressureTier = .none
                calmSince = nil
            }
        }

        // Effective tier and change reporting.
        let effective: GovernorTier
        switch input.engineState {
        case .frozen: effective = .freeze
        case .hibernated, .hibernating: effective = .hibernate
        default: effective = pressureTier
        }
        var change: TierChange?
        if effective != reportedTier {
            let reason: String
            if let a = actions.first { reason = a.reason } else if effective == .freeze { reason = "engine frozen" }
            else if effective == .hibernate { reason = "engine hibernated" }
            else { reason = "pressure \(lvl) (\(lvlReason))" }
            change = TierChange(from: reportedTier, to: effective, reason: reason)
            reportedTier = effective
        }

        return PolicyDecision(level: lvl, levelReason: lvlReason, hostLevel: hostLvl, hostLevelReason: hostReason, tier: effective,
                              tierChange: change, actions: actions, maintenance: maintenance, creep: creep,
                              nextSampleIn: nextInterval(input.engineState), notes: notes)
    }

    // MARK: - Feedback from effectors

    /// Reports the outcome of an action the policy planned.
    public mutating func record(outcome: EffectorOutcome, for action: GovernorAction) {
        let t = tierIndex(action.tier)
        failures[t] = 0
        if action.isReversal { resetReversalBackoff() }
        switch outcome.status {
        case .applied:
            lastNoop[t] = false
        case .noop:
            lastNoop[t] = true
        case .unsupported:
            if action.tier != .none {
                disabledTiers.insert(action.tier)
                if pressureTier == action.tier { pressureTier = previousEnabledTier(below: action.tier) }
            }
        }
    }

    /// Reports that an action threw (infrastructure failure). Its tier backs off exponentially.
    public mutating func recordFailure(for action: GovernorAction) {
        let t = tierIndex(action.tier)
        failures[t] = min(failures[t] + 1, 6)
        if action.isReversal {
            lastReversalAt = nil
            reversalFailures += 1
            if reversalFailures >= Self.maxReversalFailures { reversalGaveUpAt = lastReversalPlannedAt }
        }
    }

    private mutating func resetReversalBackoff() {
        reversalFailures = 0
        reversalGaveUpAt = nil
    }

    /// Thaw/resume are planned every tick while their trigger holds, so a failing one (console not answering,
    /// AVD locked, no free ports) needs its own backoff: retry after 5 s, 10 s, 20 s, … and stop after
    /// `maxReversalFailures` until the user interacts again.
    private mutating func reversalAllowed(_ input: PolicyInput, now: Duration, notes: inout [String]) -> Bool {
        guard reversalFailures > 0 else { return true }
        if let gaveUp = reversalGaveUpAt {
            guard let li = input.lastUserInteraction, li > gaveUp else {
                notes.append("thaw/resume failed \(reversalFailures) times; waiting for user input")
                return false
            }
            // New input: one fresh attempt; if it fails too, the backoff starts over at the limit.
            reversalGaveUpAt = nil
            reversalFailures = Self.maxReversalFailures - 1
            return true
        }
        let wait = Self.reversalRetryBase * (1 << min(reversalFailures - 1, 6))
        if let last = lastReversalPlannedAt, now - last < wait {
            notes.append("thaw/resume backing off after \(reversalFailures) failure(s)")
            return false
        }
        return true
    }

    /// Reports that a maintenance run finished (successfully or partly).
    public mutating func recordMaintenance(unsupportedReclaim: Bool) {
        if unsupportedReclaim { disabledTiers.insert(.reclaim) }
    }

    /// Re-enables tiers previously marked unsupported (e.g. after the engine was upgraded).
    public mutating func resetCapabilities() { disabledTiers.removeAll() }

    // MARK: - Level classification

    /// Classifies a **guest** sample against the thresholds (MemAvailable fraction, PSI). With `relaxed`, the
    /// hysteresis margins are applied (used to decide whether a level can be left). Host signals are not part
    /// of this level: see `classifyHost`.
    public static func classify(guest: GuestMemory?, config: GovernorConfig, relaxed: Bool) -> (MemoryPressureLevel, String) {
        let th = config.thresholds
        var best: MemoryPressureLevel = .normal
        var reason = "calm"
        func consider(_ l: MemoryPressureLevel, _ why: @autoclosure () -> String) {
            if l > best { best = l; reason = why() }
        }
        if let g = guest, g.totalBytes > 0 {
            let f = g.availableFraction
            let h = relaxed ? th.availableHysteresis : 0
            let pct = String(format: "%.1f%%", f * 100)
            if f <= th.availableCritical + h { consider(.critical, "guest available \(pct)") }
            else if f <= th.availableHigh + h { consider(.high, "guest available \(pct)") }
            else if f <= th.availableElevated + h { consider(.elevated, "guest available \(pct)") }
            if let psi = g.pressureStall {
                let ph = relaxed ? th.psiHysteresis : 0
                let s = psi.someAvg10
                if psi.fullAvg10 >= th.psiFullCritical - ph { consider(.critical, String(format: "PSI full avg10 %.1f", psi.fullAvg10)) }
                if s >= th.psiSomeCritical - ph { consider(.critical, String(format: "PSI some avg10 %.1f", s)) }
                else if s >= th.psiSomeHigh - ph { consider(.high, String(format: "PSI some avg10 %.1f", s)) }
                else if s >= th.psiSomeElevated - ph { consider(.elevated, String(format: "PSI some avg10 %.1f", s)) }
            }
        }
        return (best, reason)
    }

    /// Host pressure: macOS memory pressure and the engine footprint against its budget.
    public static func classifyHost(_ host: HostMemory?, config: GovernorConfig, relaxed: Bool) -> (MemoryPressureLevel, String) {
        guard let hm = host else { return (.normal, "no host data") }
        let th = config.thresholds
        var best: MemoryPressureLevel = .normal
        var reason = "calm"
        func consider(_ l: MemoryPressureLevel, _ why: @autoclosure () -> String) {
            if l > best { best = l; reason = why() }
        }
        if let fp = hm.engineFootprintBytes, let budget = config.engineFootprintBudgetBytes, budget > 0 {
            let r = Double(fp) / Double(budget)
            let fh = relaxed ? th.footprintHysteresis : 0
            let txt = "engine footprint \(ByteCount.format(fp)) (\(Int((r * 100).rounded()))% of budget)"
            let raw: MemoryPressureLevel = r >= th.footprintCritical - fh ? .critical
                : r >= th.footprintHigh - fh ? .high : r >= th.footprintElevated - fh ? .elevated : .normal
            consider(min(raw, th.footprintMaxLevel), txt)
        }
        consider(hm.systemPressure, "host memory pressure \(hm.systemPressure)")
        return (best, reason)
    }

    /// Why guest-side actions (T1–T3, maintenance) must not run now, or nil.
    func guestActionsBlocked(_ input: PolicyInput, now: Duration) -> String? {
        if let since = runningSince, now - since < config.guestActionGraceAfterStart {
            return "grace period after boot/resume (\(Self.fmt(now - since)) of \(Self.fmt(config.guestActionGraceAfterStart)))"
        }
        if let pkg = input.foregroundPackages.first(where: isSensitiveForeground) {
            return "\(pkg) in the foreground (sign-in / store / installer)"
        }
        return nil
    }

    func isSensitiveForeground(_ pkg: String) -> Bool {
        config.sensitiveForegroundPackages.contains { pkg == $0 || pkg.hasPrefix($0 + ".") || pkg.hasPrefix($0 + ":") }
    }

    private mutating func updateLevel(guest: GuestMemory?) -> (MemoryPressureLevel, String) {
        if guest == nil { return (level, "no guest data") }
        let (enter, enterReason) = Self.classify(guest: guest, config: config, relaxed: false)
        let (hold, holdReason) = Self.classify(guest: guest, config: config, relaxed: true)
        if enter > level {
            if enter == .critical || config.escalationConfirmSamples <= 1 {
                level = enter
                pendingCount = 0
            } else {
                if enter >= pendingLevel && pendingCount > 0 { pendingCount += 1 } else { pendingCount = 1 }
                pendingLevel = enter
                if pendingCount >= config.escalationConfirmSamples {
                    level = enter
                    pendingCount = 0
                }
            }
            return (level, enterReason)
        }
        pendingCount = 0
        if hold < level { level = hold }
        return (level, level == .normal ? "calm" : holdReason)
    }

    // MARK: - Pressure tiers (T1–T3)

    private static func requiredTier(for level: MemoryPressureLevel) -> GovernorTier {
        switch level {
        case .normal: return .none
        case .elevated: return .trim
        case .high: return .killBackground
        case .critical: return .reclaim
        }
    }

    private static let pressureTiers: [GovernorTier] = [.trim, .killBackground, .reclaim]

    private func tierIndex(_ t: GovernorTier) -> Int { t.rawValue }

    private func previousEnabledTier(below tier: GovernorTier) -> GovernorTier {
        Self.pressureTiers.filter { $0 < tier && !disabledTiers.contains($0) }.last ?? .none
    }

    private func highestEnabledTier(atMost tier: GovernorTier) -> GovernorTier {
        Self.pressureTiers.filter { $0 <= tier && !disabledTiers.contains($0) }.last ?? .none
    }

    private func nextEnabledTier(above tier: GovernorTier, atMost cap: GovernorTier) -> GovernorTier? {
        Self.pressureTiers.first { $0 > tier && $0 <= cap && !disabledTiers.contains($0) }
    }

    private func effectiveCooldown(_ tier: GovernorTier) -> Duration {
        let base = config.cooldowns[tier]
        let f = failures[tierIndex(tier)]
        return f == 0 ? base : base * (1 << f)
    }

    private func cooldownExpired(_ tier: GovernorTier, now: Duration) -> Bool {
        guard let last = lastActionAt[tierIndex(tier)] else { return true }
        return now - last >= effectiveCooldown(tier)
    }

    private func helped(_ tier: GovernorTier, guest: GuestMemory) -> Bool {
        let i = tierIndex(tier)
        if lastNoop[i] { return false }
        if level < baselineLevel[i] { return true }
        guard let base = baselineAvailable[i] else { return false }
        return guest.availableFraction - base >= config.improvementFraction
    }

    private mutating func pressureStep(guest: GuestMemory, visible: Bool, now: Duration, notes: inout [String]) -> PlannedAction? {
        var cap = min(visible ? config.visibleTierCap : config.hiddenTierCap, .reclaim)
        if config.automationMode { cap = min(cap, GovernorConfig.automationTierCap) }
        let desired = highestEnabledTier(atMost: min(Self.requiredTier(for: level), cap))

        if desired < pressureTier {
            let since = calmSince ?? now
            calmSince = since
            if now - since >= config.deescalationCalm {
                pressureTier = desired
                calmSince = nil
            }
            return nil
        }
        calmSince = nil
        guard desired != .none else { return nil }

        var target = pressureTier
        var why: String
        if pressureTier == .none {
            target = Self.pressureTiers.first { !disabledTiers.contains($0) && $0 <= desired } ?? .none
            why = "pressure \(level): starting at \(target)"
        } else if desired > pressureTier {
            let i = tierIndex(pressureTier)
            let delay = level == .critical ? config.evaluationDelay / 2 : config.evaluationDelay
            if let last = lastActionAt[i] {
                let judged = now - last >= delay || lastNoop[i]
                if judged && !helped(pressureTier, guest: guest), let next = nextEnabledTier(above: pressureTier, atMost: desired) {
                    target = next
                    why = "pressure \(level): \(pressureTier) did not help, escalating"
                } else {
                    why = "pressure \(level): repeating \(pressureTier)"
                }
            } else {
                why = "pressure \(level): \(pressureTier) not yet applied"
            }
        } else {
            why = "pressure \(level): repeating \(pressureTier)"
        }
        guard target != .none else { return nil }
        if target != pressureTier {
            pressureTier = target
        }
        guard cooldownExpired(target, now: now) else { return nil }
        guard allowEscalation(target, now: now, notes: &notes) else { return nil }

        let action: GovernorAction
        switch target {
        case .trim:
            let lvl: TrimMemoryLevel = level >= .critical ? .complete : level >= .high ? .moderate : .background
            action = .trimMemory(level: lvl, packages: [])
        case .killBackground:
            action = .killBackground(packages: [])
        default:
            action = .reclaimGuestMemory(targetBytes: nil)
        }
        noteIssued(target, now: now, guest: guest)
        return PlannedAction(action: action, reason: why)
    }

    /// Rate limit for escalating actions: at most `maxActionsPerHour` in any rolling hour.
    private func allowEscalation(_ tier: GovernorTier, now: Duration, notes: inout [String]) -> Bool {
        guard let oldest = actionTimes.first, actionTimes.isFull else { return true }
        if now - oldest < .hours(1) {
            notes.append("\(tier) suppressed: \(config.maxActionsPerHour) actions in the last hour")
            return false
        }
        return true
    }

    private mutating func noteIssued(_ tier: GovernorTier, now: Duration, guest: GuestMemory?) {
        let i = tierIndex(tier)
        lastActionAt[i] = now
        baselineAvailable[i] = guest?.availableFraction
        baselineLevel[i] = level
        lastNoop[i] = false
        actionTimes.append(now)
    }

    // MARK: - Freeze / hibernate (T4/T5)

    private func interacted(_ input: PolicyInput, after t: Duration) -> Bool {
        guard let li = input.lastUserInteraction else { return false }
        return li > t
    }

    private func freezeReason(_ input: PolicyInput, idleFor: Duration, now: Duration) -> String? {
        guard !config.automationMode else { return nil }
        guard !input.isVisible, let hidden = hiddenSince else { return nil }
        var after = config.freezeWhenHiddenAfter
        var why = ""
        if hostLevel >= .high, let h = config.hostPressureFreezeAfter {
            after = min(after ?? h, h)
            why = ", host memory pressure \(hostLevel)"
        }
        guard let after, now - hidden >= after, idleFor >= after else { return nil }
        if let r = lastReversalAt, now - r < effectiveCooldown(.freeze) { return nil }
        guard cooldownExpired(.freeze, now: now) else { return nil }
        return "hidden \(Self.fmt(now - hidden)), idle \(Self.fmt(idleFor))\(why)"
    }

    private func hibernateReason(_ input: PolicyInput, frozenFor: Duration) -> String? {
        guard !input.isVisible, cooldownExpired(.hibernate, now: input.now) else { return nil }
        if config.hibernateOnHostCritical, input.host?.systemPressure == .critical {
            return "host memory pressure critical while frozen"
        }
        if hostLevel >= .high, let after = config.hibernateWhenFrozenUnderHostPressureAfter, frozenFor >= after {
            return "host memory pressure \(hostLevel) while frozen \(Self.fmt(frozenFor))"
        }
        if creepActive, let after = config.hibernateWhenFrozenUnderCreepAfter, frozenFor >= after {
            return "memory creep detected; frozen \(Self.fmt(frozenFor))"
        }
        if let after = config.hibernateWhenFrozenUnderCreepAfter, frozenFor >= after,
           let fp = input.host?.engineFootprintBytes, let budget = config.engineFootprintBudgetBytes, budget > 0,
           Double(fp) / Double(budget) >= config.thresholds.footprintCritical {
            return "engine footprint \(ByteCount.format(fp)) over budget; frozen \(Self.fmt(frozenFor))"
        }
        if let after = config.hibernateWhenFrozenAfter, frozenFor >= after {
            return "frozen \(Self.fmt(frozenFor))"
        }
        return nil
    }

    private mutating func trackEngineState(_ state: InstanceState, now: Duration) {
        defer { lastEngineState = state }
        switch state {
        case .frozen:
            if frozenSince == nil { frozenSince = now }
            hibernatedSince = nil
        case .hibernated:
            if hibernatedSince == nil { hibernatedSince = now }
            frozenSince = nil
        case .running:
            if lastEngineState != .running { runningSince = now }
            frozenSince = nil
            hibernatedSince = nil
            resetReversalBackoff()
            // A fresh engine process (after hibernate/stop/crash) invalidates footprint history.
            if let prev = lastEngineState, prev != .running, prev != .frozen {
                footprintTrend.reset()
                availableTrend.reset()
                creepActive = false
            }
        default:
            frozenSince = nil
        }
    }

    // MARK: - Long horizon

    private mutating func updateTrends(_ input: PolicyInput, now: Duration) -> CreepReport? {
        if let fp = input.host?.engineFootprintBytes, input.engineState.isRunningEngine {
            footprintTrend.add(Double(fp), at: now)
        }
        if let g = input.guest, input.engineState == .running {
            availableTrend.add(Double(g.availableBytes), at: now)
            smoothedAvailableFraction.add(g.availableFraction, at: now)
        }
        let lh = config.longHorizon
        var found: CreepReport?
        if let fit = footprintTrend.fit(), fit.span >= lh.minTrendWindow, fit.r2 >= lh.minTrendR2,
           fit.slopePerHour >= lh.footprintCreepBytesPerHour {
            found = CreepReport(signal: .engineFootprint, bytesPerHour: Int64(fit.slopePerHour), r2: fit.r2, window: fit.span)
        } else if let fit = availableTrend.fit(), fit.span >= lh.minTrendWindow, fit.r2 >= lh.minTrendR2,
                  fit.slopePerHour <= lh.availableCreepBytesPerHour {
            found = CreepReport(signal: .guestAvailable, bytesPerHour: Int64(fit.slopePerHour), r2: fit.r2, window: fit.span)
        }
        creepActive = found != nil
        guard let report = found else { return nil }
        if let last = lastCreepReportAt, now - last < lh.creepReportInterval { return nil }
        lastCreepReportAt = now
        return report
    }

    private mutating func maintenancePlan(_ input: PolicyInput, idleFor: Duration, now: Duration, notes: inout [String]) -> MaintenancePlan? {
        let lh = config.longHorizon
        guard level <= .elevated else { return nil }
        let interval = creepActive ? lh.maintenanceIntervalUnderCreep : lh.maintenanceInterval
        let since = lastMaintenanceAt ?? startedAt ?? now
        guard now - since >= interval, idleFor >= lh.maintenanceRequiresIdle else { return nil }
        if lh.maintenanceRequiresHidden && input.isVisible { return nil }
        guard allowEscalation(.trim, now: now, notes: &notes) else { return nil }
        lastMaintenanceAt = now
        actionTimes.append(now)
        var steps: [MaintenanceStep] = [.trimBackground, .killCached, .trimCaches, .compact]
        if !disabledTiers.contains(.reclaim) { steps.append(.reclaim) }
        let why = creepActive ? "creep detected; idle \(Self.fmt(idleFor))" : "scheduled; idle \(Self.fmt(idleFor))"
        return MaintenancePlan(steps: steps, trimCachesDesiredFreeBytes: lh.trimCachesDesiredFreeBytes, reason: why)
    }

    private func nextInterval(_ state: InstanceState) -> Duration {
        let s = config.sampling
        switch state {
        case .running:
            if level >= .high { return s.pressure }
            if level == .elevated || pressureTier != .none { return s.elevated }
            return s.calm
        case .booting:
            return s.elevated
        default:
            return s.frozen
        }
    }

    static func fmt(_ d: Duration) -> String {
        let s = Int(d.timeInterval.rounded())
        if s >= 3600 { return "\(s / 3600)h\(String(format: "%02d", (s % 3600) / 60))m" }
        if s >= 60 { return "\(s / 60)m\(String(format: "%02d", s % 60))s" }
        return "\(s)s"
    }
}
