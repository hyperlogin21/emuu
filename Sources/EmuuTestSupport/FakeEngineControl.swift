import Foundation
import EmuuBase

/// In-memory `EngineControl` that models the state machine and records calls.
/// Inject failures with `failNext(_:with:)`; set the T3 behaviour with `reclaimOutcome`.
public final class FakeEngineControl: EngineControl, @unchecked Sendable {
    public enum Method: String, Sendable, Hashable, CaseIterable {
        case freeze, thaw, saveSnapshot, loadSnapshot, listSnapshots, reclaim, hibernate, resume, stop
    }

    private struct State {
        var state: InstanceState
        var pid: Int32?
        var serial: DeviceSerial?
        var snapshots: [String] = []
        var calls: [String] = []
        var failures: [Method: EmuuError] = [:]
        var reclaimOutcome: ReclaimOutcome = .unsupported(reason: "fake: not configured")
    }

    public let instanceID: InstanceID
    private let s: Locked<State>

    public init(instanceID: InstanceID, state: InstanceState = .running, pid: Int32? = 4242, serial: DeviceSerial? = .emulator(consolePort: 5554)) {
        self.instanceID = instanceID
        self.s = Locked(State(state: state, pid: state.isRunningEngine ? pid : nil, serial: state.isRunningEngine ? serial : nil))
    }

    /// Human-readable call log, e.g. `["freeze", "saveSnapshot(x)", "stop(graceful)"]`.
    public var calls: [String] { s.withLock { $0.calls } }
    public var snapshots: [String] { s.withLock { $0.snapshots } }

    public var reclaimOutcome: ReclaimOutcome {
        get { s.withLock { $0.reclaimOutcome } }
        set { s.withLock { $0.reclaimOutcome = newValue } }
    }

    public func setState(_ newState: InstanceState) { s.withLock { $0.state = newState } }

    /// The next call of `method` throws `error` (once).
    public func failNext(_ method: Method, with error: EmuuError) { s.withLock { $0.failures[method] = error } }

    private func begin(_ method: Method, _ label: String) throws {
        let failure: EmuuError? = s.withLock { st in
            st.calls.append(label)
            return st.failures.removeValue(forKey: method)
        }
        if let failure { throw failure }
    }

    private func requireState(_ allowed: (InstanceState) -> Bool, action: String) throws {
        let current = s.withLock { $0.state }
        if !allowed(current) { throw EmuuError.invalidStateTransition(from: current, action: action) }
    }

    public func state() async -> InstanceState { s.withLock { $0.state } }
    public func enginePID() async -> Int32? { s.withLock { $0.pid } }
    public func serial() async -> DeviceSerial? { s.withLock { $0.serial } }

    public func freeze() async throws {
        try begin(.freeze, "freeze")
        try requireState({ $0 == .running || $0 == .frozen }, action: "freeze")
        setState(.frozen)
    }

    public func thaw() async throws {
        try begin(.thaw, "thaw")
        try requireState({ $0 == .running || $0 == .frozen }, action: "thaw")
        setState(.running)
    }

    public func saveSnapshot(named name: String) async throws {
        try begin(.saveSnapshot, "saveSnapshot(\(name))")
        try requireState({ $0 == .running }, action: "save snapshot")
        s.withLock { if !$0.snapshots.contains(name) { $0.snapshots.append(name) } }
    }

    public func loadSnapshot(named name: String) async throws {
        try begin(.loadSnapshot, "loadSnapshot(\(name))")
        try requireState({ $0 == .running }, action: "load snapshot")
        guard s.withLock({ $0.snapshots.contains(name) }) else { throw EmuuError.engine("snapshot '\(name)' not found") }
    }

    public func listSnapshots() async throws -> [String] {
        try begin(.listSnapshots, "listSnapshots")
        return snapshots
    }

    public func reclaimGuestMemory(targetBytes: UInt64?) async throws -> ReclaimOutcome {
        try begin(.reclaim, "reclaim(\(targetBytes.map(String.init) ?? "max"))")
        try requireState({ $0 == .running }, action: "reclaim memory")
        return reclaimOutcome
    }

    public func hibernate() async throws {
        try begin(.hibernate, "hibernate")
        try requireState({ $0 == .running || $0 == .frozen }, action: "hibernate")
        s.withLock { st in
            st.state = .hibernated
            st.pid = nil
            st.serial = nil
        }
    }

    public func resume() async throws {
        try begin(.resume, "resume")
        s.withLock { st in
            st.state = .running
            st.pid = 4242
            st.serial = .emulator(consolePort: 5554)
        }
    }

    public func stop(_ mode: EngineStopMode) async throws {
        let label: String
        switch mode {
        case .graceful(let save): label = "stop(graceful\(save ? ",save" : ""))"
        case .force: label = "stop(force)"
        }
        try begin(.stop, label)
        s.withLock { st in
            st.state = .stopped
            st.pid = nil
            st.serial = nil
        }
    }
}
