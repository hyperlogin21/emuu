import Foundation
import EmuuBase

/// Overall result of a health check.
public enum HealthVerdict: String, Codable, Sendable, Hashable, CaseIterable {
    case healthy
    /// Usable but something is off (unexpected guest reboot, ANR dialog in front, /data nearly full, booting).
    case degraded
    /// The engine or guest does not answer (SIGSTOPped from outside, adb shell/framework timeouts).
    case hung
    /// The engine process is gone.
    case dead
    /// Frozen by Emuu on purpose (T4 / `emuu freeze`): not a fault.
    case frozen
    /// Not running and not expected to be (stopped/hibernated).
    case stopped
}

public enum ProbeStatus: String, Codable, Sendable, Hashable { case ok, fail, skip }

public struct ProbeResult: Codable, Sendable, Hashable {
    public var name: String
    public var status: ProbeStatus
    public var detail: String
    public var millis: Int?

    public init(name: String, status: ProbeStatus, detail: String, millis: Int? = nil) {
        self.name = name
        self.status = status
        self.detail = detail
        self.millis = millis
    }
}

/// The recovery steps, in escalation order. Each is a real operation (docs/ARCHITECTURE.md, "Self-healing").
public enum HealStep: String, Codable, Sendable, Hashable, CaseIterable {
    /// SIGCONT an engine that someone else SIGSTOPped.
    case thaw
    /// `adb reconnect offline` / `adb -s S reconnect` for an offline transport while the console answers.
    case reconnectADB = "reconnect-adb"
    /// Farm devices: console `avd snapshot load default_boot` (back to the golden state; works while the guest hangs).
    case reset
    /// `adb reboot`: guest restart, engine keeps running (needs a working adbd).
    case softReboot = "soft-reboot"
    /// Engine stopped (console kill → SIGTERM → SIGKILL) and started again from the quick-boot snapshot.
    case hardRestart = "hard-restart"
    /// Engine stopped and started with a cold boot (quick-boot snapshot discarded).
    case coldBoot = "cold-boot"
    /// Farm devices: destroy the clone and resume a fresh one from the golden image.
    case replace
}

/// What the probes found (input of the pure evaluator).
public struct HealthFacts: Codable, Sendable, Hashable {
    public var engineAlive: Bool
    /// The engine process is in state T (SIGSTOP).
    public var engineStopped: Bool = false
    /// Emuu's freeze marker is set (`run/<id>.frozen`).
    public var frozenByEmuu: Bool = false
    /// Console answered its greeting (nil = not probed).
    public var consoleOK: Bool?
    /// `adb get-state`: device, offline, unauthorized, missing (nil = not probed).
    public var adbState: String?
    public var shellOK: Bool?
    public var bootCompleted: Bool?
    /// system_server answered a binder call (`cmd package resolve-activity`/`pm path android`) in time.
    public var frameworkOK: Bool?
    public var bootID: String?
    /// The boot id the device should have (farm: the golden's; instances: the one seen at the previous check).
    public var expectedBootID: String?
    public var uptimeSeconds: Double?
    /// Window title of an "isn't responding" / "keeps stopping" system dialog in front, if any.
    public var systemDialog: String?
    public var dataFreeBytes: UInt64?
    /// Still within the boot/resume grace period: not-yet-booted is expected.
    public var withinBootGrace: Bool = false

    public init(engineAlive: Bool) { self.engineAlive = engineAlive }

    public static let minimumDataFreeBytes: UInt64 = 256 << 20
}

public struct HealthEvaluation: Codable, Sendable, Hashable {
    public var verdict: HealthVerdict
    public var reason: String
    /// What broke, for choosing the escalation ladder.
    public var fault: HealthFault?

    public init(verdict: HealthVerdict, reason: String, fault: HealthFault?) {
        self.verdict = verdict
        self.reason = reason
        self.fault = fault
    }
}

public enum HealthFault: String, Codable, Sendable, Hashable {
    case engineDead = "engine-dead"
    case engineStoppedExternally = "engine-stopped"
    case consoleUnresponsive = "console-unresponsive"
    case adbOffline = "adb-offline"
    case guestUnresponsive = "guest-unresponsive"
    case frameworkUnresponsive = "framework-unresponsive"
    case notBooted = "not-booted"
    case guestRebooted = "guest-rebooted"
    case systemDialog = "system-dialog"
    case dataFull = "data-full"
}

/// Pure: probe facts → verdict. Order matters: the most fundamental failure wins.
public enum HealthEvaluator {
    public static func evaluate(_ f: HealthFacts) -> HealthEvaluation {
        if !f.engineAlive { return .init(verdict: .dead, reason: "engine process is gone", fault: .engineDead) }
        if f.engineStopped {
            return f.frozenByEmuu
                ? .init(verdict: .frozen, reason: "frozen by Emuu (SIGSTOP); thaw with `emuu thaw`", fault: nil)
                : .init(verdict: .hung, reason: "engine is SIGSTOPped but Emuu did not freeze it", fault: .engineStoppedExternally)
        }
        if f.consoleOK == false && f.shellOK != true {
            return .init(verdict: .hung, reason: "engine console and adb do not answer", fault: .consoleUnresponsive)
        }
        if let s = f.adbState, s != "device" {
            if f.withinBootGrace { return .init(verdict: .degraded, reason: "booting (adb \(s))", fault: .notBooted) }
            return .init(verdict: .hung, reason: "adb transport is \(s)", fault: .adbOffline)
        }
        if f.shellOK == false {
            if f.withinBootGrace { return .init(verdict: .degraded, reason: "booting (adb shell not answering yet)", fault: .notBooted) }
            return .init(verdict: .hung, reason: "adb shell does not answer in time", fault: .guestUnresponsive)
        }
        if f.bootCompleted == false {
            if f.withinBootGrace { return .init(verdict: .degraded, reason: "booting (sys.boot_completed not set)", fault: .notBooted) }
            return .init(verdict: .hung, reason: "Android did not finish booting", fault: .notBooted)
        }
        if f.frameworkOK == false {
            return .init(verdict: .hung, reason: "system_server does not answer binder calls (framework hang)", fault: .frameworkUnresponsive)
        }
        if let b = f.bootID, let e = f.expectedBootID, b != e {
            return .init(verdict: .degraded, reason: "guest rebooted unexpectedly (boot_id changed)", fault: .guestRebooted)
        }
        if let d = f.systemDialog {
            return .init(verdict: .degraded, reason: "system dialog in front: \(d)", fault: .systemDialog)
        }
        if let free = f.dataFreeBytes, free < HealthFacts.minimumDataFreeBytes {
            return .init(verdict: .degraded, reason: "/data has only \(ByteCount.format(free)) free", fault: .dataFull)
        }
        return .init(verdict: .healthy, reason: "ok", fault: nil)
    }
}

/// Compact health record kept with farm devices and in status output.
public struct HealthSummary: Codable, Sendable, Hashable {
    public var verdict: HealthVerdict
    public var reason: String
    public var at: Date

    public init(verdict: HealthVerdict, reason: String, at: Date) {
        self.verdict = verdict
        self.reason = reason
        self.at = at
    }
}

/// `emuu health --json` document.
public struct HealthReport: Codable, Sendable, Hashable {
    public var instance: String
    public var serial: String?
    public var verdict: HealthVerdict
    public var reason: String
    public var fault: HealthFault?
    public var checkedAt: Date
    public var probes: [ProbeResult]
    public var bootID: String?
    /// First step `emuu heal` would take (nil when healthy or nothing safe applies).
    public var suggestedStep: HealStep?

    public init(instance: String, serial: String?, verdict: HealthVerdict, reason: String, fault: HealthFault?,
                checkedAt: Date, probes: [ProbeResult], bootID: String?, suggestedStep: HealStep?) {
        self.instance = instance
        self.serial = serial
        self.verdict = verdict
        self.reason = reason
        self.fault = fault
        self.checkedAt = checkedAt
        self.probes = probes
        self.bootID = bootID
        self.suggestedStep = suggestedStep
    }

    public var summary: HealthSummary { HealthSummary(verdict: verdict, reason: reason, at: checkedAt) }
}

/// Escalation ladders: the minimal step first, each later step more invasive. Pure.
public enum HealLadder {
    public static func steps(for fault: HealthFault?, farmDevice: Bool) -> [HealStep] {
        guard let fault else { return [] }
        if farmDevice {
            switch fault {
            case .engineDead: return [.replace]
            case .engineStoppedExternally: return [.thaw, .replace]
            case .consoleUnresponsive: return [.replace]
            case .adbOffline: return [.reconnectADB, .reset, .replace]
            case .guestUnresponsive, .frameworkUnresponsive, .notBooted, .guestRebooted: return [.reset, .replace]
            case .systemDialog, .dataFull: return [.reset, .replace]
            }
        }
        switch fault {
        case .engineDead: return [.hardRestart, .coldBoot]
        case .engineStoppedExternally: return [.thaw, .hardRestart, .coldBoot]
        case .consoleUnresponsive: return [.hardRestart, .coldBoot]
        case .adbOffline: return [.reconnectADB, .hardRestart, .coldBoot]
        case .guestUnresponsive, .notBooted: return [.hardRestart, .coldBoot]
        case .frameworkUnresponsive: return [.softReboot, .hardRestart, .coldBoot]
        // Informational on an interactive instance: the user's own app, their data, or a reboot that already
        // completed. Nothing is restarted automatically.
        case .guestRebooted, .systemDialog, .dataFull: return []
        }
    }
}

/// Self-healing policy knobs.
public struct SelfHealPolicy: Codable, Sendable, Hashable {
    /// Consecutive bad checks before acting (a dead engine acts on the first).
    public var confirmations: Int = 2
    /// Recoveries allowed within `window` before the circuit breaker opens.
    public var maxAttempts: Int = 3
    public var window: TimeInterval = 1800
    public var backoffBase: TimeInterval = 20
    public var backoffMax: TimeInterval = 600

    public init() {}

    public func backoff(afterAttempt n: Int) -> TimeInterval {
        min(backoffMax, backoffBase * pow(2, Double(max(0, n - 1))))
    }
}

/// Pure self-healing state machine: health observations in, heal decisions out.
public struct SelfHealState: Codable, Sendable, Hashable {
    public enum Decision: Equatable, Sendable {
        case none
        case heal(HealStep, reason: String)
        /// Circuit breaker opened: stop retrying and surface the instance as failed.
        case giveUp(reason: String)
    }

    public var consecutiveBad = 0
    public var attempts: [Date] = []
    public var nextAllowed: Date?
    public var ladderIndex = 0
    public var failed = false
    public var lastFault: HealthFault?

    public init() {}

    public mutating func observe(_ eval: HealthEvaluation, farmDevice: Bool, now: Date, policy: SelfHealPolicy) -> Decision {
        let ladder = HealLadder.steps(for: eval.fault, farmDevice: farmDevice)
        guard eval.verdict == .hung || eval.verdict == .dead || (eval.verdict == .degraded && !ladder.isEmpty && eval.fault != .notBooted) else {
            if eval.verdict == .healthy || eval.verdict == .frozen || eval.verdict == .stopped {
                consecutiveBad = 0
                ladderIndex = 0
                lastFault = nil
            }
            return .none
        }
        if failed { return .none }
        if eval.fault != lastFault { ladderIndex = 0 }
        lastFault = eval.fault
        consecutiveBad += 1
        let needed = eval.verdict == .dead ? 1 : max(1, policy.confirmations)
        guard consecutiveBad >= needed, !ladder.isEmpty else { return .none }
        if let nextAllowed, now < nextAllowed { return .none }
        attempts = attempts.filter { now.timeIntervalSince($0) < policy.window }
        if attempts.count >= policy.maxAttempts {
            failed = true
            return .giveUp(reason: "\(attempts.count) recoveries in \(Int(policy.window / 60)) min did not fix it (\(eval.reason))")
        }
        let step = ladder[min(ladderIndex, ladder.count - 1)]
        ladderIndex += 1
        attempts.append(now)
        nextAllowed = now.addingTimeInterval(policy.backoff(afterAttempt: attempts.count))
        return .heal(step, reason: eval.reason)
    }

    /// After a recovery step: success clears the bad streak (the next fault starts the ladder from the bottom).
    public mutating func recordOutcome(success: Bool) {
        if success {
            consecutiveBad = 0
            ladderIndex = 0
        }
    }

    /// Manual reset of the circuit breaker (`emuu heal`, `farm gc`).
    public mutating func resetBreaker() {
        failed = false
        attempts = []
        nextAllowed = nil
        ladderIndex = 0
        consecutiveBad = 0
    }
}

/// One line of the bounded health history (`logs/health-<id>.jsonl`), shown by `emuu health --history`.
public struct HealthHistoryEntry: Codable, Sendable, Hashable {
    public var at: Date
    /// check, detect, heal, recovered, heal-failed, give-up
    public var kind: String
    public var verdict: HealthVerdict?
    public var reason: String
    public var step: HealStep?
    public var millis: Int?

    public init(at: Date, kind: String, verdict: HealthVerdict? = nil, reason: String, step: HealStep? = nil, millis: Int? = nil) {
        self.at = at
        self.kind = kind
        self.verdict = verdict
        self.reason = reason
        self.step = step
        self.millis = millis
    }
}

public struct HealthHistory: Sendable {
    public let url: URL
    public static let limit = 200

    public init(paths: EmuuPaths, instance: String) {
        url = paths.logsDirectory.appendingPathComponent("health-\(instance).jsonl")
    }

    public func append(_ entry: HealthHistoryEntry) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        guard let line = try? enc.encode(entry) else { return }
        var lines = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        lines.append(String(decoding: line, as: UTF8.self))
        if lines.count > Self.limit { lines.removeFirst(lines.count - Self.limit) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
    }

    public func entries() -> [HealthHistoryEntry] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
            try? dec.decode(HealthHistoryEntry.self, from: Data($0.utf8))
        }
    }
}
