import Foundation
import EmuuBase
import EmuuMemory

/// Request sent to a supervisor over its unix socket: one JSON object per line, one request per connection.
struct ControlRequest: Codable, Sendable, Hashable {
    enum Command: String, Codable, Sendable, Hashable, CaseIterable {
        /// Current `SupervisorStatus`.
        case status
        /// Thaw/resume if needed and record user activity (device commands call this first).
        case wake
        case freeze, thaw, hibernate, resume
        /// Stop the engine (quick-boot snapshot saved unless `save == false`) and end the supervisor.
        case stop
        /// Leave the engine running and end the supervisor.
        case detach
        /// Manual T1 (and T2 with `kill`).
        case trim
        /// Manual T3 (engine reclaim) plus guest compaction.
        case reclaim
        /// Governor events after sequence number `since`.
        case events
        /// Display visibility hint from a front end (`visible`), so the governor can freeze/thaw.
        case visibility
        /// Record user activity without waking.
        case touch
        /// Turn automation mode on/off (`enabled`).
        case automation
    }

    var command: Command
    var save: Bool?
    var kill: Bool?
    var since: UInt64?
    var visible: Bool?
    /// `trim`: `am send-trim-memory` level name (default MODERATE).
    var level: TrimMemoryLevel?
    /// `trim`: also run `pm trim-caches` with this desired free storage.
    var cachesBytes: UInt64?
    /// `automation`: the new mode.
    var enabled: Bool?

    init(command: Command, save: Bool? = nil, kill: Bool? = nil, since: UInt64? = nil, visible: Bool? = nil,
         level: TrimMemoryLevel? = nil, cachesBytes: UInt64? = nil, enabled: Bool? = nil) {
        self.enabled = enabled
        self.command = command
        self.save = save
        self.kill = kill
        self.since = since
        self.visible = visible
        self.level = level
        self.cachesBytes = cachesBytes
    }
}

/// A governor event with the supervisor's sequence number (for incremental polling).
struct SequencedEvent: Codable, Sendable, Hashable {
    var seq: UInt64
    var event: GovernorEvent
}

/// Result of a manual tier command.
struct TierReport: Codable, Sendable, Hashable {
    var step: String
    var status: String
    var detail: String
    var reclaimedBytes: UInt64?

    init(step: String, outcome: EffectorOutcome) {
        self.step = step
        self.status = outcome.status.rawValue
        self.detail = outcome.detail
        self.reclaimedBytes = outcome.reclaimedBytes
    }

    init(step: String, error: String) {
        self.step = step
        self.status = "failed"
        self.detail = error
        self.reclaimedBytes = nil
    }
}

struct ControlReply: Codable, Sendable, Hashable {
    var ok: Bool
    var message: String?
    var status: SupervisorStatus?
    var events: [SequencedEvent]?
    var nextSeq: UInt64?
    var reports: [TierReport]?

    static func failure(_ message: String) -> ControlReply { ControlReply(ok: false, message: message) }
}

/// What a supervisor publishes in `run/<id>.supervisor.json` (and returns for `status`).
struct SupervisorStatus: Codable, Sendable, Hashable {
    struct Governor: Codable, Sendable, Hashable {
        var enabled: Bool
        var profile: String
        var level: String
        var tier: String
        var tierNumber: Int
        var disabledTiers: [String]
        var creepActive: Bool
        var samplesTaken: Int
        var actionsApplied: Int
        var actionsFailed: Int
        var maintenanceRuns: Int
        var consecutiveGuestSampleFailures: Int
        var freezeWhenHiddenAfterSeconds: Double?
        var hibernateWhenFrozenAfterSeconds: Double?
        /// Automation mode (never freeze/hibernate); optional for status files written by older builds.
        var automationMode: Bool?
        /// Seconds since adb activity from other tools was last seen, if ever.
        var adbActivitySecondsAgo: Double?
    }

    static let formatVersion = 1

    var formatVersion: Int = SupervisorStatus.formatVersion
    var instanceID: String
    var pid: Int32
    var mode: String
    var startedAt: Date
    var updatedAt: Date
    var socketPath: String
    var ownsEngine: Bool
    var visible: Bool
    var engineState: String
    var engineStateDetail: String
    var enginePID: Int32?
    var serial: String?
    var governor: Governor
    var lastSample: HistoryPoint?
    var lastEvent: String?
}
