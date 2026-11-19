import EmuuBase

/// When an instance's window closes by itself (pure; unit-tested).
///
/// The window closes when the device is shut down or hibernated on purpose — from the window, the library, the
/// memory governor, the CLI (`emuu stop|hibernate`, `adb emu kill`), a CLI supervisor, or Android powering itself
/// off. It stays open for everything that brings the engine back or that the user should see: guest reboots,
/// engine restarts (`emuu reboot --hard|--cold`, self-healing, the app's own "Restart Engine"), freeze/thaw,
/// crashes and failed starts.
///
/// Telling a shutdown from a restart:
/// * A stop or hibernate run *in this process* (window, library, governor) passes through `.stopping` /
///   `.hibernating` in the session's own engine controller, so it is known to be intentional at once.
/// * When another process stops the engine (CLI, supervisor, `adb emu kill`, guest power-off), the session only
///   sees the engine vanish: up → `.stopped`/`.hibernated` with no transitional state. A restart looks the same
///   until the new engine appears (≈1 s after the old one exits), so such an exit is **confirmed** after
///   `confirmDelay`: the engine is looked up again, and the window only closes if no engine came back and a
///   live CLI supervisor does not report one on its way.
/// * Android powering itself off is reported by the engine controller as a crash: engine 36.4.9 saves its
///   snapshot, then hangs and kills itself (SIGKILL) after 20 s. Its log says so ("… seconds to shutdown
///   gracefully before kill"); such a "crash" is treated as an external stop (`engineLogShowsShutdown`).
enum WindowAutoClosePolicy {
    /// What the session does when its engine's state changes.
    enum Decision: Equatable {
        case keepOpen
        /// Close now (intentional stop/hibernate in this process).
        case close(reason: String)
        /// The engine went away from outside: close only if `confirm` still agrees after `confirmDelay`.
        case confirm
    }

    /// Outcome of a confirmation check.
    enum Confirmation: Equatable {
        case close(reason: String)
        /// An engine is up again (restart): keep the window and reconnect it.
        case engineBack
        /// A live CLI supervisor reports a transition (booting/stopping): look again shortly.
        case checkAgain
        case keepOpen
    }

    struct Context: Equatable {
        /// The session's pipeline was built at least once (phase reached `.ready`). Before that, a stop is a
        /// failed start and the window keeps showing it.
        var wasUp: Bool
        /// The window shows an error (crash, failed resume): keep it so the user sees what happened.
        var showsFailure: Bool
        /// This session is restarting or resuming the engine itself (Restart Engine, Retry, resume on show).
        var restartInProgress: Bool
        /// This window asked a CLI supervisor to hibernate/stop the engine (the exit then looks external).
        var exitRequestedHere: Bool
        /// The last "crash" was the engine shutting down (guest power-off; see `engineLogShowsShutdown`).
        var crashWasShutdown: Bool

        init(wasUp: Bool, showsFailure: Bool = false, restartInProgress: Bool = false, exitRequestedHere: Bool = false,
             crashWasShutdown: Bool = false) {
            self.wasUp = wasUp
            self.showsFailure = showsFailure
            self.restartInProgress = restartInProgress
            self.exitRequestedHere = exitRequestedHere
            self.crashWasShutdown = crashWasShutdown
        }
    }

    /// How long an exit seen from outside is given to turn out to be a restart.
    static let confirmDelay: Duration = .seconds(4)
    /// Interval and number of extra looks while a CLI supervisor reports a transition.
    static let recheckInterval: Duration = .seconds(2)
    static let maxRechecks = 30

    static func decide(previous: InstanceState, new: InstanceState, context: Context) -> Decision {
        let poweredOff = context.crashWasShutdown && isCrash(new)
        guard new == .stopped || new == .hibernated || poweredOff else { return .keepOpen }
        guard context.wasUp, !context.showsFailure, !context.restartInProgress else { return .keepOpen }
        if poweredOff { return .confirm }   // as for any engine that vanished: a supervisor may restart it
        switch previous {
        case .stopping, .hibernating:
            return .close(reason: reason(new))
        case .crashed:
            // `stop` on a crashed engine only clears the crash; the window keeps showing it (after a power-off
            // the close is already being confirmed).
            return .keepOpen
        case .running, .booting, .frozen, .stopped, .hibernated:
            // stopped ⇄ hibernated: the marker written by another process after its verified save.
            return context.exitRequestedHere ? .close(reason: reason(new)) : .confirm
        }
    }

    /// - Parameters:
    ///   - state: the engine state after looking for a live engine again (`EngineInstance.refresh()`).
    ///   - supervisorEngineState: the engine state a live CLI supervisor publishes (nil without one).
    static func confirm(state: InstanceState, supervisorEngineState: String?, context: Context) -> Confirmation {
        if context.restartInProgress || context.showsFailure { return .keepOpen }
        switch state {
        case .crashed:
            guard context.crashWasShutdown else { return .keepOpen }
            return .close(reason: "shut down")
        case .booting, .running, .frozen, .stopping, .hibernating: return .engineBack
        case .stopped, .hibernated: break
        }
        if let s = supervisorEngineState, ["booting", "running", "stopping", "hibernating", "frozen"].contains(s) {
            return .checkAgain
        }
        return .close(reason: reason(state))
    }

    /// Line engine 36.4.9 logs when it begins shutting down (guest power-off, console `kill`); a real crash does
    /// not log it.
    static let shutdownLogMarker = "to shutdown gracefully before kill"
    /// Header Emuu writes into the engine log at every launch (`EngineInstance.appendLogHeader`).
    static let launchLogHeader = "emuu launch "

    /// Whether the engine's log, since its last launch, shows that the engine was shutting down when it exited.
    static func engineLogShowsShutdown(_ logTail: String) -> Bool {
        let sinceLaunch = logTail.range(of: launchLogHeader, options: .backwards).map { logTail[$0.upperBound...] } ?? logTail[...]
        return sinceLaunch.contains(shutdownLogMarker)
    }

    static func isCrash(_ state: InstanceState) -> Bool {
        if case .crashed = state { return true }
        return false
    }

    static func reason(_ state: InstanceState) -> String {
        state == .hibernated ? "hibernated" : "shut down"
    }
}
