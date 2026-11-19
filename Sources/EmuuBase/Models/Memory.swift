import Foundation

/// Coarse pressure classification used by both host and guest signals. Ordered: `.normal < .critical`.
public enum MemoryPressureLevel: Int, Codable, Sendable, Hashable, Comparable, CaseIterable, CustomStringConvertible {
    case normal = 0
    /// Worth trimming opportunistically.
    case elevated = 1
    /// Reclaim actively.
    case high = 2
    /// Act now (kill / freeze / hibernate).
    case critical = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String {
        switch self {
        case .normal: return "normal"
        case .elevated: return "elevated"
        case .high: return "high"
        case .critical: return "critical"
        }
    }
}

/// Linux PSI (`/proc/pressure/memory`) averages, in percent (0…100).
public struct PressureStall: Codable, Sendable, Hashable {
    public var someAvg10: Double
    public var someAvg60: Double
    public var someAvg300: Double
    public var fullAvg10: Double
    public var fullAvg60: Double
    public var fullAvg300: Double

    public init(someAvg10: Double, someAvg60: Double, someAvg300: Double, fullAvg10: Double, fullAvg60: Double, fullAvg300: Double) {
        self.someAvg10 = someAvg10
        self.someAvg60 = someAvg60
        self.someAvg300 = someAvg300
        self.fullAvg10 = fullAvg10
        self.fullAvg60 = fullAvg60
        self.fullAvg300 = fullAvg300
    }
}

/// Memory use of one guest app (from `dumpsys meminfo` or similar), when cheaply available.
public struct AppMemoryUsage: Codable, Sendable, Hashable {
    public var packageName: String
    public var pid: Int32?
    /// Proportional set size in bytes.
    public var pssBytes: UInt64
    /// Whether the app is in the foreground (top) state.
    public var isForeground: Bool

    public init(packageName: String, pid: Int32? = nil, pssBytes: UInt64, isForeground: Bool = false) {
        self.packageName = packageName
        self.pid = pid
        self.pssBytes = pssBytes
        self.isForeground = isForeground
    }
}

/// Guest-side memory view. All sizes in bytes (converted from /proc/meminfo kB × 1024).
public struct GuestMemory: Codable, Sendable, Hashable {
    public var totalBytes: UInt64
    public var freeBytes: UInt64
    public var availableBytes: UInt64
    public var cachedBytes: UInt64
    public var buffersBytes: UInt64
    public var swapTotalBytes: UInt64
    public var swapFreeBytes: UInt64
    /// PSI averages, nil if `/proc/pressure/memory` is unavailable.
    public var pressureStall: PressureStall?
    /// Number of processes in cached (background) state, when measured.
    public var cachedProcessCount: Int?
    /// Per-app usage, when measured (expensive; sampled rarely).
    public var apps: [AppMemoryUsage]

    public init(
        totalBytes: UInt64, freeBytes: UInt64, availableBytes: UInt64,
        cachedBytes: UInt64 = 0, buffersBytes: UInt64 = 0,
        swapTotalBytes: UInt64 = 0, swapFreeBytes: UInt64 = 0,
        pressureStall: PressureStall? = nil, cachedProcessCount: Int? = nil, apps: [AppMemoryUsage] = []
    ) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.availableBytes = availableBytes
        self.cachedBytes = cachedBytes
        self.buffersBytes = buffersBytes
        self.swapTotalBytes = swapTotalBytes
        self.swapFreeBytes = swapFreeBytes
        self.pressureStall = pressureStall
        self.cachedProcessCount = cachedProcessCount
        self.apps = apps
    }

    /// MemAvailable / MemTotal in 0…1 (0 if total is 0).
    public var availableFraction: Double {
        totalBytes == 0 ? 0 : Double(availableBytes) / Double(totalBytes)
    }

    public var usedBytes: UInt64 { totalBytes > availableBytes ? totalBytes - availableBytes : 0 }
    public var swapUsedBytes: UInt64 { swapTotalBytes > swapFreeBytes ? swapTotalBytes - swapFreeBytes : 0 }
}

/// Host-side view of the engine process and the Mac.
public struct HostMemory: Codable, Sendable, Hashable {
    /// Engine `phys_footprint` (what Activity Monitor calls "Memory"), from `proc_pid_rusage`.
    public var engineFootprintBytes: UInt64?
    /// Engine resident size.
    public var engineResidentBytes: UInt64?
    /// Latest system memory-pressure level (DispatchSource memory pressure / sysctl).
    public var systemPressure: MemoryPressureLevel
    /// Physical memory of the Mac.
    public var physicalMemoryBytes: UInt64?

    public init(engineFootprintBytes: UInt64? = nil, engineResidentBytes: UInt64? = nil, systemPressure: MemoryPressureLevel = .normal, physicalMemoryBytes: UInt64? = nil) {
        self.engineFootprintBytes = engineFootprintBytes
        self.engineResidentBytes = engineResidentBytes
        self.systemPressure = systemPressure
        self.physicalMemoryBytes = physicalMemoryBytes
    }
}

/// One combined observation fed to the governor policy. Either side may be missing (e.g. guest
/// unreachable while frozen).
public struct MemorySample: Codable, Sendable, Hashable {
    public var instanceID: InstanceID
    /// Wall-clock time for display/logging.
    public var timestamp: Date
    /// Monotonic reading (`EmuuClock.monotonicNow()`) for policy timing.
    public var monotonic: Duration
    public var guest: GuestMemory?
    public var host: HostMemory?

    public init(instanceID: InstanceID, timestamp: Date, monotonic: Duration, guest: GuestMemory? = nil, host: HostMemory? = nil) {
        self.instanceID = instanceID
        self.timestamp = timestamp
        self.monotonic = monotonic
        self.guest = guest
        self.host = host
    }
}

/// Android `am send-trim-memory` levels (names as accepted by the `am` command, per AOSP
/// ActivityManagerShellCommand). Ordered from mildest to most severe.
public enum TrimMemoryLevel: String, Codable, Sendable, Hashable, CaseIterable {
    case runningModerate = "RUNNING_MODERATE"
    case runningLow = "RUNNING_LOW"
    case runningCritical = "RUNNING_CRITICAL"
    case uiHidden = "HIDDEN"
    case background = "BACKGROUND"
    case moderate = "MODERATE"
    case complete = "COMPLETE"
}

/// Escalation tiers of the memory governor.
public enum GovernorTier: Int, Codable, Sendable, Hashable, Comparable, CaseIterable, CustomStringConvertible {
    case none = 0
    /// T1: ask apps to trim, trim package caches.
    case trim = 1
    /// T2: kill cached/background processes.
    case killBackground = 2
    /// T3: return guest memory to the host (balloon or engine equivalent).
    case reclaim = 3
    /// T4: pause the engine while hidden/idle.
    case freeze = 4
    /// T5: snapshot + quit; resume via quick-boot snapshot.
    case hibernate = 5

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String {
        switch self {
        case .none: return "T0 none"
        case .trim: return "T1 trim"
        case .killBackground: return "T2 kill-background"
        case .reclaim: return "T3 reclaim"
        case .freeze: return "T4 freeze"
        case .hibernate: return "T5 hibernate"
        }
    }
}

/// Concrete actions the policy can request. Effectors (in EmuuMemory, using `DeviceShell` and
/// `EngineControl`) carry them out. Reversal actions (`thaw`, `resume`) have tier `.none`.
public enum GovernorAction: Codable, Sendable, Hashable, CustomStringConvertible {
    /// T1: `am send-trim-memory <pkg> <level>` for each package (empty = all background apps).
    case trimMemory(level: TrimMemoryLevel, packages: [String])
    /// T1: `pm trim-caches <desiredFreeBytes>`.
    case trimCaches(desiredFreeBytes: UInt64)
    /// T2: kill cached/background processes (`am kill-all`, or targeted `am kill <pkg>`).
    case killBackground(packages: [String])
    /// T3: reclaim guest memory to the host; nil target = as much as the mechanism allows.
    case reclaimGuestMemory(targetBytes: UInt64?)
    /// T4: pause the engine.
    case freeze
    /// Undo T4.
    case thaw
    /// T5: snapshot + quit.
    case hibernate
    /// Undo T5: relaunch from the hibernation snapshot.
    case resume

    public var tier: GovernorTier {
        switch self {
        case .trimMemory, .trimCaches: return .trim
        case .killBackground: return .killBackground
        case .reclaimGuestMemory: return .reclaim
        case .freeze: return .freeze
        case .hibernate: return .hibernate
        case .thaw, .resume: return .none
        }
    }

    /// True for actions that undo an earlier tier rather than escalate.
    public var isReversal: Bool {
        switch self {
        case .thaw, .resume: return true
        default: return false
        }
    }

    public var description: String {
        switch self {
        case .trimMemory(let level, let packages):
            return "trimMemory(\(level.rawValue), \(packages.isEmpty ? "background" : packages.joined(separator: ",")))"
        case .trimCaches(let bytes): return "trimCaches(\(ByteCount.format(bytes)))"
        case .killBackground(let packages):
            return "killBackground(\(packages.isEmpty ? "all" : packages.joined(separator: ",")))"
        case .reclaimGuestMemory(let target): return "reclaimGuestMemory(\(target.map(ByteCount.format) ?? "max"))"
        case .freeze: return "freeze"
        case .thaw: return "thaw"
        case .hibernate: return "hibernate"
        case .resume: return "resume"
        }
    }
}

/// Result reported by an effector for one action.
public struct EffectorOutcome: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable, Hashable {
        /// The action was carried out.
        case applied
        /// Nothing to do (e.g. no background apps).
        case noop
        /// The mechanism is not available in this engine/guest; the policy should stop requesting it.
        case unsupported
    }

    public var status: Status
    public var detail: String
    /// Measured or estimated bytes freed, when known.
    public var reclaimedBytes: UInt64?

    public init(status: Status, detail: String = "", reclaimedBytes: UInt64? = nil) {
        self.status = status
        self.detail = detail
        self.reclaimedBytes = reclaimedBytes
    }

    public static func applied(_ detail: String = "", reclaimedBytes: UInt64? = nil) -> EffectorOutcome {
        EffectorOutcome(status: .applied, detail: detail, reclaimedBytes: reclaimedBytes)
    }

    public static func noop(_ detail: String = "") -> EffectorOutcome { EffectorOutcome(status: .noop, detail: detail) }
    public static func unsupported(_ detail: String) -> EffectorOutcome { EffectorOutcome(status: .unsupported, detail: detail) }
}

/// Observable governor history (UI, logs, CLI `emuu mem watch`).
public struct GovernorEvent: Codable, Sendable, Hashable {
    public enum Kind: Codable, Sendable, Hashable {
        case sampled(MemorySample)
        case tierChanged(from: GovernorTier, to: GovernorTier, reason: String)
        case actionPlanned(GovernorAction, reason: String)
        case actionApplied(GovernorAction, EffectorOutcome)
        case actionFailed(GovernorAction, message: String)
        /// Long-run creep detected on engine footprint (bytes per hour slope over the window).
        case creepDetected(bytesPerHour: Int64, window: Duration)
        case stateChanged(InstanceState)
        case maintenanceRan(summary: String)
        /// The guest kernel restarted under a running engine (its `boot_id` changed between two samples).
        /// `recentActions` are the governor's last guest/engine actions before it (newest last), for diagnosis.
        case guestRebooted(uptime: Duration, recentActions: [String])
    }

    public var instanceID: InstanceID
    public var timestamp: Date
    public var kind: Kind

    public init(instanceID: InstanceID, timestamp: Date, kind: Kind) {
        self.instanceID = instanceID
        self.timestamp = timestamp
        self.kind = kind
    }
}
