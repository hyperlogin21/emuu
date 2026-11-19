import Foundation

/// Outcome of a guest-memory reclaim request (governor tier T3).
public enum ReclaimOutcome: Sendable, Hashable {
    /// Memory was returned to the host. `bytes` is the measured or engine-reported amount, if known.
    case reclaimed(bytes: UInt64?, detail: String)
    /// This engine/guest has no working mechanism; `reason` says what was checked.
    case unsupported(reason: String)
}

/// How to stop an engine.
public enum EngineStopMode: Sendable, Hashable {
    /// Ask the engine to exit cleanly (console `kill`), optionally saving the quick-boot snapshot.
    case graceful(saveQuickBoot: Bool)
    /// SIGKILL the engine process. Last resort; risks userdata corruption.
    case force
}

/// Control surface of one running (or stopped) engine instance. Implemented by `EmuuEngine`;
/// consumed by `EmuuMemory` effectors (T3–T5), the CLI and the app.
///
/// All methods are safe to call from any task. Implementations must be idempotent where noted and
/// must throw `EmuuError.invalidStateTransition` for impossible requests (e.g. `freeze` while stopped).
public protocol EngineControl: Sendable {
    var instanceID: InstanceID { get }

    /// Current lifecycle state.
    func state() async -> InstanceState

    /// Host pid of the process whose memory is the guest (the QEMU process), when running.
    /// This is the pid to sample with `proc_pid_rusage` and to signal for freeze, if signals are used.
    func enginePID() async -> Int32?

    /// adb serial of the running instance, when running.
    func serial() async -> DeviceSerial?

    /// T4: pause guest execution. Idempotent (no-op when already frozen). State becomes `.frozen`.
    func freeze() async throws
    /// Undo `freeze`. Idempotent. State becomes `.running`.
    func thaw() async throws

    /// Save a named snapshot of the running instance.
    func saveSnapshot(named name: String) async throws
    /// Load a named snapshot into the running instance.
    func loadSnapshot(named name: String) async throws
    /// Names of snapshots that exist for this instance.
    func listSnapshots() async throws -> [String]

    /// T3: return guest memory to the host. Must report `.unsupported` (not throw) when no mechanism exists.
    func reclaimGuestMemory(targetBytes: UInt64?) async throws -> ReclaimOutcome

    /// T5: save state and quit so the next `resume` restores it quickly. State: `.hibernating` → `.hibernated`.
    func hibernate() async throws
    /// Start again from the hibernation state (or a normal start if none). State ends `.running`.
    func resume() async throws

    /// Stop the engine. Idempotent when already stopped.
    func stop(_ mode: EngineStopMode) async throws
}
