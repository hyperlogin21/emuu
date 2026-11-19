import Darwin
import Foundation
import EmuuBase
import EmuuEngine
import EmuuFarm

/// Health checks and recovery steps for one instance, shared by `emuu health/heal/reboot` and the supervisor's
/// self-healing loop.
enum HealthService {
    /// `run/<id>.bootid`: the guest boot id seen at the last healthy check (unexpected-reboot detection for
    /// ordinary instances; farm devices compare with their golden's id instead).
    static func bootIDFile(_ paths: EmuuPaths, _ id: InstanceID) -> URL {
        paths.runDirectory.appendingPathComponent("\(id.rawValue).bootid")
    }

    static func prober(_ ctx: CLIContext) -> HealthProber {
        HealthProber(runner: SystemProcessRunner(), adb: ctx.sdk.adb)
    }

    /// Probes `engine`'s instance. Records the boot id after a healthy check; a changed id is reported once as
    /// `degraded (guest rebooted)` and then becomes the new expectation.
    static func check(ctx: CLIContext, config: InstanceConfig, engine: EngineInstance, deep: Bool = false,
                      bootGrace: Bool? = nil) async -> HealthReport {
        // A pid file whose process is gone means the engine died without a clean stop (a clean stop/hibernate
        // removes it). Read it before refresh(), which clears it.
        let pidFile = ctx.paths.pidFile(for: config.id)
        let stalePID = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .flatMap { kill($0, 0) != 0 && errno == ESRCH ? $0 : nil }
        var state = await engine.refresh()
        if !state.isRunningEngine, state != .hibernated {
            if let stalePID {
                state = .crashed(reason: "engine pid \(stalePID) exited without a clean stop")
            } else if let why = CrashMarker.reason(for: config.id, paths: ctx.paths) {
                state = .crashed(reason: why)
            }
        }
        let pid = await engine.enginePID()
        let port = await engine.consolePorts()?.console
        var expected = (try? String(contentsOf: bootIDFile(ctx.paths, config.id), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let golden = config.goldenSource, config.discardStateOnExit == true,
           let record = GoldenStore.load(golden, farm: FarmPaths(paths: ctx.paths)) {
            expected = record.bootID
        }
        if !state.isRunningEngine && pid == nil {
            let verdict: HealthVerdict
            let reason: String
            switch state {
            case .crashed(let why): verdict = .dead; reason = "engine crashed: \(why)"
            case .hibernated: verdict = .stopped; reason = "hibernated (resume with `emuu resume`)"
            default: verdict = .stopped; reason = "not running"
            }
            return HealthReport(instance: config.id.rawValue, serial: nil, verdict: verdict, reason: reason,
                                fault: verdict == .dead ? .engineDead : nil, checkedAt: Date(),
                                probes: [ProbeResult(name: "process", status: verdict == .dead ? .fail : .skip, detail: reason)],
                                bootID: nil, suggestedStep: verdict == .dead ? .hardRestart : nil)
        }
        let target = HealthProber.Target(instance: config.id.rawValue, enginePID: pid, consolePort: port,
                                         frozenByEmuu: FreezeMarker.isSet(for: config.id, paths: ctx.paths),
                                         expectedBootID: expected, withinBootGrace: bootGrace ?? (state == .booting))
        let report = await prober(ctx).check(target, deep: deep, farmDevice: config.discardStateOnExit == true)
        if let b = report.bootID, report.verdict == .healthy || report.fault == .guestRebooted {
            try? Data((b + "\n").utf8).write(to: bootIDFile(ctx.paths, config.id), options: .atomic)
        }
        return report
    }

    /// Executes one recovery step on an instance's engine (not for farm devices: their pool daemon recovers them).
    static func perform(_ step: HealStep, ctx: CLIContext, engine: EngineInstance) async throws {
        _ = await engine.refresh()
        switch step {
        case .thaw:
            if let pid = await engine.enginePID() { kill(pid, SIGCONT) }
            _ = await engine.refresh()
            if await engine.state() == .frozen { try await engine.thaw() }
        case .reconnectADB:
            guard let serial = await engine.serial() else { throw EmuuError.engine("no adb serial") }
            _ = try? await SystemProcessRunner().run(ProcessRequest(executable: ctx.sdk.adb, arguments: ["-s", serial.rawValue, "reconnect"], timeout: .seconds(10)))
            _ = try? await SystemProcessRunner().run(ProcessRequest(executable: ctx.sdk.adb, arguments: ["reconnect", "offline"], timeout: .seconds(10)))
            try await Task.sleep(for: .seconds(2))
        case .softReboot:
            try await engine.rebootGuest()
        case .reset:
            try await engine.resetToQuickBootSnapshot()
        case .hardRestart:
            if await engine.state().isRunningEngine {
                // Console kill saves the quick-boot snapshot; escalates to SIGTERM/SIGKILL on timeout (a SIGKILL
                // discards the snapshot, so the start below cold-boots from the current disks).
                do { try await engine.stop(.graceful(saveQuickBoot: true)) } catch { try await engine.stop(.force) }
            } else {
                try? await engine.stop(.force)
            }
            try await engine.start(EngineLaunchOptions(bootTimeout: .seconds(300)))
        case .coldBoot:
            if await engine.state().isRunningEngine { try await engine.stop(.force) } // discards the (suspect) snapshot
            try await engine.start(EngineLaunchOptions(coldBoot: true, bootTimeout: .seconds(300)))
        case .replace:
            throw EmuuError.engine("replace applies to farm devices only")
        }
    }

    struct StepResult: Codable, Sendable {
        var step: HealStep
        var ok: Bool
        var millis: Int
        var error: String?
        var after: HealthSummary?
    }

    struct HealResult: Codable, Sendable {
        var instance: String
        var before: HealthReport
        var steps: [StepResult]
        var after: HealthReport
        var healed: Bool
    }

    /// Runs the escalation ladder until a check passes. `waitSeconds` bounds the final wait for health.
    static func heal(ctx: CLIContext, config: InstanceConfig, engine: EngineInstance, start: HealthReport? = nil,
                     waitSeconds: Int = 120, onStep: (HealStep, String) -> Void = { _, _ in }) async -> HealResult {
        let history = HealthHistory(paths: ctx.paths, instance: config.id.rawValue)
        var before: HealthReport
        if let start { before = start } else { before = await check(ctx: ctx, config: config, engine: engine, deep: true) }
        if before.verdict == .hung || before.verdict == .degraded {
            // Confirm first: an adb transport dropped by `adb disconnect` or an adb server restart comes back by
            // itself within a second or two (measured), and must not cost an engine restart.
            try? await Task.sleep(for: .seconds(3))
            let again = await check(ctx: ctx, config: config, engine: engine, deep: true)
            if again.verdict == .healthy || again.fault != before.fault { before = again }
        }
        if before.fault == .notBooted {
            // Still booting (or adb just dropped, which also reads as "booting"): give it time before restarting.
            let waited = await waitHealthy(ctx: ctx, config: config, engine: engine, seconds: 60)
            before = waited.verdict == .healthy ? waited : await check(ctx: ctx, config: config, engine: engine, deep: true, bootGrace: false)
        }
        var steps: [StepResult] = []
        var last = before
        if before.verdict == .healthy || before.verdict == .frozen || before.verdict == .stopped {
            return HealResult(instance: config.id.rawValue, before: before, steps: [], after: before, healed: before.verdict == .healthy)
        }
        history.append(HealthHistoryEntry(at: Date(), kind: "detect", verdict: before.verdict, reason: before.reason))
        for step in HealLadder.steps(for: before.fault, farmDevice: false) {
            onStep(step, before.reason)
            let t0 = ContinuousClock.now
            var err: String?
            do { try await perform(step, ctx: ctx, engine: engine) } catch { err = describe(error) }
            last = await waitHealthy(ctx: ctx, config: config, engine: engine, seconds: err == nil ? waitSeconds : 5)
            let ms = Int((ContinuousClock.now - t0).timeInterval * 1000)
            let ok = err == nil && last.verdict == .healthy
            steps.append(StepResult(step: step, ok: ok, millis: ms, error: err, after: last.summary))
            history.append(HealthHistoryEntry(at: Date(), kind: ok ? "recovered" : "heal-failed", verdict: last.verdict,
                                              reason: err ?? last.reason, step: step, millis: ms))
            if ok { break }
        }
        return HealResult(instance: config.id.rawValue, before: before, steps: steps, after: last, healed: last.verdict == .healthy)
    }

    /// Polls until healthy (boot grace on) or `seconds` pass; then one strict check.
    static func waitHealthy(ctx: CLIContext, config: InstanceConfig, engine: EngineInstance, seconds: Int) async -> HealthReport {
        let deadline = ContinuousClock.now + .seconds(seconds)
        var report = await check(ctx: ctx, config: config, engine: engine, bootGrace: true)
        while report.verdict != .healthy, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .seconds(1))
            report = await check(ctx: ctx, config: config, engine: engine, bootGrace: true)
        }
        return report
    }
}
