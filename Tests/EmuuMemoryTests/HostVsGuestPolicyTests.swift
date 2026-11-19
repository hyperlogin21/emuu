import Foundation
import Testing
import EmuuBase
import EmuuTestSupport
@testable import EmuuMemory

/// Problem of 2026-11-18 (emuu-e2e, emuu.log 23:21–23:22 UTC): 30 s after a quick-boot resume the governor saw
/// "pressure high" — the *host's* macOS pressure, with the guest at 39 % MemAvailable — and ran T1 trim, then
/// T2 kill of 11 packages while the user was signing in to the Play Store. Host pressure must never cause
/// guest-side actions; guest actions wait out a grace period after boot/resume and never run over sign-in,
/// store or installer screens.
@Suite struct HostVsGuestPolicyTests {
    @Test func regressionHostPressureAfterResumeTriggersNoGuestActions() {
        var d = PolicyDriver(.preset(.balanced), grace: .minutes(3))
        // Replay: resume at 0; host high from 30 s on; guest healthy (39 % available); user signing in.
        for t in stride(from: 0, through: 600, by: 5) {
            d.step(t, guest: guest(available: 0.39), host: host(footprint: 4700 * mib, pressure: t >= 30 ? .high : .normal),
                   visible: true, interaction: t, foreground: ["com.google.android.gms"])
        }
        #expect(d.log.isEmpty)
        #expect(d.decisions.last?.level == .normal)
        #expect(d.decisions.last?.hostLevel == .high)
    }

    @Test func hostPressureNeverTrimsOrKillsEvenWithoutGrace() {
        var d = PolicyDriver(.preset(.frugal))
        for t in stride(from: 0, through: 3600, by: 10) {
            d.step(t, guest: guest(available: 0.6), host: host(footprint: 9 * gib, pressure: .critical), visible: true, interaction: t)
        }
        #expect(d.log.isEmpty)
    }

    @Test func hostPressureOnlyShortensFreezeOfHiddenIdleInstance() {
        // Balanced freezes after 5 min hidden+idle; under host pressure after 1 min.
        var d = PolicyDriver(.preset(.balanced))
        for t in stride(from: 0, through: 50, by: 10) { d.step(t, guest: guest(available: 0.5), host: host(pressure: .high), visible: false) }
        #expect(d.log.isEmpty)
        let f = d.step(60, guest: guest(available: 0.5), host: host(pressure: .high), visible: false)
        #expect(f.actions.map(\.action) == [.freeze])
        #expect(f.actions[0].reason.contains("host memory pressure"))
        // Frozen + host high → hibernate after 2 min.
        var at: Int?
        for t in stride(from: 70, through: 600, by: 10) {
            d.step(t, guest: nil, host: host(pressure: .high), visible: false)
            if d.actions.last == .hibernate { at = t; break }
        }
        #expect(at == 70 + 120)
    }

    @Test func hostPressureNeverFreezesVisibleOrActiveInstance() {
        var visible = PolicyDriver(.preset(.frugal))
        for t in stride(from: 0, through: 3600, by: 10) { visible.step(t, guest: guest(available: 0.5), host: host(pressure: .critical), visible: true) }
        #expect(visible.log.isEmpty)
        var active = PolicyDriver(.preset(.frugal))
        for t in stride(from: 0, through: 3600, by: 10) {
            active.step(t, guest: guest(available: 0.5), host: host(pressure: .critical), visible: false, interaction: t)
        }
        #expect(active.log.isEmpty)
    }

    @Test func automationModeNeverFreezesUnderHostPressure() {
        var cfg = GovernorConfig.preset(.frugal)
        cfg.automationMode = true
        var d = PolicyDriver(cfg)
        for t in stride(from: 0, through: 3600, by: 10) { d.step(t, guest: guest(available: 0.5), host: host(pressure: .critical), visible: false) }
        #expect(d.log.isEmpty)
    }

    @Test func guestPressureWaitsOutTheGracePeriodAfterBootAndResume() {
        var d = PolicyDriver(.preset(.balanced), grace: .minutes(3))
        for t in stride(from: 0, to: 180, by: 5) {
            let dec = d.step(t, guest: guest(available: 0.05), interaction: t)
            if t > 0 { #expect(dec.notes.contains { $0.contains("grace period") }) }
        }
        #expect(d.log.isEmpty)
        d.step(180, guest: guest(available: 0.05), interaction: 180)
        #expect(d.actions == [.trimMemory(level: .complete, packages: [])])
        // Hibernate → resume restarts the grace period.
        d.state = .hibernated
        d.step(400, guest: nil, visible: false)
        d.state = .running
        let before = d.log.count
        for t in stride(from: 410, to: 590, by: 5) { d.step(t, guest: guest(available: 0.05), interaction: t) }
        #expect(d.log.count == before)
        for t in stride(from: 590, through: 700, by: 5) { d.step(t, guest: guest(available: 0.05), interaction: t) }
        #expect(d.log.count > before)
    }

    @Test func noGuestActionsOverSignInStoreOrInstaller() {
        for fg in ["com.android.vending", "com.google.android.gms", "com.google.android.gms.ui", "com.google.android.packageinstaller",
                   "com.android.permissioncontroller"] {
            var d = PolicyDriver(.preset(.frugal))
            for t in stride(from: 0, through: 1800, by: 10) {
                d.step(t, guest: guest(available: 0.04), visible: true, interaction: t, foreground: [fg])
            }
            #expect(d.log.isEmpty, "acted while \(fg) was in the foreground")
        }
        // An ordinary app in front: guest pressure is handled.
        var d = PolicyDriver(.preset(.frugal))
        for t in stride(from: 0, through: 60, by: 10) { d.step(t, guest: guest(available: 0.04), visible: true, interaction: t, foreground: ["com.example.game"]) }
        #expect(!d.log.isEmpty)
        #expect(GovernorPolicy(config: .preset(.frugal)).isSensitiveForeground("com.google.android.gmsx") == false)
    }
}

/// Guest reboot detection (defensive diagnostics for the 2026-11-18 reboot): every sample reads the guest
/// kernel's boot id; a change is logged and emitted with the governor's last actions.
@Suite struct GuestRebootDetectionTests {
    @Test func parsesBootIDAndUptime() throws {
        let out = "@@meminfo\nMemTotal: 2017768 kB\nMemFree: 50000 kB\nMemAvailable: 800000 kB\nCached: 600000 kB\n@@boot\n0ee0afb6-c02a-483f-9725-f844e46f3676\n219.07 379.96\n@@end\n"
        let snap = try GuestSampler.parse(out)
        #expect(snap.bootID == "0ee0afb6-c02a-483f-9725-f844e46f3676")
        #expect(snap.uptimeSeconds == 219.07)
        #expect(GuestSampler.combinedCommand.contains("/proc/sys/kernel/random/boot_id"))
    }

    @Test func governorReportsRebootWithRecentActions() async throws {
        let clock = FakeClock()
        let boot = Locked("aaaaaaaa-0000-0000-0000-000000000001")
        let avail = Locked(0.05)
        var cfg = GovernorConfig.preset(.balanced)
        cfg.guestActionGraceAfterStart = .zero
        let g = MemoryGovernor(instanceID: testID, config: cfg, engine: FakeEngineControl(instanceID: testID),
                               guestSampler: ScriptedGuestSampler {
                                   var s = GuestSnapshot(memory: guest(available: avail.current), foregroundProcesses: ["com.example.app"])
                                   s.bootID = boot.current
                                   s.uptimeSeconds = 3
                                   return s
                               },
                               hostSampler: ScriptedHostSampler { _ in hostSnapshot(footprint: 4 * gib) },
                               effector: RecordingEffector(), maintenance: nil, activity: FakeActivity(), clock: clock)
        _ = await g.tick()                                  // critical → T1 trim (journal)
        avail.set(0.6)
        boot.set("aaaaaaaa-0000-0000-0000-000000000002")    // the guest restarted
        clock.advance(by: .seconds(30))
        _ = await g.tick()
        let reboots = await g.recentEvents().compactMap { e -> [String]? in
            if case .guestRebooted(_, let recent) = e.kind { return recent } else { return nil }
        }
        #expect(reboots.count == 1)
        #expect(reboots.first?.last?.contains("trimMemory") == true)
    }
}
