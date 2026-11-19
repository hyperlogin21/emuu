import Foundation

/// Carries out governor actions. `EmuuMemory` provides concrete effectors (guest-side via
/// `DeviceShell`, engine-side via `EngineControl`); the policy only produces `GovernorAction`s.
public protocol MemoryEffector: Sendable {
    /// Whether this effector handles the action at all (independent of runtime success).
    func handles(_ action: GovernorAction) -> Bool
    /// Applies the action. Returns `.unsupported` when the mechanism is unavailable; throws on
    /// infrastructure errors (device offline, engine gone).
    func apply(_ action: GovernorAction) async throws -> EffectorOutcome
}

/// Receives governor events (UI, logs, history). Must be cheap and non-blocking.
public protocol GovernorEventSink: Sendable {
    func record(_ event: GovernorEvent)
}

/// Hooks other modules can use to participate in governor decisions without depending on EmuuMemory.
/// E.g. the display layer reports visibility; the app reports user activity.
public protocol GovernorActivitySource: Sendable {
    /// Whether the instance's window is currently visible on screen.
    func isDisplayVisible(_ id: InstanceID) async -> Bool
    /// Monotonic time (`EmuuClock.monotonicNow()`) of the last user input to the instance, if any.
    func lastUserInteraction(_ id: InstanceID) async -> Duration?
}

/// Fans one event out to several sinks.
public struct CompositeEventSink: GovernorEventSink {
    public let sinks: [any GovernorEventSink]
    public init(_ sinks: [any GovernorEventSink]) { self.sinks = sinks }
    public func record(_ event: GovernorEvent) { sinks.forEach { $0.record(event) } }
}

/// Keeps the most recent N events in memory (bounded, for long sessions).
public final class RingBufferEventSink: GovernorEventSink, @unchecked Sendable {
    public let capacity: Int
    private let storage: Locked<[GovernorEvent]>

    public init(capacity: Int = 500) {
        self.capacity = max(1, capacity)
        self.storage = Locked([])
    }

    public func record(_ event: GovernorEvent) {
        storage.withLock { buf in
            buf.append(event)
            if buf.count > capacity { buf.removeFirst(buf.count - capacity) }
        }
    }

    public var events: [GovernorEvent] { storage.current }
}
