import Darwin
import Foundation
import ArgumentParser
import EmuuBase
import EmuuEngine
import EmuuFarm

// MARK: health

struct Health: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Layered health check of an instance: healthy, degraded, hung, dead (or frozen/stopped).",
        discussion: """
        Probes, each with its own timeout: engine process (alive, not SIGSTOPped by someone else), console ping, \
        adb transport state, one adb shell round trip (boot_completed, boot_id, uptime, /data free), a \
        system_server binder call, and with --deep the focused window (ANR / crash dialogs). \
        Exit status: 0 healthy or frozen-by-Emuu, 1 degraded, 2 hung, 3 dead, 4 stopped.
        """)

    @OptionGroup var target: TargetInstance
    @Flag(help: "Also run the UI probe (dumpsys window).") var deep = false
    @Flag(help: "Show the recorded detections and recoveries instead of checking.") var history = false
    @Flag(help: "JSON output.") var json = false

    func run() async throws {
        let ctx = try CLIContext.live()
        let config = try ctx.resolveInstance(target.explicit)
        if history {
            let entries = HealthHistory(paths: ctx.paths, instance: config.id.rawValue).entries()
            if json { return try Out.json(entries) }
            if entries.isEmpty { return Out.line("No health events recorded for \(config.id).") }
            for e in entries {
                Out.line("\(ISO8601DateFormatter().string(from: e.at))  \(e.kind.padding(toLength: 11, withPad: " ", startingAt: 0)) \(e.verdict?.rawValue ?? "-")  \(e.step.map { "[\($0.rawValue)] " } ?? "")\(e.reason)\(e.millis.map { " (\($0) ms)" } ?? "")")
            }
            return
        }
        let engine = try await ctx.engines.engine(for: config.id)
        let report = await HealthService.check(ctx: ctx, config: config, engine: engine, deep: deep)
        if report.verdict != .healthy {
            HealthHistory(paths: ctx.paths, instance: config.id.rawValue)
                .append(HealthHistoryEntry(at: Date(), kind: "check", verdict: report.verdict, reason: report.reason))
        }
        if json { try Out.json(report) } else { Self.print(report) }
        throw ExitCode(Self.exitCode(report.verdict))
    }

    static func exitCode(_ v: HealthVerdict) -> Int32 {
        switch v {
        case .healthy, .frozen: return 0
        case .degraded: return 1
        case .hung: return 2
        case .dead: return 3
        case .stopped: return 4
        }
    }

    static func print(_ r: HealthReport) {
        Out.line("\(r.instance): \(r.verdict.rawValue.uppercased()) — \(r.reason)")
        for p in r.probes {
            let mark = p.status == .ok ? "ok  " : p.status == .fail ? "FAIL" : "skip"
            Out.line("  [\(mark)] \(p.name.padding(toLength: 9, withPad: " ", startingAt: 0)) \(p.detail)\(p.millis.map { " (\($0) ms)" } ?? "")")
        }
        if let s = r.suggestedStep { Out.line("  next step: `emuu heal \(r.instance)` would start with \(s.rawValue)") }
    }
}

// MARK: reboot

enum RebootMode: String, ExpressibleByArgument, CaseIterable, Codable, Sendable {
    case soft, hard, cold

    var step: HealStep {
        switch self {
        case .soft: return .softReboot
        case .hard: return .hardRestart
        case .cold: return .coldBoot
        }
    }
}

struct Reboot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Reboot an instance: --soft (guest reboot via adb, default), --hard (engine restart from the quick-boot snapshot) or --cold (engine restart, cold boot).")

    @OptionGroup var target: TargetInstance
    @Flag(help: "Guest reboot (`adb reboot`); the engine keeps running.") var soft = false
    @Flag(help: "Stop the engine (console kill → SIGTERM → SIGKILL) and start it from the quick-boot snapshot.") var hard = false
    @Flag(help: "Stop the engine and cold-boot it (the quick-boot snapshot is discarded).") var cold = false
    @Flag(help: "Wait until the instance is healthy again (non-zero exit if it does not get there).") var wait = false
    @Flag(help: "JSON output.") var json = false

    func validate() throws {
        if [soft, hard, cold].filter({ $0 }).count > 1 { throw ValidationError("choose one of --soft, --hard, --cold") }
    }

    var mode: RebootMode { hard ? .hard : cold ? .cold : .soft }

    struct Result: Codable, Sendable {
        var instance: String
        var mode: RebootMode
        var ok: Bool
        var seconds: Double
        var error: String?
        var health: HealthReport?
    }

    func run() async throws {
        let ctx = try CLIContext.live()
        let config = try ctx.resolveInstance(target.explicit)
        try FarmGuard.refuseFarmDevice(config, action: "reboot")
        let t0 = ContinuousClock.now
        var err: String?
        if let sup = SupervisorRegistry(paths: ctx.paths).liveSupervisor(for: config.id) {
            let reply = try await ControlClient(socketPath: sup.socketPath)
                .send(ControlRequest(command: .reboot, rebootMode: mode.rawValue), timeout: .seconds(420))
            if !reply.ok { err = reply.message ?? "reboot failed" }
        } else {
            let engine = try await ctx.engines.engine(for: config.id)
            do { try await HealthService.perform(mode.step, ctx: ctx, engine: engine) } catch { err = describe(error) }
        }
        var health: HealthReport?
        if wait || json, err == nil {
            let engine = try await ctx.engines.engine(for: config.id)
            health = await HealthService.waitHealthy(ctx: ctx, config: config, engine: engine, seconds: wait ? 180 : 10)
        }
        let secs = (ContinuousClock.now - t0).timeInterval
        HealthHistory(paths: ctx.paths, instance: config.id.rawValue).append(HealthHistoryEntry(
            at: Date(), kind: "reboot", verdict: health?.verdict, reason: err ?? "\(mode.rawValue) reboot by request", step: mode.step,
            millis: Int(secs * 1000)))
        let ok = err == nil && (!wait || health?.verdict == .healthy)
        if json {
            try Out.json(Result(instance: config.id.rawValue, mode: mode, ok: ok, seconds: secs, error: err, health: health))
        } else if let err {
            Out.err("emuu: \(config.id): \(mode.rawValue) reboot failed: \(err)")
        } else {
            Out.line("\(config.id): \(mode.rawValue) reboot done in \(Fmt.seconds(ContinuousClock.now - t0))\(health.map { "; \($0.verdict.rawValue)" } ?? "").")
        }
        if !ok { throw ExitCode(1) }
    }
}

// MARK: heal

struct Heal: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check health and apply the smallest fix: reconnect adb → soft reboot → hard restart → cold boot (farm devices: reset → fresh clone).")

    @OptionGroup var target: TargetInstance
    @Flag(help: "Wait until healthy; non-zero exit if recovery failed.") var wait = false
    @Flag(help: "JSON output.") var json = false

    func run() async throws {
        let ctx = try CLIContext.live()
        let config = try ctx.resolveInstance(target.explicit)
        if let pool = FarmGuard.pool(of: config, paths: ctx.paths) {
            return try await healFarmDevice(ctx: ctx, config: config, pool: pool)
        }
        let result: HealthService.HealResult
        if let sup = SupervisorRegistry(paths: ctx.paths).liveSupervisor(for: config.id) {
            let reply = try await ControlClient(socketPath: sup.socketPath).send(ControlRequest(command: .heal), timeout: .seconds(900))
            guard let data = reply.message?.data(using: .utf8), let r = try? JSONText.decoder.decode(HealthService.HealResult.self, from: data) else {
                throw CLIError(reply.message ?? "supervisor did not answer")
            }
            result = r
        } else {
            let engine = try await ctx.engines.engine(for: config.id)
            result = await HealthService.heal(ctx: ctx, config: config, engine: engine, waitSeconds: wait ? 180 : 90) { step, why in
                if !json { Out.err("\(config.id): \(why) → \(step.rawValue)…") }
            }
        }
        if json { try Out.json(result) } else {
            Out.line("\(config.id): before \(result.before.verdict.rawValue) (\(result.before.reason))")
            for s in result.steps {
                Out.line("  \(s.step.rawValue): \(s.ok ? "ok" : "not fixed") in \(s.millis) ms\(s.error.map { " — \($0)" } ?? "")")
            }
            Out.line("\(config.id): now \(result.after.verdict.rawValue) (\(result.after.reason))")
        }
        if !result.healed { throw ExitCode(1) }
    }

    /// Farm devices are recovered by their pool daemon: mark the device unhealthy and (with --wait) wait for it.
    private func healFarmDevice(ctx: CLIContext, config: InstanceConfig, pool: String) async throws {
        let store = FarmStateStore(farm: FarmPaths(paths: ctx.paths), pool: pool)
        try store.update { s in
            s.withDevice(config.id.rawValue) { d in
                if d.state == .ready || d.state == .frozen || d.state == .failed { d.state = .unhealthy; d.note = "heal requested" }
            }
            s.log("heal-request", device: config.id.rawValue, "emuu heal", at: Date())
        }
        Out.err("\(config.id) belongs to farm pool '\(pool)'; its daemon recovers it (reset, else a fresh clone).")
        guard wait else { return }
        let deadline = ContinuousClock.now + .seconds(240)
        while ContinuousClock.now < deadline {
            if let d = try? store.read().device(config.id.rawValue), d.state == .ready || d.state == .leased {
                if json { try Out.json(d) } else { Out.line("\(config.id): \(d.state.rawValue)") }
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw CLIError("\(config.id) did not become ready within 240 s")
    }
}

/// Farm devices are owned by their pool daemon; direct lifecycle commands would fight it.
enum FarmGuard {
    static func pool(of config: InstanceConfig, paths: EmuuPaths) -> String? {
        guard config.discardStateOnExit == true else { return nil }
        let farm = FarmPaths(paths: paths)
        return farm.poolNames().first { name in
            (try? FarmStateStore(farm: farm, pool: name).read().device(config.id.rawValue)) != nil
        }
    }

    static func refuseFarmDevice(_ config: InstanceConfig, action: String) throws {
        guard config.discardStateOnExit == true, config.id.rawValue.hasPrefix("farm-") else { return }
        throw CLIError("\(config.id) is a farm pool device; use `emuu heal \(config.id)` (the daemon resets or replaces it) or `emuu farm release --recycle`.")
    }
}
