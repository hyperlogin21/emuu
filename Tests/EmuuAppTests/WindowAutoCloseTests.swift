import Testing
import EmuuBase
@testable import EmuuApp

@Suite struct WindowAutoClosePolicyTests {
    typealias P = WindowAutoClosePolicy
    let up = P.Context(wasUp: true)

    // MARK: Intentional stop / hibernate in this process → close at once

    @Test func hibernateByWindowOrGovernorCloses() {
        #expect(P.decide(previous: .hibernating, new: .hibernated, context: up) == .close(reason: "hibernated"))
    }

    @Test func shutDownInThisProcessCloses() {
        #expect(P.decide(previous: .stopping, new: .stopped, context: up) == .close(reason: "shut down"))
    }

    @Test func failedSaveParkedAsHibernatedStillCloses() {
        // hibernate() parks the instance as hibernated even when the save failed (memory released).
        #expect(P.decide(previous: .hibernating, new: .hibernated, context: up) == .close(reason: "hibernated"))
    }

    // MARK: Engine vanished (CLI, supervisor, adb emu kill, guest power-off) → confirm first

    @Test(arguments: [InstanceState.running, .booting, .frozen])
    func externalExitIsConfirmed(previous: InstanceState) {
        #expect(P.decide(previous: previous, new: .stopped, context: up) == .confirm)
        #expect(P.decide(previous: previous, new: .hibernated, context: up) == .confirm)
    }

    @Test func markerSettleAfterExternalStopIsConfirmed() {
        #expect(P.decide(previous: .stopped, new: .hibernated, context: up) == .confirm)
    }

    @Test func hibernateRequestedFromThisWindowViaSupervisorClosesAtOnce() {
        let ctx = P.Context(wasUp: true, exitRequestedHere: true)
        #expect(P.decide(previous: .running, new: .stopped, context: ctx) == .close(reason: "shut down"))
        #expect(P.decide(previous: .running, new: .hibernated, context: ctx) == .close(reason: "hibernated"))
    }

    // MARK: Android powering itself off (engine 36.4.9 reports it as a SIGKILL "crash")

    @Test func guestPowerOffIsConfirmedLikeAnExternalStop() {
        let ctx = P.Context(wasUp: true, crashWasShutdown: true)
        #expect(P.decide(previous: .running, new: .crashed(reason: "engine signal 9"), context: ctx) == .confirm)
        #expect(P.confirm(state: .crashed(reason: "engine signal 9"), supervisorEngineState: nil, context: ctx) == .close(reason: "shut down"))
        // A supervisor's self-heal restarts it: keep the window.
        #expect(P.confirm(state: .booting, supervisorEngineState: "booting", context: ctx) == .engineBack)
    }

    @Test func engineLogShutdownMarkerSinceLastLaunch() {
        let header = "emuu launch 2026-11-19T06:40:44Z: emulator -avd wc1 …\n"
        let poweredOff = header + """
            INFO         | Successfully loaded snapshot 'default_boot' using 1239 ms
            INFO         | Saving snapshot 'default_boot' using 3755 ms
            INFO         | Wait for emulator (pid 36513) 20 seconds to shutdown gracefully before kill;you can set environment variable ANDROID_EMULATOR_WAIT_TIME_BEFORE_KILL(in seconds) to change the default value (20 seconds)
            """
        #expect(P.engineLogShowsShutdown(poweredOff))
        // A real crash: no shutdown line since the last launch (an older run's line does not count).
        let crashed = poweredOff + "\n" + header + "INFO         | Successfully loaded snapshot 'default_boot'\nFATAL        | something broke\n"
        #expect(!P.engineLogShowsShutdown(crashed))
        #expect(!P.engineLogShowsShutdown(""))
    }

    @Test func realCrashIsNotTreatedAsPowerOff() {
        #expect(P.decide(previous: .running, new: .crashed(reason: "engine signal 11"), context: up) == .keepOpen)
        #expect(P.confirm(state: .crashed(reason: "x"), supervisorEngineState: nil, context: up) == .keepOpen)
    }

    // MARK: Never close

    @Test(arguments: [InstanceState.running, .booting, .frozen, .stopping, .hibernating])
    func nonTerminalStatesKeepTheWindow(new: InstanceState) {
        #expect(P.decide(previous: .running, new: new, context: up) == .keepOpen)
    }

    @Test func guestRebootKeepsTheWindow() {
        // Soft reboot / snapshot reset: the engine keeps running, Android goes back to booting.
        #expect(P.decide(previous: .running, new: .booting, context: up) == .keepOpen)
        #expect(P.decide(previous: .booting, new: .running, context: up) == .keepOpen)
    }

    @Test func freezeAndThawKeepTheWindow() {
        #expect(P.decide(previous: .running, new: .frozen, context: up) == .keepOpen)
        #expect(P.decide(previous: .frozen, new: .running, context: up) == .keepOpen)
    }

    @Test func crashKeepsTheWindow() {
        #expect(P.decide(previous: .running, new: .crashed(reason: "engine signaled(9)"), context: up) == .keepOpen)
        // A later stop only clears the crash; the error stays visible.
        #expect(P.decide(previous: .crashed(reason: "x"), new: .stopped, context: up) == .keepOpen)
        #expect(P.decide(previous: .running, new: .stopped, context: P.Context(wasUp: true, showsFailure: true)) == .keepOpen)
    }

    @Test func failedOrUnfinishedStartKeepsTheWindow() {
        let starting = P.Context(wasUp: false)
        #expect(P.decide(previous: .booting, new: .stopped, context: starting) == .keepOpen)
        #expect(P.decide(previous: .stopping, new: .stopped, context: starting) == .keepOpen)
        #expect(P.decide(previous: .hibernating, new: .hibernated, context: starting) == .keepOpen)
    }

    @Test func appRestartOrResumeKeepsTheWindow() {
        // "Restart Engine" hibernates and resumes; Retry / Cold Boot / resume-on-show run a resume task.
        let restarting = P.Context(wasUp: true, restartInProgress: true)
        #expect(P.decide(previous: .hibernating, new: .hibernated, context: restarting) == .keepOpen)
        #expect(P.decide(previous: .running, new: .stopped, context: restarting) == .keepOpen)
        #expect(P.decide(previous: .stopping, new: .stopped, context: restarting) == .keepOpen)
    }

    // MARK: Confirmation of an external exit

    @Test func confirmClosesWhenNoEngineCameBack() {
        #expect(P.confirm(state: .stopped, supervisorEngineState: nil, context: up) == .close(reason: "shut down"))
        #expect(P.confirm(state: .hibernated, supervisorEngineState: nil, context: up) == .close(reason: "hibernated"))
        #expect(P.confirm(state: .hibernated, supervisorEngineState: "hibernated", context: up) == .close(reason: "hibernated"))
        #expect(P.confirm(state: .stopped, supervisorEngineState: "stopped", context: up) == .close(reason: "shut down"))
    }

    @Test(arguments: [InstanceState.booting, .running, .frozen, .stopping, .hibernating])
    func restartElsewhereKeepsTheWindow(state: InstanceState) {
        // `emuu reboot --hard|--cold`, `emuu heal`, a supervisor's self-heal: a new engine is up.
        #expect(P.confirm(state: state, supervisorEngineState: nil, context: up) == .engineBack)
    }

    @Test func supervisorMidTransitionIsCheckedAgain() {
        for s in ["booting", "stopping", "hibernating", "running"] {
            #expect(P.confirm(state: .stopped, supervisorEngineState: s, context: up) == .checkAgain)
        }
    }

    @Test func confirmKeepsTheWindowForCrashesAndOwnRestarts() {
        #expect(P.confirm(state: .crashed(reason: "x"), supervisorEngineState: nil, context: up) == .keepOpen)
        #expect(P.confirm(state: .stopped, supervisorEngineState: nil, context: P.Context(wasUp: true, restartInProgress: true)) == .keepOpen)
        #expect(P.confirm(state: .stopped, supervisorEngineState: nil, context: P.Context(wasUp: true, showsFailure: true)) == .keepOpen)
    }
}
