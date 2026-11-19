import Foundation
import Testing
import EmuuBase
@testable import EmuuFarm

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func facts(_ change: (inout HealthFacts) -> Void = { _ in }) -> HealthFacts {
    var f = HealthFacts(engineAlive: true)
    f.consoleOK = true
    f.adbState = "device"
    f.shellOK = true
    f.bootCompleted = true
    f.frameworkOK = true
    f.bootID = "b-1"
    f.expectedBootID = "b-1"
    f.dataFreeBytes = 2 << 30
    change(&f)
    return f
}

@Suite struct HealthEvaluatorTests {
    @Test func healthy() {
        #expect(HealthEvaluator.evaluate(facts()).verdict == .healthy)
    }

    @Test func layeredFaults() {
        #expect(HealthEvaluator.evaluate(facts { $0.engineAlive = false }).fault == .engineDead)
        #expect(HealthEvaluator.evaluate(facts { $0.engineAlive = false }).verdict == .dead)
        let stopped = HealthEvaluator.evaluate(facts { $0.engineStopped = true })
        #expect(stopped.verdict == .hung && stopped.fault == .engineStoppedExternally)
        let frozen = HealthEvaluator.evaluate(facts { $0.engineStopped = true; $0.frozenByEmuu = true })
        #expect(frozen.verdict == .frozen && frozen.fault == nil)
        #expect(HealthEvaluator.evaluate(facts { $0.consoleOK = false; $0.shellOK = false }).fault == .consoleUnresponsive)
        // console alone failing while adb works: not a hang
        #expect(HealthEvaluator.evaluate(facts { $0.consoleOK = false }).verdict == .healthy)
        #expect(HealthEvaluator.evaluate(facts { $0.adbState = "offline" }).fault == .adbOffline)
        #expect(HealthEvaluator.evaluate(facts { $0.shellOK = false }).fault == .guestUnresponsive)
        #expect(HealthEvaluator.evaluate(facts { $0.frameworkOK = false }).fault == .frameworkUnresponsive)
        let rebooted = HealthEvaluator.evaluate(facts { $0.bootID = "b-2" })
        #expect(rebooted.verdict == .degraded && rebooted.fault == .guestRebooted)
        #expect(HealthEvaluator.evaluate(facts { $0.systemDialog = "Application Not Responding: x" }).fault == .systemDialog)
        #expect(HealthEvaluator.evaluate(facts { $0.dataFreeBytes = 10 << 20 }).fault == .dataFull)
    }

    @Test func bootGraceDowngradesNotYetBooted() {
        let booting = HealthEvaluator.evaluate(facts { $0.bootCompleted = false; $0.withinBootGrace = true })
        #expect(booting.verdict == .degraded && booting.fault == .notBooted)
        #expect(HealthEvaluator.evaluate(facts { $0.bootCompleted = false }).verdict == .hung)
        #expect(HealthEvaluator.evaluate(facts { $0.adbState = "offline"; $0.withinBootGrace = true }).verdict == .degraded)
    }
}

@Suite struct HealLadderTests {
    @Test func instanceLadders() {
        #expect(HealLadder.steps(for: .engineStoppedExternally, farmDevice: false) == [.thaw, .hardRestart, .coldBoot])
        #expect(HealLadder.steps(for: .adbOffline, farmDevice: false) == [.reconnectADB, .hardRestart, .coldBoot])
        #expect(HealLadder.steps(for: .frameworkUnresponsive, farmDevice: false) == [.softReboot, .hardRestart, .coldBoot])
        #expect(HealLadder.steps(for: .engineDead, farmDevice: false) == [.hardRestart, .coldBoot])
        // The user's own app / data: report only on interactive instances.
        #expect(HealLadder.steps(for: .systemDialog, farmDevice: false).isEmpty)
        #expect(HealLadder.steps(for: nil, farmDevice: false).isEmpty)
    }

    @Test func farmLaddersEndWithAFreshClone() {
        for fault in [HealthFault.engineDead, .engineStoppedExternally, .consoleUnresponsive, .adbOffline, .guestUnresponsive,
                      .frameworkUnresponsive, .notBooted, .guestRebooted, .systemDialog, .dataFull] {
            #expect(HealLadder.steps(for: fault, farmDevice: true).last == .replace, "\(fault)")
        }
        #expect(HealLadder.steps(for: .guestUnresponsive, farmDevice: true) == [.reset, .replace])
    }
}

@Suite struct SelfHealStateTests {
    let hung = HealthEvaluation(verdict: .hung, reason: "adb shell timeout", fault: .guestUnresponsive)
    let ok = HealthEvaluation(verdict: .healthy, reason: "ok", fault: nil)

    @Test func needsConfirmationThenEscalates() {
        var s = SelfHealState()
        let p = SelfHealPolicy()
        #expect(s.observe(hung, farmDevice: false, now: t0, policy: p) == .none)
        #expect(s.observe(hung, farmDevice: false, now: t0.addingTimeInterval(20), policy: p) == .heal(.hardRestart, reason: "adb shell timeout"))
        s.recordOutcome(success: false)
        // backoff: the next attempt is not before base (20 s) after the first
        #expect(s.observe(hung, farmDevice: false, now: t0.addingTimeInterval(30), policy: p) == .none)
        #expect(s.observe(hung, farmDevice: false, now: t0.addingTimeInterval(45), policy: p) == .heal(.coldBoot, reason: "adb shell timeout"))
    }

    @Test func deadActsImmediately() {
        var s = SelfHealState()
        let dead = HealthEvaluation(verdict: .dead, reason: "gone", fault: .engineDead)
        #expect(s.observe(dead, farmDevice: true, now: t0, policy: SelfHealPolicy()) == .heal(.replace, reason: "gone"))
    }

    @Test func successResetsLadderAndHealthyClearsStreak() {
        var s = SelfHealState()
        let p = SelfHealPolicy()
        _ = s.observe(hung, farmDevice: false, now: t0, policy: p)
        _ = s.observe(hung, farmDevice: false, now: t0.addingTimeInterval(20), policy: p)
        s.recordOutcome(success: true)
        #expect(s.observe(ok, farmDevice: false, now: t0.addingTimeInterval(40), policy: p) == .none)
        #expect(s.consecutiveBad == 0 && s.ladderIndex == 0)
        // A later hang starts from the bottom of the ladder again (after its own confirmation and the backoff).
        _ = s.observe(hung, farmDevice: false, now: t0.addingTimeInterval(100), policy: p)
        #expect(s.observe(hung, farmDevice: false, now: t0.addingTimeInterval(120), policy: p) == .heal(.hardRestart, reason: "adb shell timeout"))
    }

    @Test func circuitBreakerOpensAfterMaxAttempts() {
        var s = SelfHealState()
        var p = SelfHealPolicy()
        p.confirmations = 1
        p.backoffBase = 1
        var t = t0
        var heals = 0
        for _ in 0..<10 {
            switch s.observe(hung, farmDevice: true, now: t, policy: p) {
            case .heal: heals += 1; s.recordOutcome(success: false)
            case .giveUp: break
            case .none: break
            }
            t = t.addingTimeInterval(60)
        }
        #expect(heals == p.maxAttempts)
        #expect(s.failed)
        #expect(s.observe(hung, farmDevice: true, now: t, policy: p) == .none)
        s.resetBreaker()
        #expect(!s.failed)
        #expect(s.observe(hung, farmDevice: true, now: t, policy: p) == .heal(.reset, reason: "adb shell timeout"))
    }

    @Test func attemptsOutsideTheWindowDoNotCount() {
        var s = SelfHealState()
        var p = SelfHealPolicy()
        p.confirmations = 1
        p.backoffBase = 1
        p.window = 600
        var t = t0
        for _ in 0..<6 { // one attempt every 20 min: never 3 within 10 min
            if case .heal = s.observe(hung, farmDevice: true, now: t, policy: p) { s.recordOutcome(success: true) }
            t = t.addingTimeInterval(1200)
        }
        #expect(!s.failed)
    }

    @Test func backoffDoublesAndCaps() {
        let p = SelfHealPolicy()
        #expect(p.backoff(afterAttempt: 1) == 20)
        #expect(p.backoff(afterAttempt: 2) == 40)
        #expect(p.backoff(afterAttempt: 10) == p.backoffMax)
    }

    @Test func noFalsePositiveWhileBooting() {
        var s = SelfHealState()
        let booting = HealthEvaluation(verdict: .degraded, reason: "booting", fault: .notBooted)
        for i in 0..<5 { #expect(s.observe(booting, farmDevice: false, now: t0.addingTimeInterval(Double(i) * 20), policy: SelfHealPolicy()) == .none) }
    }
}

@Suite struct ProberParsingTests {
    @Test func shellFacts() {
        let lines = ["emuu-ok", "1", "f448fa99-f59f-4c8a-9c9e-8f24211e78e0", "141.22",
                     "/dev/block/dm-48   5944596 1219004 4709208  21% /data"]
        let f = HealthProber.parseShellFacts(lines)
        #expect(f.bootCompleted)
        #expect(f.bootID == "f448fa99-f59f-4c8a-9c9e-8f24211e78e0")
        #expect(f.uptime == 141.22)
        #expect(f.dataFree == 4709208 * 1024)
        #expect(!HealthProber.parseShellFacts(["emuu-ok", ""]).bootCompleted)
        #expect(!HealthProber.parseShellFacts([]).bootCompleted)
    }

    @Test func adbState() {
        #expect(HealthProber.parseADBState(stdout: "device\n", stderr: "") == "device")
        #expect(HealthProber.parseADBState(stdout: "", stderr: "error: device 'emulator-5554' not found") == "missing")
        #expect(HealthProber.parseADBState(stdout: "", stderr: "error: device offline") == "offline")
        #expect(HealthProber.parseADBState(stdout: "", stderr: "error: device unauthorized.") == "unauthorized")
    }

    @Test func systemDialogInFocus() {
        let anr = "  mCurrentFocus=Window{1a2b u0 Application Not Responding: com.example}\n  mFocusedApp=ActivityRecord{…}"
        #expect(HealthProber.systemDialog(inFocus: anr) == "Application Not Responding: com.example")
        #expect(HealthProber.systemDialog(inFocus: "  mCurrentFocus=Window{1 u0 com.android.settings/.Settings}") == nil)
    }
}
