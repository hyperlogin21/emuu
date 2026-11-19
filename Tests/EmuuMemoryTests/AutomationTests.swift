import Foundation
import Testing
import EmuuBase
import EmuuTestSupport
@testable import EmuuMemory

@Suite struct AutomationPolicyTests {
    private func automation(_ profile: MemoryProfile) -> GovernorConfig {
        var c = GovernorConfig.preset(profile)
        c.automationMode = true
        return c
    }

    @Test func hiddenIdleInstanceIsFrozenWithoutAutomation() {
        var d = PolicyDriver(.preset(.frugal))
        for i in 0..<40 { d.step(i * 30, guest: guest(available: 0.5), visible: false) }
        #expect(d.actions.contains(.freeze))
    }

    @Test func automationNeverFreezesOrHibernates() {
        for profile in MemoryProfile.allCases {
            var d = PolicyDriver(automation(profile))
            // 10 hours hidden and idle, with heavy pressure and host-critical moments.
            for i in 0..<1200 {
                let crit = i % 50 == 0
                d.step(i * 30, guest: guest(available: i % 3 == 0 ? 0.05 : 0.15), host: host(pressure: crit ? .critical : .normal),
                       visible: false)
            }
            #expect(!d.actions.contains(.freeze), "\(profile)")
            #expect(!d.actions.contains(.hibernate), "\(profile)")
            #expect(d.state == .running)
            // It still trims/kills background apps.
            #expect(d.actions.contains { $0.tier == .trim }, "\(profile)")
        }
    }

    @Test func automationCapsPressureTiersAtKillBackground() {
        var d = PolicyDriver(automation(.balanced))
        for i in 0..<200 { d.step(i * 10, guest: guest(available: 0.03), visible: false) }
        #expect(d.actions.contains { $0.tier == .killBackground })
        #expect(!d.actions.contains { $0.tier == .reclaim })
        #expect(d.actions.allSatisfy { $0.tier <= .killBackground })
    }

    @Test func automationLeavesAManualFreezeAloneButNeverHibernatesIt() {
        var d = PolicyDriver(automation(.frugal))
        d.state = .frozen
        for i in 0..<400 { d.step(i * 30, guest: nil, host: host(pressure: i == 200 ? .critical : .normal), visible: false) }
        #expect(!d.actions.contains(.hibernate))
        // Showing the window still thaws it.
        d.step(400 * 30, guest: nil, visible: true)
        #expect(d.actions.last == .thaw)
    }

    @Test func togglingAutomationAtRuntime() {
        var d = PolicyDriver(automation(.frugal))
        for i in 0..<20 { d.step(i * 30, guest: guest(available: 0.5), visible: false) }
        #expect(!d.actions.contains(.freeze))
        var c = d.policy.config
        c.automationMode = false
        d.policy.updateConfig(c)
        for i in 20..<40 { d.step(i * 30, guest: guest(available: 0.5), visible: false) }
        #expect(d.actions.contains(.freeze))
    }
}

@Suite struct ADBActivityDetectorTests {
    @Test func shellSessionsCountImmediately() {
        var det = ADBActivityDetector()
        let r1 = det.update(shellSessions: 1, lastPID: nil, at: .seconds(0)); #expect(r1)
        let r2 = det.update(shellSessions: 0, lastPID: nil, at: .seconds(30)); #expect(!r2)
    }

    @Test func pidRateDetectsCommandBursts() {
        var det = ADBActivityDetector(pidRateThreshold: 60)
        let r3 = det.update(shellSessions: 0, lastPID: 7554, at: .seconds(0)); #expect(!r3)
        // Idle: 8 pids in 30 s (16/min).
        let r4 = det.update(shellSessions: 0, lastPID: 7562, at: .seconds(30)); #expect(!r4)
        // Ten `adb shell input tap` between samples: +52 pids in 30 s (104/min).
        let r5 = det.update(shellSessions: 0, lastPID: 7614, at: .seconds(60)); #expect(r5)
        // Wrap-around / reboot resets instead of reporting.
        let r6 = det.update(shellSessions: 0, lastPID: 300, at: .seconds(90)); #expect(!r6)
        // The sampler's own forks are subtracted: 10 s sampling (4 pids each) on an idle guest is not activity.
        var fast = ADBActivityDetector()
        var pid = 1000
        for i in 0..<12 {
            pid += 4 + 2                       // own sample + 12/min background
            let r = fast.update(shellSessions: 0, lastPID: pid, at: .seconds(10 * (i + 1)))
            #expect(!r)
        }
        // After the governor's own trim (17 `cmd` processes) the baseline is reset.
        fast.rebaseline()
        let afterOwnAction = fast.update(shellSessions: 0, lastPID: pid + 40, at: .seconds(200))
        #expect(!afterOwnAction)
        // Too-short intervals are ignored.
        let r7 = det.update(shellSessions: 0, lastPID: 340, at: .seconds(91)); #expect(!r7)
    }

    @Test func governorTreatsADBActivityAsInteraction() async throws {
        // Frugal freezes after 2 min hidden+idle. Other tools keep running adb shells → no freeze.
        let clock = FakeClock()
        let engine = FakeEngineControl(instanceID: testID, state: .running)
        let activity = FakeActivity(visible: false)
        let sessions = Locked(1)
        let sampler = ScriptedGuestSampler {
            var s = GuestSnapshot(memory: guest(available: 0.5))
            s.adbShellSessions = sessions.current
            return s
        }
        let gov = MemoryGovernor(instanceID: testID, config: .preset(.frugal), engine: engine, guestSampler: sampler,
                                 hostSampler: ScriptedHostSampler { _ in hostSnapshot(footprint: gib) },
                                 effector: EffectorRouter([EngineEffector(engine: engine)]), maintenance: nil, activity: activity, clock: clock)
        for _ in 0..<20 {
            await gov.tick()
            clock.advance(by: .seconds(30))
        }
        #expect(await engine.state() == .running)
        #expect(await gov.status().lastADBActivity != nil)
        sessions.set(0)
        for _ in 0..<20 {
            await gov.tick()
            clock.advance(by: .seconds(30))
        }
        // Once adb goes quiet the frugal timers apply again: freeze after 2 min idle (then hibernate).
        let events = await gov.recentEvents().map { "\($0.kind)" }
        #expect(events.contains { $0.hasPrefix("actionApplied(freeze") })
        #expect(await engine.state() != .running)
    }
}

@Suite struct InstrumentationProbeTests {
    static let dumpsys = """
      Active instrumentation:
        Instrumentation #0:
          ActiveInstrumentation{8d1f2a io.appium.uiautomator2.server.test/androidx.test.runner.AndroidJUnitRunner}
          mClass=androidx.test.runner.AndroidJUnitRunner mFinished=false
          mRunningProcesses:
            #0: ProcessRecord{3c4b5d 4321:io.appium.uiautomator2.server/u0a190}
          mTargetInfo:
            name=io.appium.uiautomator2.server.ServerInstrumentation packageName=io.appium.uiautomator2.server
          mArguments:
            Bundle[{disableAnalytics=true}]
      Process LRU list (sorted by oom_adj, 80 total, non-act at 2, non-svc at 2):
        PERS #79: sys   F/ /PER  LCM  t: 0 3596:system/1000 (fixed)
    """

    @Test func parsesActiveInstrumentationSection() {
        let pkgs = InstrumentationProbe.activeInstrumentationPackages(Self.dumpsys)
        #expect(pkgs == ["io.appium.uiautomator2.server.test", "io.appium.uiautomator2.server"])
    }

    @Test func parsesInstrumentClientsAndTargets() {
        let output = """
        @@dumpsys
        @@ps
        app_process /system/bin com.android.commands.am.Am instrument -w -r -e debug false com.example.test/androidx.test.runner.AndroidJUnitRunner
        cmd activity instrument -w dev.mobile.maestro.test/androidx.test.runner.AndroidJUnitRunner
        @@list
        instrumentation:com.example.test/androidx.test.runner.AndroidJUnitRunner (target=com.example)
        instrumentation:dev.mobile.maestro.test/androidx.test.runner.AndroidJUnitRunner (target=dev.mobile.maestro)
        instrumentation:other.idle.test/x.Runner (target=other.idle)
        @@end
        """
        let pkgs = InstrumentationProbe.packages(fromProbeOutput: output)
        #expect(pkgs == ["com.example.test", "com.example", "dev.mobile.maestro.test", "dev.mobile.maestro"])
    }

    @Test func noInstrumentationGivesEmptySet() {
        #expect(InstrumentationProbe.packages(fromProbeOutput: "@@dumpsys\n@@ps\n@@list\n@@end\n").isEmpty)
    }

    @Test func effectorNeverTrimsOrKillsInstrumentedPackages() async throws {
        let shell = FakeDeviceShell(serial: DeviceSerial(rawValue: "emulator-5554"))
        shell.onShell(prefix: "cmd activity help", reply: .ok("Activity manager (activity) commands:\n  send-trim-memory\n  kill [--user]\n  compact\n"))
        shell.onShell(prefix: "cmd package help", reply: .ok("  trim-caches DESIRED\n"))
        shell.onShell(prefix: "echo @@dumpsys", reply: .ok("@@dumpsys\n" + Self.dumpsys + "\n@@ps\n@@list\n@@end\n"))
        shell.onShell(prefix: "for d in /proc", reply: .ok("""
        0 com.example.foreground
        950 io.appium.uiautomator2.server
        950 com.example.cached
        950 io.appium.uiautomator2.server.test
        """))
        shell.onShell(where: { $0.contains("send-trim-memory") || $0.contains("cmd activity kill") }, reply: .ok("avail 100\n@@run\n@@done\navail 200\n"))
        let effector = GuestEffector(shell: shell)
        _ = try await effector.killBackground(packages: [])
        _ = try await effector.trim(level: .moderate, packages: [])
        let acted = shell.shellCommands.filter { $0.contains("send-trim-memory") || $0.contains("cmd activity kill") }
        #expect(acted.count == 2)
        for cmd in acted {
            #expect(cmd.contains("com.example.cached"))
            #expect(!cmd.contains("uiautomator2"))
            #expect(!cmd.contains("com.example.foreground"))
        }
    }
}

@Suite struct ADBProbeAndMeminfoParserTests {
    @Test func parsesProbeLine() {
        let p = GuestParsers.adbProbe("adbd 2 7554\n")
        #expect(p?.children == 2)
        #expect(p?.lastPID == 7554)
        let snap = try? GuestSampler.parse("@@meminfo\nMemTotal: 2000000 kB\nMemFree: 100 kB\nMemAvailable: 1000000 kB\n@@adb\nadbd 3 900\n@@end\n")
        #expect(snap?.adbShellSessions == 2)
        #expect(snap?.lastPID == 900)
        #expect(GuestSampler.combinedCommand.contains("@@adb"))
        // adbd's long-lived `abb` helper (left behind by `adb install`) must not count as a session.
        #expect(GuestSampler.adbProbeScript.contains("*'(abb)'*) continue"))
    }

    @Test func meminfoCompactKeepsOneRowPerPID() {
        let text = """
        version,1
        oom,sys,275732,N/A
        proc,sys,system,3596,275996,N/A,e
        proc,servicea,com.android.settings,5456,87568,N/A,e
        cat,Native,228816,N/A
        oom,sys,190000,N/A
        proc,sys,system,3596,190539,N/A,e
        proc,servicea,com.android.settings,5456,25404,N/A,e
        """
        let rows = GuestParsers.dumpsysMeminfoCompact(text)
        #expect(rows.count == 2)
        #expect(rows.first { $0.packageName == "system" }?.pssBytes == 190539 * 1024)
        #expect(rows.first { $0.packageName == "com.android.settings" }?.pssBytes == 25404 * 1024)
    }
}
