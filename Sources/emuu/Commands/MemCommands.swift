import Foundation
import ArgumentParser
import EmuuBase
import EmuuADB
import EmuuMemory

extension TrimMemoryLevel: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(rawValue: argument.uppercased())
    }
}

struct Mem: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Memory governor: live view (default), manual trim, reclaim.",
        subcommands: [MemWatch.self, MemTrim.self, MemReclaim.self],
        defaultSubcommand: MemWatch.self)
}

struct MemWatch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Live governor view: samples, tier changes and actions (Ctrl-C to quit).")

    @OptionGroup var target: TargetInstance
    @Flag(help: "JSON lines (one governor event per line, or one reading per line without a supervisor).")
    var json = false
    @Flag(help: "Print the current state and recent events once, then exit.")
    var once = false
    @Flag(help: "Also print a per-app memory breakdown (dumpsys meminfo; costs a few hundred ms in the guest).")
    var apps = false
    @Option(help: "Polling interval in seconds.") var interval: Double = 2

    func run() async throws {
        let ctx = try CLIContext.live()
        let config = try ctx.resolveInstance(target.explicit)
        let registry = SupervisorRegistry(paths: ctx.paths)
        if apps { try await printApps(ctx: ctx, config: config) }
        guard let sup = registry.liveSupervisor(for: config.id) else {
            return try await observe(ctx: ctx, config: config)
        }
        let client = ControlClient(socketPath: sup.socketPath)
        var since: UInt64 = 0
        var first = true
        while !Task.isCancelled {
            let reply: ControlReply
            do {
                reply = try await client.send(ControlRequest(command: .events, since: since), timeout: .seconds(10))
            } catch {
                if first { throw CLIError("supervisor did not answer: \(describe(error))") }
                Out.err("Supervisor for \(config.id) is gone.")
                return
            }
            if first, let st = reply.status, !json {
                Out.line(Self.header(st))
            }
            for e in reply.events ?? [] {
                if json { Out.line(try JSONText.encode(e)) } else { Out.line(EventText.render(e.event)) }
            }
            since = reply.nextSeq.map { $0 - 1 } ?? since
            first = false
            if once { return }
            try await Task.sleep(for: .seconds(max(0.2, interval)))
        }
    }

    static func header(_ st: SupervisorStatus) -> String {
        let g = st.governor
        var lines = ["\(st.instanceID): \(st.engineStateDetail)\(st.serial.map { " on \($0)" } ?? "") · supervisor pid \(st.pid) (\(st.mode)) · up \(Fmt.uptime(Date().timeIntervalSince(st.startedAt)))"]
        if g.enabled {
            var s = "governor \(g.profile): level \(g.level), tier \(g.tier), \(g.samplesTaken) samples, \(g.actionsApplied) actions applied, \(g.actionsFailed) failed, \(g.maintenanceRuns) maintenance runs"
            if !g.disabledTiers.isEmpty { s += "; unsupported here: \(g.disabledTiers.joined(separator: ", "))" }
            if g.creepActive { s += "; CREEP DETECTED" }
            lines.append(s)
            lines.append("idle freeze: \(g.freezeWhenHiddenAfterSeconds.map { Fmt.uptime($0) } ?? "off") · hibernate after frozen: \(g.hibernateWhenFrozenAfterSeconds.map { Fmt.uptime($0) } ?? "never")")
        } else {
            lines.append("governor off")
        }
        if let m = MemoryReading(point: st.lastSample) { lines.append("last sample: " + m.line) }
        return lines.joined(separator: "\n")
    }

    /// No supervisor: read-only sampling (no governor actions).
    private func observe(ctx: CLIContext, config: InstanceConfig) async throws {
        let engine = try await ctx.engines.engine(for: config.id)
        if !json { Out.err("No supervisor runs for \(config.id), so the governor is off; showing samples only. Start one with `emuu start \(config.id) --detach`.") }
        while !Task.isCancelled {
            let state = await engine.refresh()
            let reading = await MemoryReading.sample(ctx: ctx, enginePID: await engine.enginePID(),
                                                      serial: state == .running ? await engine.serial() : nil)
            if json { Out.line(try JSONText.encode(reading)) } else { Out.line("[\(Fmt.time(reading.sampledAt))] \(state) · \(reading.line)") }
            if once { return }
            try await Task.sleep(for: .seconds(max(1, interval)))
        }
    }

    private func printApps(ctx: CLIContext, config: InstanceConfig) async throws {
        let serial = try await ctx.ensureRunning(config, wake: false)
        let usage = try await GuestSampler(shell: ADBClient(serial: serial, server: ctx.adbServer())).appBreakdown()
            .sorted { $0.pssBytes > $1.pssBytes }
        if json { return try Out.json(usage, pretty: false) }
        Out.line(Fmt.table(["PACKAGE/PROCESS", "PSS", "FG"], usage.prefix(25).map { [$0.packageName, Fmt.mib($0.pssBytes), $0.isForeground ? "yes" : ""] }))
        Out.line("")
    }
}

struct MemTrim: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trim",
        abstract: "Manual T1: ask background apps to release memory (send-trim-memory); --kill adds T2.",
        discussion: "The foreground app, launchers, system UI, Play services and the Play Store are never touched.")

    @OptionGroup var target: TargetInstance
    @Option(help: "Trim level: HIDDEN, RUNNING_MODERATE, BACKGROUND, RUNNING_LOW, MODERATE, RUNNING_CRITICAL, COMPLETE.")
    var level: TrimMemoryLevel = .moderate
    @Flag(help: "T2: also kill cached (background) app processes.") var kill = false
    @Option(help: "Also run `pm trim-caches` until this many GB of storage are free (deletes app cache files).")
    var cachesGb: Double?
    @Flag(help: "JSON output.") var json = false

    func run() async throws {
        let ctx = try CLIContext.live()
        let config = try ctx.resolveInstance(target.explicit)
        let caches = cachesGb.map { UInt64($0 * Double(ByteCount.gib)) }
        let reports: [TierReport]
        if let sup = SupervisorRegistry(paths: ctx.paths).liveSupervisor(for: config.id), sup.status?.governor.enabled != false {
            let reply = try await ControlClient(socketPath: sup.socketPath).send(
                ControlRequest(command: .trim, kill: kill, level: level, cachesBytes: caches), timeout: .seconds(180))
            guard reply.ok else { throw CLIError(reply.message ?? "trim failed") }
            reports = reply.reports ?? []
        } else {
            let serial = try await ctx.ensureRunning(config, wake: false)
            let guest = GuestEffector(shell: ADBClient(serial: serial, server: ctx.adbServer()))
            reports = await ManualTiers.trim(guest: guest, level: level, kill: kill, caches: caches)
        }
        if json { return try Out.json(reports) }
        Out.line(ManualTiers.render(reports))
        if reports.contains(where: { $0.status == "failed" }) { throw ExitCode(1) }
    }
}

struct MemReclaim: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reclaim",
        abstract: "Manual T3: try to return guest RAM to the Mac, plus guest compaction.",
        discussion: """
        On engine 36.4.9 with the android-36.1 image this reports `unsupported`: the guest kernel has no \
        virtio-balloon driver. The reliable way to give memory back is `emuu hibernate` (~2 s resume).
        """)

    @OptionGroup var target: TargetInstance
    @Flag(help: "JSON output.") var json = false

    func run() async throws {
        let ctx = try CLIContext.live()
        let config = try ctx.resolveInstance(target.explicit)
        let reports: [TierReport]
        if let sup = SupervisorRegistry(paths: ctx.paths).liveSupervisor(for: config.id), sup.status?.governor.enabled != false {
            let reply = try await ControlClient(socketPath: sup.socketPath).send(ControlRequest(command: .reclaim), timeout: .seconds(120))
            guard reply.ok else { throw CLIError(reply.message ?? "reclaim failed") }
            reports = reply.reports ?? []
        } else {
            let serial = try await ctx.ensureRunning(config, wake: false)
            let engine = try await ctx.engines.engine(for: config.id)
            reports = await ManualTiers.reclaim(guest: GuestEffector(shell: ADBClient(serial: serial, server: ctx.adbServer())),
                                                engine: EngineEffector(engine: engine))
        }
        if json { return try Out.json(reports) }
        Out.line(ManualTiers.render(reports))
        if reports.first?.status == "unsupported" {
            Out.line("To return host memory now: `emuu hibernate \(config.id)` (resume takes about 2 s).")
        }
    }
}
