import Foundation
import Testing
import EmuuBase
@testable import EmuuMemory

@Suite struct PolicyClassificationTests {
    let cfg = GovernorConfig.preset(.balanced)

    @Test func signalsMapToLevels() {
        func lvl(_ g: GuestMemory?, relaxed: Bool = false) -> MemoryPressureLevel {
            GovernorPolicy.classify(guest: g, config: cfg, relaxed: relaxed).0
        }
        func hostLvl(_ h: HostMemory?) -> MemoryPressureLevel { GovernorPolicy.classifyHost(h, config: cfg, relaxed: false).0 }
        #expect(lvl(guest(available: 0.5)) == .normal)
        #expect(lvl(guest(available: 0.20)) == .elevated)
        #expect(lvl(guest(available: 0.12)) == .high)
        #expect(lvl(guest(available: 0.05)) == .critical)
        #expect(lvl(guest(available: 0.5, psiSome10: 25)) == .high)
        #expect(lvl(guest(available: 0.5, psiSome10: 1, psiFull10: 20)) == .critical)
        // Host signals are a separate level (they never raise the guest level).
        #expect(hostLvl(host(pressure: .high)) == .high)
        // Footprint vs budget (2 × 3072 MiB + 1 GiB = 7168 MiB); capped at .elevated by default.
        #expect(hostLvl(host(footprint: 4400 * mib)) == .normal)
        #expect(hostLvl(host(footprint: 7600 * mib)) == .elevated)
        #expect(hostLvl(host(footprint: 11000 * mib)) == .elevated)
        var uncapped = cfg
        uncapped.thresholds.footprintMaxLevel = .critical
        #expect(GovernorPolicy.classifyHost(host(footprint: 11000 * mib), config: uncapped, relaxed: false).0 == .critical)
        // Hysteresis: 0.24 is normal on entry but still elevated when relaxed.
        #expect(lvl(guest(available: 0.24)) == .normal)
        #expect(lvl(guest(available: 0.24), relaxed: true) == .elevated)
    }

    @Test func presetsAreOrderedSensibly() {
        let f = GovernorConfig.preset(.frugal), b = GovernorConfig.preset(.balanced), p = GovernorConfig.preset(.performance)
        #expect(f.thresholds.availableElevated > b.thresholds.availableElevated)
        #expect(b.thresholds.availableElevated > p.thresholds.availableElevated)
        #expect(f.freezeWhenHiddenAfter! < b.freezeWhenHiddenAfter!)
        #expect(b.freezeWhenHiddenAfter! < p.freezeWhenHiddenAfter!)
        #expect(p.visibleTierCap == .trim)
        #expect(b.engineFootprintBudgetBytes == 7168 * mib)
        #expect(GovernorConfig.preset(.balanced, guestRAMMB: 2048).engineFootprintBudgetBytes == 5120 * mib)
    }
}

@Suite struct PolicyScenarioTests {
    @Test func steadyStateProducesNoActions() {
        var d = PolicyDriver(.preset(.balanced))
        for i in 0..<2000 { // ~16.6 h at 30 s, user active
            let dec = d.step(i * 30, guest: guest(available: 0.5), interaction: i * 30)
            #expect(dec.maintenance == nil)
        }
        #expect(d.log.isEmpty)
        #expect(d.policy.pressureTier == .none)
        #expect(d.decisions.last?.nextSampleIn == .seconds(30))
        #expect(d.decisions.allSatisfy { $0.tierChange == nil })
    }

    @Test func rampingPressureEscalatesOneTierAtATime() {
        var d = PolicyDriver(.preset(.balanced))
        d.step(0, guest: guest(available: 0.5), interaction: 0)
        d.step(10, guest: guest(available: 0.20), interaction: 10)       // elevated, unconfirmed
        #expect(d.log.isEmpty)
        let t1 = d.step(20, guest: guest(available: 0.20), interaction: 20) // confirmed → T1
        #expect(d.actions == [.trimMemory(level: .background, packages: [])])
        #expect(t1.tierChange?.to == .trim)
        #expect(t1.nextSampleIn == .seconds(10))
        d.step(30, guest: guest(available: 0.12), interaction: 30)
        d.step(40, guest: guest(available: 0.12), interaction: 40)       // high, but T1 not yet judged
        #expect(d.log.count == 1)
        d.step(60, guest: guest(available: 0.12), interaction: 60)       // 40 s < 45 s evaluation delay
        #expect(d.log.count == 1)
        let t2 = d.step(70, guest: guest(available: 0.12), interaction: 70) // T1 did not help → T2
        #expect(d.actions.last == .killBackground(packages: []))
        #expect(t2.tierChange?.from == .trim && t2.tierChange?.to == .killBackground)
        #expect(t2.nextSampleIn == .seconds(5))
        d.step(80, guest: guest(available: 0.05), interaction: 80)       // critical (immediate)
        #expect(d.log.count == 2)                                        // still judging T2
        d.step(95, guest: guest(available: 0.05), interaction: 95)       // 25 s ≥ 22.5 s (halved delay)
        #expect(d.actions.last == .reclaimGuestMemory(targetBytes: nil))
        #expect(d.times(of: .trim) == [20])
        #expect(d.times(of: .killBackground) == [70])
        #expect(d.times(of: .reclaim) == [95])
        // Never more than one tier per step.
        #expect(Set(d.log.map(\.t)).count == d.log.count)
    }

    @Test func helpedTrimSuppressesEscalationWhileStillHigh() {
        var cfg = GovernorConfig.preset(.balanced)
        cfg.escalationConfirmSamples = 1
        var d = PolicyDriver(cfg)
        d.step(0, guest: guest(available: 0.13))                         // high → T1 first
        #expect(d.actions == [.trimMemory(level: .moderate, packages: [])])
        // Still high (0.165 < 0.14+0.04 hold) but improved 3.5 points vs baseline 0.13 → no escalation.
        for t in stride(from: 10, through: 170, by: 10) { d.step(t, guest: guest(available: 0.165)) }
        #expect(d.log.count == 1)
        #expect(d.policy.level == .high)
        // T1 is repeated only after its 3 min cooldown.
        d.step(180, guest: guest(available: 0.165))
        #expect(d.actions == [.trimMemory(level: .moderate, packages: []), .trimMemory(level: .moderate, packages: [])])
    }

    @Test func noopEscalatesWithoutWaiting() {
        var cfg = GovernorConfig.preset(.balanced)
        cfg.escalationConfirmSamples = 1
        var d = PolicyDriver(cfg)
        d.step(0, guest: guest(available: 0.12)) { _ in .noop("nothing to trim") }
        d.step(5, guest: guest(available: 0.12))
        #expect(d.actions == [.trimMemory(level: .moderate, packages: []), .killBackground(packages: [])])
    }

    @Test func cooldownsSpaceRepeatedActions() {
        var d = PolicyDriver(.preset(.balanced))
        for t in stride(from: 0, through: 3600, by: 10) { d.step(t, guest: guest(available: 0.20)) }
        let trims = d.times(of: .trim)
        #expect(trims.count >= 15 && trims.count <= 20)
        for (a, b) in zip(trims, trims.dropFirst()) { #expect(b - a >= 180) }
        #expect(d.times(of: .killBackground).isEmpty) // elevated never needs T2
    }

    @Test func deescalatesAfterCalmPeriod() {
        var cfg = GovernorConfig.preset(.balanced)
        cfg.escalationConfirmSamples = 1
        var d = PolicyDriver(cfg)
        d.step(0, guest: guest(available: 0.12))
        d.step(50, guest: guest(available: 0.12))
        #expect(d.policy.pressureTier == .killBackground)
        d.step(60, guest: guest(available: 0.5))                           // calm starts
        #expect(d.policy.pressureTier == .killBackground)
        d.step(200, guest: guest(available: 0.5))
        #expect(d.policy.pressureTier == .killBackground)
        let dec = d.step(240, guest: guest(available: 0.5))                // 180 s calm
        #expect(d.policy.pressureTier == .none)
        #expect(dec.tierChange?.to == GovernorTier.none)
        #expect(dec.nextSampleIn == .seconds(30))
    }

    @Test func hysteresisAvoidsFlapping() {
        var cfg = GovernorConfig.preset(.balanced)
        cfg.escalationConfirmSamples = 1
        var d = PolicyDriver(cfg)
        // Oscillate around the 0.22 enter threshold, staying under the 0.26 exit threshold.
        for i in 0..<120 { d.step(i * 10, guest: guest(available: i % 2 == 0 ? 0.215 : 0.235)) }
        let changes = d.decisions.compactMap(\.tierChange)
        #expect(changes.count == 1)
        #expect(d.policy.level == .elevated)
    }

    @Test func unsupportedReclaimIsNeverRequestedAgain() {
        var cfg = GovernorConfig.preset(.balanced)
        cfg.escalationConfirmSamples = 1
        var d = PolicyDriver(cfg)
        let respond: (GovernorAction) -> EffectorOutcome = { a in
            a.tier == .reclaim ? .unsupported("no balloon") : .applied()
        }
        for t in stride(from: 0, through: 7200, by: 5) { d.step(t, guest: guest(available: 0.04), outcome: respond) }
        #expect(d.times(of: .reclaim).count == 1)
        #expect(d.policy.disabledTiers == [.reclaim])
        #expect(d.times(of: .killBackground).count > 2)
    }

    @Test func rateLimitPreventsActionStorms() {
        var cfg = GovernorConfig.preset(.balanced)
        cfg.escalationConfirmSamples = 1
        cfg.cooldowns = TierCooldowns(trim: .seconds(1), killBackground: .seconds(1), reclaim: .seconds(1), freeze: .seconds(1), hibernate: .seconds(1))
        cfg.evaluationDelay = .seconds(1)
        cfg.maxActionsPerHour = 5
        var d = PolicyDriver(cfg)
        var notes: [String] = []
        for t in stride(from: 0, through: 3599, by: 2) { notes += d.step(t, guest: guest(available: 0.04)).notes }
        #expect(d.log.count == 5)
        #expect(notes.contains { $0.contains("suppressed") })
        for t in stride(from: 3600, through: 7199, by: 2) { d.step(t, guest: guest(available: 0.04)) }
        #expect(d.log.count == 10)
    }

    @Test func gamingProfileOnlyTrimsWhileVisible() {
        var d = PolicyDriver(.preset(.performance))
        for t in stride(from: 0, through: 7200, by: 10) {
            d.step(t, guest: guest(available: 0.03), host: host(pressure: .critical), visible: true, interaction: t)
        }
        #expect(!d.log.isEmpty)
        #expect(d.actions.allSatisfy { if case .trimMemory = $0 { return true } else { return false } })
        #expect(d.state == .running)
        // Every trim targets background apps only (empty package list = background per effector contract).
        #expect(d.actions.allSatisfy { $0 == .trimMemory(level: .complete, packages: []) })
    }

    @Test func gamingProfileNeverFreezesWhileVisibleEvenWhenIdle() {
        var d = PolicyDriver(.preset(.performance))
        for t in stride(from: 0, through: 4 * 3600, by: 30) { d.step(t, guest: guest(available: 0.5), visible: true) }
        #expect(!d.actions.contains(.freeze))
        // Hidden: freezes after 15 min hidden + idle.
        for t in stride(from: 4 * 3600 + 30, through: 4 * 3600 + 1200, by: 30) { d.step(t, guest: guest(available: 0.5), visible: false) }
        #expect(d.actions.contains(.freeze))
        let freezeAt = d.log.first { $0.action == .freeze }!.t
        #expect(freezeAt >= 4 * 3600 + 30 + 900)
    }

    @Test func freezeThawLifecycle() {
        var d = PolicyDriver(.preset(.balanced))
        for t in stride(from: 0, to: 300, by: 30) { d.step(t, guest: guest(available: 0.5), visible: false) }
        #expect(d.log.isEmpty)                                            // hidden < 5 min
        let f = d.step(300, guest: guest(available: 0.5), visible: false)
        #expect(f.actions.map(\.action) == [.freeze])
        let frozen = d.step(310, guest: nil, host: host(), visible: false)
        #expect(frozen.tier == .freeze)
        #expect(frozen.nextSampleIn == .seconds(60))
        let thaw = d.step(400, guest: nil, host: host(), visible: true)
        #expect(thaw.actions.map(\.action) == [.thaw])
        // Hidden again right away: no re-freeze before the anti-flap cooldown and the hidden timer.
        for t in stride(from: 410, to: 700, by: 30) { d.step(t, guest: guest(available: 0.5), visible: false) }
        #expect(d.actions == [.freeze, .thaw])
        for t in stride(from: 710, to: 800, by: 30) { d.step(t, guest: guest(available: 0.5), visible: false) }
        #expect(d.actions == [.freeze, .thaw, .freeze])
    }

    @Test func userInputThawsAndBlocksFreeze() {
        var d = PolicyDriver(.preset(.balanced))
        // Hidden but the user keeps interacting (e.g. via adb/automation): never idle → no freeze.
        for t in stride(from: 0, through: 1800, by: 30) { d.step(t, guest: guest(available: 0.5), visible: false, interaction: t) }
        #expect(d.log.isEmpty)
        for t in stride(from: 1830, through: 2200, by: 30) { d.step(t, guest: guest(available: 0.5), visible: false, interaction: 1800) }
        #expect(d.actions == [.freeze])
        let thaw = d.step(2300, guest: nil, visible: false, interaction: 2290)
        #expect(thaw.actions.map(\.action) == [.thaw])
    }

    @Test func hibernateAfterLongFreezeAndResumeOnShow() {
        var d = PolicyDriver(.preset(.balanced))
        for t in stride(from: 0, through: 300, by: 30) { d.step(t, guest: guest(available: 0.5), visible: false) }
        #expect(d.state == .frozen)
        for t in stride(from: 360, through: 300 + 7200 - 60, by: 60) { d.step(t, guest: nil, visible: false) }
        #expect(!d.actions.contains(.hibernate))
        d.step(300 + 7200 + 60, guest: nil, visible: false)
        #expect(d.actions.last == .hibernate)
        let h = d.step(300 + 7200 + 120, guest: nil, host: nil, visible: false)
        #expect(h.tier == .hibernate)
        #expect(h.actions.isEmpty)
        let r = d.step(300 + 7200 + 180, guest: nil, host: nil, visible: true)
        #expect(r.actions.map(\.action) == [.resume])
        #expect(d.state == .running)
    }

    /// Regression: a resume (or thaw) that keeps failing was re-planned on every 1 s activity tick forever.
    /// It now backs off exponentially and stops after `maxReversalFailures` until new user input.
    @Test func failingResumeBacksOffAndWaitsForNewInput() {
        var policy = GovernorPolicy(config: .preset(.frugal))
        func tick(_ t: Int, interaction: Int) -> [GovernorAction] {
            policy.evaluate(PolicyInput(now: .seconds(1000 + t), engineState: .hibernated, isVisible: false,
                                        lastUserInteraction: .seconds(1000 + interaction))).actions.map(\.action)
        }
        _ = tick(0, interaction: -10)  // hibernated, no new input yet
        var planned: [Int] = []
        for t in 1...600 {
            if tick(t, interaction: 1) == [.resume] {
                planned.append(t)
                policy.recordFailure(for: .resume)
            }
        }
        #expect(planned.count == GovernorPolicy.maxReversalFailures)
        #expect(planned == [1, 6, 16, 36, 76])
        // New user input re-arms exactly one attempt.
        #expect(tick(700, interaction: 650) == [.resume])
        policy.recordFailure(for: .resume)
        #expect(tick(701, interaction: 650).isEmpty)
        #expect(tick(1000, interaction: 650).isEmpty)
        // A success clears the backoff.
        #expect(tick(1001, interaction: 1001) == [.resume])
        policy.record(outcome: .applied(), for: .resume)
        #expect(tick(1002, interaction: 1002) == [.resume])
    }

    @Test func failingThawBacksOff() {
        var policy = GovernorPolicy(config: .preset(.balanced))
        var planned = 0
        for t in 0..<120 {
            let a = policy.evaluate(PolicyInput(now: .seconds(1000 + t), engineState: .frozen, isVisible: true)).actions.map(\.action)
            if a == [.thaw] { planned += 1; policy.recordFailure(for: .thaw) }
        }
        #expect(planned == 5)
    }

    @Test func hostCriticalHibernatesFrozenInstanceImmediately() {
        var d = PolicyDriver(.preset(.balanced))
        for t in stride(from: 0, through: 300, by: 30) { d.step(t, guest: guest(available: 0.5), visible: false) }
        #expect(d.state == .frozen)
        let dec = d.step(330, guest: nil, host: host(pressure: .critical), visible: false)
        #expect(dec.actions.map(\.action) == [.hibernate])
        #expect(dec.actions[0].reason.contains("critical"))
    }

    @Test func overBudgetFootprintShortensHibernate() {
        var d = PolicyDriver(.preset(.balanced))
        for t in stride(from: 0, through: 300, by: 30) { d.step(t, guest: guest(available: 0.5), visible: false) }
        #expect(d.state == .frozen)
        var at: Int?
        for t in stride(from: 330, through: 3 * 3600, by: 60) {
            d.step(t, guest: nil, host: host(footprint: 11 * gib), visible: false)
            if d.actions.last == .hibernate { at = t; break }
        }
        // frozenSince = 330; under-budget would wait 2 h, over-budget waits the 30 min creep delay.
        #expect(at == 330 + 1800)
    }

    @Test func frozenInstanceIsNeverHibernatedWhileVisible() {
        var d = PolicyDriver(.preset(.balanced))
        d.state = .frozen
        let dec = d.step(0, guest: nil, host: host(pressure: .critical), visible: true)
        #expect(dec.actions.map(\.action) == [.thaw])
    }

    @Test func noActionsWhileBootingOrStopped() {
        var d = PolicyDriver(.preset(.frugal))
        for s in [InstanceState.booting, .stopped, .stopping, .hibernating, .crashed(reason: "x")] {
            d.state = s
            for t in stride(from: 0, through: 3600, by: 60) { d.step(t, guest: guest(available: 0.02), host: host(pressure: .critical), visible: false) }
        }
        #expect(d.log.isEmpty)
    }

    @Test func missingGuestSamplePausesPressureTiers() {
        var d = PolicyDriver(.preset(.balanced))
        let dec = d.step(0, guest: nil, host: host(pressure: .critical))
        #expect(dec.level == .normal)
        #expect(dec.hostLevel == .critical)
        #expect(dec.actions.isEmpty)
        #expect(dec.notes.contains { $0.contains("no guest sample") })
    }

    @Test func maintenanceRunsWhenIdleOnSchedule() {
        var d = PolicyDriver(.preset(.balanced))
        var plans: [(Int, MaintenancePlan)] = []
        for t in stride(from: 0, through: 5 * 3600, by: 60) {
            // User active for the first 3 h, then idle (but window visible, so no freeze).
            let dec = d.step(t, guest: guest(available: 0.5), visible: true, interaction: t <= 3 * 3600 ? t : 3 * 3600)
            if let p = dec.maintenance { plans.append((t, p)) }
        }
        // Due at 2 h but the user is active until 3 h; runs at 3 h + 10 min idle, then every 2 h.
        #expect(plans.map(\.0) == [3 * 3600 + 600])
        #expect(plans.first?.1.steps == [.trimBackground, .killCached, .trimCaches, .compact, .reclaim])
        d.policy.recordMaintenance(unsupportedReclaim: true)
        var later: MaintenancePlan?
        for t in stride(from: 5 * 3600 + 60, through: 8 * 3600, by: 60) {
            if let p = d.step(t, guest: guest(available: 0.5), visible: true, interaction: 3 * 3600).maintenance { later = p; break }
        }
        #expect(later?.steps.contains(.reclaim) == false)
    }

    @Test func performanceMaintenanceRequiresHidden() {
        var d = PolicyDriver(.preset(.performance))
        for t in stride(from: 0, through: 10 * 3600, by: 60) {
            #expect(d.step(t, guest: guest(available: 0.5), visible: true).maintenance == nil)
        }
    }

    @Test func creepDetectedOnRisingFootprintAndShortensMaintenance() {
        var d = PolicyDriver(.preset(.balanced))
        var creeps: [(Int, CreepReport)] = []
        var maint: [Int] = []
        for t in stride(from: 0, to: 3 * 3600, by: 30) {
            let fp = 2 * gib + UInt64(Double(t) / 3600 * Double(200 * mib))   // +200 MiB/h
            let dec = d.step(t, guest: guest(available: 0.5), host: host(footprint: fp), visible: true, interaction: 0)
            if let c = dec.creep { creeps.append((t, c)) }
            if dec.maintenance != nil { maint.append(t) }
        }
        #expect(creeps.count == 2)                                     // at ~1 h and again ≥ 1 h later
        let first = creeps[0].1
        #expect(first.signal == .engineFootprint)
        #expect(abs(Double(first.bytesPerHour) - Double(200 * mib)) < Double(5 * mib))
        #expect(creeps[0].0 >= 3600 && creeps[0].0 <= 3700)
        #expect(creeps[1].0 - creeps[0].0 >= 3600)
        #expect(d.policy.creepActive)
        // With creep active the 45 min interval applies: first run as soon as creep is seen (> 45 min since start).
        #expect(maint.first == creeps[0].0)
        #expect(maint.count >= 3)
    }

    @Test func creepOnShrinkingGuestAvailable() {
        var d = PolicyDriver(.preset(.balanced))
        var found: CreepReport?
        for t in stride(from: 0, through: 2 * 3600, by: 30) {
            let avail = 0.60 - Double(t) / 3600 * 0.08                  // −0.08 × 2 GiB ≈ −164 MiB/h
            if let c = d.step(t, guest: guest(available: avail), interaction: t).creep { found = c }
        }
        #expect(found?.signal == .guestAvailable)
        #expect((found?.bytesPerHour ?? 0) < -Int64(128 * mib))
    }

    @Test func noCreepOnNoisyButFlatFootprint() {
        var d = PolicyDriver(.preset(.balanced))
        var creeps = 0
        for t in stride(from: 0, through: 6 * 3600, by: 30) {
            let jitter = UInt64((t / 30) % 7) * 40 * mib
            if d.step(t, guest: guest(available: 0.5), host: host(footprint: 2 * gib + jitter), interaction: t).creep != nil { creeps += 1 }
        }
        #expect(creeps == 0)
    }

    @Test func creepUnderFreezeShortensHibernate() throws {
        var d = PolicyDriver(.preset(.balanced))
        // Build creep while visible.
        for t in stride(from: 0, through: 3700, by: 30) {
            let fp = 2 * gib + UInt64(Double(t) / 3600 * Double(300 * mib))
            d.step(t, guest: guest(available: 0.5), host: host(footprint: fp), visible: true, interaction: t)
        }
        #expect(d.policy.creepActive)
        var hibernatedAt: Int?
        for t in stride(from: 3730, through: 3730 + 3 * 3600, by: 60) {
            let fp = 2 * gib + UInt64(Double(t) / 3600 * Double(300 * mib))
            d.step(t, guest: d.state == .running ? guest(available: 0.5) : nil, host: host(footprint: fp), visible: false, interaction: 3700)
            if d.actions.last == .hibernate { hibernatedAt = t; break }
        }
        let freezeAt = d.log.first { $0.action == .freeze }!.t
        let h = try #require(hibernatedAt)
        #expect(h - freezeAt >= 1800 && h - freezeAt < 2 * 3600)
    }
}
