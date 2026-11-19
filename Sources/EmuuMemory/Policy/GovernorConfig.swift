import Foundation
import EmuuBase

/// Enter thresholds for each pressure level. A level is *entered* when any signal crosses its
/// enter threshold and *held* until every signal is back past the threshold relaxed by the
/// hysteresis margins (see `GovernorPolicy.classify`).
public struct PressureThresholds: Codable, Sendable, Hashable {
    /// Guest MemAvailable/MemTotal at or below which the level is entered.
    public var availableElevated: Double
    public var availableHigh: Double
    public var availableCritical: Double
    /// Added to the available thresholds to leave a level (fraction, e.g. 0.04 = 4 points).
    public var availableHysteresis: Double

    /// PSI `some avg10` (percent) at or above which the level is entered.
    public var psiSomeElevated: Double
    public var psiSomeHigh: Double
    public var psiSomeCritical: Double
    /// PSI `full avg10` (percent) at or above which `.critical` is entered (all tasks stalled).
    public var psiFullCritical: Double
    /// Subtracted from the PSI thresholds to leave a level (percentage points).
    public var psiHysteresis: Double

    /// Engine footprint as a ratio of `GovernorConfig.engineFootprintBudgetBytes`.
    public var footprintElevated: Double
    public var footprintHigh: Double
    public var footprintCritical: Double
    /// Subtracted from the footprint ratios to leave a level.
    public var footprintHysteresis: Double
    /// Highest pressure level the footprint signal alone can produce. Guest-side tiers (trim/kill)
    /// barely change host footprint, so by default an over-budget engine only earns cheap T1 trims;
    /// its real remedies are reclaim (maintenance) and hibernate (see `GovernorPolicy`).
    public var footprintMaxLevel: MemoryPressureLevel = .elevated

    public init(availableElevated: Double, availableHigh: Double, availableCritical: Double, availableHysteresis: Double,
                psiSomeElevated: Double, psiSomeHigh: Double, psiSomeCritical: Double, psiFullCritical: Double, psiHysteresis: Double,
                footprintElevated: Double, footprintHigh: Double, footprintCritical: Double, footprintHysteresis: Double) {
        self.availableElevated = availableElevated
        self.availableHigh = availableHigh
        self.availableCritical = availableCritical
        self.availableHysteresis = availableHysteresis
        self.psiSomeElevated = psiSomeElevated
        self.psiSomeHigh = psiSomeHigh
        self.psiSomeCritical = psiSomeCritical
        self.psiFullCritical = psiFullCritical
        self.psiHysteresis = psiHysteresis
        self.footprintElevated = footprintElevated
        self.footprintHigh = footprintHigh
        self.footprintCritical = footprintCritical
        self.footprintHysteresis = footprintHysteresis
    }
}

/// Minimum time between two actions of the same tier.
public struct TierCooldowns: Codable, Sendable, Hashable {
    public var trim: Duration
    public var killBackground: Duration
    public var reclaim: Duration
    /// Minimum running time after a thaw/resume before freezing again (anti-flap).
    public var freeze: Duration
    public var hibernate: Duration

    public init(trim: Duration, killBackground: Duration, reclaim: Duration, freeze: Duration, hibernate: Duration) {
        self.trim = trim
        self.killBackground = killBackground
        self.reclaim = reclaim
        self.freeze = freeze
        self.hibernate = hibernate
    }

    public subscript(tier: GovernorTier) -> Duration {
        switch tier {
        case .none: return .zero
        case .trim: return trim
        case .killBackground: return killBackground
        case .reclaim: return reclaim
        case .freeze: return freeze
        case .hibernate: return hibernate
        }
    }
}

/// Adaptive sampling intervals.
public struct SamplingIntervals: Codable, Sendable, Hashable {
    /// Level normal and no active tier.
    public var calm: Duration
    /// Level elevated, or a tier is active.
    public var elevated: Duration
    /// Level high/critical.
    public var pressure: Duration
    /// Engine frozen: only host stats are read (no adb), at this interval.
    public var frozen: Duration
    /// How often the activity source (visibility/input) is polled while frozen/hibernated so a
    /// thaw/resume happens promptly. Cheap (in-process); `MemoryGovernor.nudge()` wakes immediately.
    public var activityPoll: Duration

    public init(calm: Duration, elevated: Duration, pressure: Duration, frozen: Duration, activityPoll: Duration) {
        self.calm = calm
        self.elevated = elevated
        self.pressure = pressure
        self.frozen = frozen
        self.activityPoll = activityPoll
    }
}

/// Long-horizon settings: creep detection and idle maintenance.
public struct LongHorizonConfig: Codable, Sendable, Hashable {
    /// Engine footprint slope (bytes/hour) above which creep is reported.
    public var footprintCreepBytesPerHour: Double
    /// Guest MemAvailable slope (bytes/hour, negative = shrinking) below which creep is reported.
    public var availableCreepBytesPerHour: Double
    /// Minimum window span before a trend is trusted.
    public var minTrendWindow: Duration
    /// Minimum r² for a trend to count as creep (rejects noisy, non-linear data).
    public var minTrendR2: Double
    /// Trend window: one point kept per `trendPointSpacing`, `trendCapacity` points max.
    public var trendPointSpacing: Duration
    public var trendCapacity: Int
    /// Do not report creep more often than this.
    public var creepReportInterval: Duration

    /// Normal time between maintenance runs.
    public var maintenanceInterval: Duration
    /// Time between maintenance runs while creep is detected.
    public var maintenanceIntervalUnderCreep: Duration
    /// User must have been idle (no input) this long for maintenance to run.
    public var maintenanceRequiresIdle: Duration
    /// When true, maintenance only runs while the display is hidden.
    public var maintenanceRequiresHidden: Bool
    /// Bytes passed to `pm trim-caches` during maintenance (desired free storage).
    public var trimCachesDesiredFreeBytes: UInt64

    public init(footprintCreepBytesPerHour: Double, availableCreepBytesPerHour: Double, minTrendWindow: Duration, minTrendR2: Double,
                trendPointSpacing: Duration, trendCapacity: Int, creepReportInterval: Duration,
                maintenanceInterval: Duration, maintenanceIntervalUnderCreep: Duration, maintenanceRequiresIdle: Duration,
                maintenanceRequiresHidden: Bool, trimCachesDesiredFreeBytes: UInt64) {
        self.footprintCreepBytesPerHour = footprintCreepBytesPerHour
        self.availableCreepBytesPerHour = availableCreepBytesPerHour
        self.minTrendWindow = minTrendWindow
        self.minTrendR2 = minTrendR2
        self.trendPointSpacing = trendPointSpacing
        self.trendCapacity = trendCapacity
        self.creepReportInterval = creepReportInterval
        self.maintenanceInterval = maintenanceInterval
        self.maintenanceIntervalUnderCreep = maintenanceIntervalUnderCreep
        self.maintenanceRequiresIdle = maintenanceRequiresIdle
        self.maintenanceRequiresHidden = maintenanceRequiresHidden
        self.trimCachesDesiredFreeBytes = trimCachesDesiredFreeBytes
    }
}

/// Everything the policy needs to decide. Build with `GovernorConfig.preset(_:)` and adjust.
public struct GovernorConfig: Codable, Sendable, Hashable {
    public var profile: MemoryProfile
    public var thresholds: PressureThresholds
    /// Expected engine footprint (guest RAM + engine overhead). nil disables the footprint signal.
    public var engineFootprintBudgetBytes: UInt64?
    public var cooldowns: TierCooldowns
    public var sampling: SamplingIntervals
    public var longHorizon: LongHorizonConfig

    /// Consecutive samples a higher level must be seen before it counts (critical is immediate).
    public var escalationConfirmSamples: Int
    /// Time after a tier's action before judging whether it helped.
    public var evaluationDelay: Duration
    /// Improvement in guest available fraction that counts as "helped" (e.g. 0.03 = 3 points).
    public var improvementFraction: Double
    /// Time the level must stay below a tier before the governor steps down from it.
    public var deescalationCalm: Duration

    /// Highest pressure tier (T1–T3) used while the display is visible.
    public var visibleTierCap: GovernorTier
    /// Highest pressure tier (T1–T3) used while hidden.
    public var hiddenTierCap: GovernorTier

    /// Freeze (T4) after the display has been hidden this long and the user idle at least as long. nil = never.
    public var freezeWhenHiddenAfter: Duration?
    /// Hibernate (T5) after being frozen this long. nil = never on a timer.
    public var hibernateWhenFrozenAfter: Duration?
    /// While frozen and creep is detected, hibernate after this shorter time (a hibernate/resume
    /// cycle discards the engine's accumulated footprint). nil = no special case.
    public var hibernateWhenFrozenUnderCreepAfter: Duration?
    /// While frozen, hibernate immediately when the host reaches `.critical` pressure.
    public var hibernateOnHostCritical: Bool
    /// Resume a hibernated instance automatically when it becomes visible / receives input.
    public var autoResume: Bool

    /// Upper bound on escalating actions (T1–T5) in any rolling hour. Reversals are never limited.
    public var maxActionsPerHour: Int

    /// Automation mode (test runners, Appium, Maestro, scripts driving the instance over adb): the governor
    /// keeps trimming and killing *background* apps (T1/T2, maintenance) but never freezes (T4) or
    /// hibernates (T5) the engine and never goes past T2. The effectors additionally skip the foreground app
    /// and every package with running instrumentation (they always do; see `GuestEffector`).
    public var automationMode: Bool = false

    /// No guest-side action (T1–T3, maintenance) for this long after the engine (re)enters `.running` (cold
    /// boot, quick-boot resume, thaw). Right after boot/resume the guest is busy restoring itself; MemAvailable
    /// is low for a while by design and trimming/killing then only disturbs what the user is about to use
    /// (2026-11-18: a T1→T2 sequence started 30 s after a resume, during Play Store sign-in).
    public var guestActionGraceAfterStart: Duration = .minutes(3)

    /// While one of these packages (or a dotted sub-process of it) is in the foreground, no guest-side action
    /// runs: account sign-in, Play Store purchases and package installs must never be disturbed.
    public var sensitiveForegroundPackages: [String] = GovernorConfig.defaultSensitiveForeground

    public static let defaultSensitiveForeground = [
        "com.android.vending", "com.google.android.gms", "com.google.android.gsf",
        "com.google.android.packageinstaller", "com.android.packageinstaller",
        "com.google.android.permissioncontroller", "com.android.permissioncontroller",
        "com.google.android.setupwizard", "com.android.settings.accounts",
    ]

    /// Under host memory pressure (macOS `warning` or worse, or an engine far over budget), a hidden and idle
    /// instance is frozen after this (instead of `freezeWhenHiddenAfter`), and a frozen one hibernated after
    /// `hibernateWhenFrozenUnderHostPressureAfter`. Host pressure never triggers guest-side trim/kill: those
    /// do not shrink the engine's host footprint (docs/BENCHMARKS.md). nil = no special case.
    public var hostPressureFreezeAfter: Duration? = .minutes(1)
    public var hibernateWhenFrozenUnderHostPressureAfter: Duration? = .minutes(2)

    /// The highest pressure tier automation mode allows.
    public static let automationTierCap: GovernorTier = .killBackground

    public init(profile: MemoryProfile, thresholds: PressureThresholds, engineFootprintBudgetBytes: UInt64?, cooldowns: TierCooldowns,
                sampling: SamplingIntervals, longHorizon: LongHorizonConfig, escalationConfirmSamples: Int, evaluationDelay: Duration,
                improvementFraction: Double, deescalationCalm: Duration, visibleTierCap: GovernorTier, hiddenTierCap: GovernorTier,
                freezeWhenHiddenAfter: Duration?, hibernateWhenFrozenAfter: Duration?, hibernateWhenFrozenUnderCreepAfter: Duration?,
                hibernateOnHostCritical: Bool, autoResume: Bool, maxActionsPerHour: Int) {
        self.profile = profile
        self.thresholds = thresholds
        self.engineFootprintBudgetBytes = engineFootprintBudgetBytes
        self.cooldowns = cooldowns
        self.sampling = sampling
        self.longHorizon = longHorizon
        self.escalationConfirmSamples = escalationConfirmSamples
        self.evaluationDelay = evaluationDelay
        self.improvementFraction = improvementFraction
        self.deescalationCalm = deescalationCalm
        self.visibleTierCap = visibleTierCap
        self.hiddenTierCap = hiddenTierCap
        self.freezeWhenHiddenAfter = freezeWhenHiddenAfter
        self.hibernateWhenFrozenAfter = hibernateWhenFrozenAfter
        self.hibernateWhenFrozenUnderCreepAfter = hibernateWhenFrozenUnderCreepAfter
        self.hibernateOnHostCritical = hibernateOnHostCritical
        self.autoResume = autoResume
        self.maxActionsPerHour = maxActionsPerHour
    }

    /// Engine footprint budget for a guest of `guestRAMMB`: 2 × guest RAM + 1 GiB.
    ///
    /// Empirical basis (engine 36.4.9, `-memory 2048 -gpu host`, API 36 Play image, minutes after
    /// boot): `phys_footprint` of the QEMU process was 4.3–4.4 GiB (Activity Monitor "Memory", which
    /// includes ~1.5 GiB compressed), resident 2.8 GiB. Guest RAM + a fixed overhead would flag every
    /// healthy instance as critical.
    public static func footprintBudget(guestRAMMB: Int) -> UInt64 {
        ByteCount.mib(guestRAMMB) * 2 + ByteCount.gib
    }

    /// Presets. `frugal` is the "lite" profile; `performance` is the gaming profile (it never
    /// kills, freezes or reclaims while the game is on screen — background apps are only asked to trim).
    public static func preset(_ profile: MemoryProfile, guestRAMMB: Int? = nil) -> GovernorConfig {
        let budget = footprintBudget(guestRAMMB: guestRAMMB ?? profile.suggestedRAMMB)
        switch profile {
        case .frugal:
            return GovernorConfig(
                profile: .frugal,
                thresholds: PressureThresholds(
                    availableElevated: 0.30, availableHigh: 0.20, availableCritical: 0.10, availableHysteresis: 0.05,
                    psiSomeElevated: 5, psiSomeHigh: 15, psiSomeCritical: 35, psiFullCritical: 10, psiHysteresis: 3,
                    footprintElevated: 0.95, footprintHigh: 1.10, footprintCritical: 1.30, footprintHysteresis: 0.05),
                engineFootprintBudgetBytes: budget,
                cooldowns: TierCooldowns(trim: .minutes(2), killBackground: .minutes(4), reclaim: .minutes(10), freeze: .minutes(2), hibernate: .minutes(30)),
                sampling: SamplingIntervals(calm: .seconds(30), elevated: .seconds(10), pressure: .seconds(5), frozen: .seconds(60), activityPoll: .seconds(1)),
                longHorizon: LongHorizonConfig(
                    footprintCreepBytesPerHour: Double(ByteCount.mib(64)), availableCreepBytesPerHour: -Double(ByteCount.mib(96)),
                    minTrendWindow: .hours(1), minTrendR2: 0.6, trendPointSpacing: .minutes(1), trendCapacity: 240,
                    creepReportInterval: .hours(1),
                    maintenanceInterval: .hours(1), maintenanceIntervalUnderCreep: .minutes(30), maintenanceRequiresIdle: .minutes(5),
                    maintenanceRequiresHidden: false, trimCachesDesiredFreeBytes: ByteCount.gib * 2),
                escalationConfirmSamples: 2, evaluationDelay: .seconds(30), improvementFraction: 0.03, deescalationCalm: .minutes(2),
                visibleTierCap: .reclaim, hiddenTierCap: .reclaim,
                // Lite hibernates 5 min into a freeze: a SIGSTOPped engine keeps its whole phys_footprint (macOS only
                // compresses/swaps it), while hibernate frees it all and resumes in ~2 s (docs/BENCHMARKS.md).
                freezeWhenHiddenAfter: .minutes(2), hibernateWhenFrozenAfter: .minutes(5), hibernateWhenFrozenUnderCreepAfter: .minutes(5),
                hibernateOnHostCritical: true, autoResume: true, maxActionsPerHour: 30)
        case .balanced:
            return GovernorConfig(
                profile: .balanced,
                thresholds: PressureThresholds(
                    availableElevated: 0.22, availableHigh: 0.14, availableCritical: 0.07, availableHysteresis: 0.04,
                    psiSomeElevated: 8, psiSomeHigh: 20, psiSomeCritical: 40, psiFullCritical: 15, psiHysteresis: 3,
                    footprintElevated: 1.05, footprintHigh: 1.20, footprintCritical: 1.40, footprintHysteresis: 0.05),
                engineFootprintBudgetBytes: budget,
                cooldowns: TierCooldowns(trim: .minutes(3), killBackground: .minutes(6), reclaim: .minutes(15), freeze: .minutes(3), hibernate: .minutes(30)),
                sampling: SamplingIntervals(calm: .seconds(30), elevated: .seconds(10), pressure: .seconds(5), frozen: .seconds(60), activityPoll: .seconds(1)),
                longHorizon: LongHorizonConfig(
                    footprintCreepBytesPerHour: Double(ByteCount.mib(96)), availableCreepBytesPerHour: -Double(ByteCount.mib(128)),
                    minTrendWindow: .hours(1), minTrendR2: 0.6, trendPointSpacing: .minutes(1), trendCapacity: 240,
                    creepReportInterval: .hours(1),
                    maintenanceInterval: .hours(2), maintenanceIntervalUnderCreep: .minutes(45), maintenanceRequiresIdle: .minutes(10),
                    maintenanceRequiresHidden: false, trimCachesDesiredFreeBytes: ByteCount.gib * 2),
                escalationConfirmSamples: 2, evaluationDelay: .seconds(45), improvementFraction: 0.03, deescalationCalm: .minutes(3),
                visibleTierCap: .reclaim, hiddenTierCap: .reclaim,
                freezeWhenHiddenAfter: .minutes(5), hibernateWhenFrozenAfter: .hours(2), hibernateWhenFrozenUnderCreepAfter: .minutes(30),
                hibernateOnHostCritical: true, autoResume: true, maxActionsPerHour: 24)
        case .performance:
            return GovernorConfig(
                profile: .performance,
                thresholds: PressureThresholds(
                    availableElevated: 0.15, availableHigh: 0.09, availableCritical: 0.05, availableHysteresis: 0.04,
                    psiSomeElevated: 12, psiSomeHigh: 25, psiSomeCritical: 50, psiFullCritical: 20, psiHysteresis: 4,
                    footprintElevated: 1.15, footprintHigh: 1.30, footprintCritical: 1.50, footprintHysteresis: 0.05),
                engineFootprintBudgetBytes: budget,
                cooldowns: TierCooldowns(trim: .minutes(5), killBackground: .minutes(10), reclaim: .minutes(20), freeze: .minutes(5), hibernate: .hours(1)),
                sampling: SamplingIntervals(calm: .seconds(45), elevated: .seconds(15), pressure: .seconds(10), frozen: .seconds(60), activityPoll: .seconds(1)),
                longHorizon: LongHorizonConfig(
                    footprintCreepBytesPerHour: Double(ByteCount.mib(128)), availableCreepBytesPerHour: -Double(ByteCount.mib(192)),
                    minTrendWindow: .hours(1), minTrendR2: 0.6, trendPointSpacing: .minutes(1), trendCapacity: 240,
                    creepReportInterval: .hours(1),
                    maintenanceInterval: .hours(4), maintenanceIntervalUnderCreep: .hours(1), maintenanceRequiresIdle: .minutes(15),
                    maintenanceRequiresHidden: true, trimCachesDesiredFreeBytes: ByteCount.gib * 2),
                escalationConfirmSamples: 3, evaluationDelay: .seconds(60), improvementFraction: 0.03, deescalationCalm: .minutes(5),
                visibleTierCap: .trim, hiddenTierCap: .reclaim,
                freezeWhenHiddenAfter: .minutes(15), hibernateWhenFrozenAfter: nil, hibernateWhenFrozenUnderCreepAfter: .hours(1),
                hibernateOnHostCritical: true, autoResume: true, maxActionsPerHour: 12)
        }
    }
}
