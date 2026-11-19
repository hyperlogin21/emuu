import Darwin
import Foundation
import ArgumentParser
import EmuuBase
import EmuuEngine
import EmuuADB
import EmuuMemory

/// `--profile lite|balanced|performance` (lite = MemoryProfile.frugal).
enum ProfileArgument: String, ExpressibleByArgument, CaseIterable, Sendable {
    case lite, balanced, performance

    var memoryProfile: MemoryProfile {
        switch self {
        case .lite: return .frugal
        case .balanced: return .balanced
        case .performance: return .performance
        }
    }

    init(_ profile: MemoryProfile) {
        switch profile {
        case .frugal: self = .lite
        case .balanced: self = .balanced
        case .performance: self = .performance
        }
    }
}

/// Optional positional instance name, plus `-i`.
struct TargetInstance: ParsableArguments {
    @Argument(help: "Instance name (same as -i).")
    var name: String?

    @OptionGroup var option: InstanceOption

    var explicit: String? { name ?? option.instance }
}

// MARK: start

struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Boot an instance and supervise it (engine + memory governor).",
        discussion: """
        Runs in the foreground until Ctrl-C (which saves a quick-boot snapshot and stops the engine), \
        or in the background with --detach. Other commands and the app find the supervisor through \
        ~/.emuu/run/<id>.supervisor.json and its control socket.

        Headless (default) there is no window; use `emuu screenshot` or adb to see the screen. \
        --window opens a lightweight display window (the engine's own framebuffer over gRPC) and lets the \
        governor freeze the engine while the window is hidden.
        """)

    @OptionGroup var target: TargetInstance

    @Flag(name: .customLong("headless"), help: "No window (default).")
    var headless = false

    @Flag(name: .customLong("window"), help: "Open a display window.")
    var window = false

    @Option(help: "Governor profile: lite, balanced or performance. Default: the instance's profile.")
    var profile: ProfileArgument?

    @Flag(help: "Run the supervisor in the background and return once the instance has booted.")
    var detach = false

    @Flag(help: "Ignore the quick-boot snapshot and cold boot.")
    var coldBoot = false

    @Flag(help: "Run without the memory governor.")
    var noGovernor = false

    @Option(help: "Headless only: freeze the engine after this many idle minutes (no Emuu command touching it). Default: never.")
    var idleFreeze: Int?

    @Flag(help: "Do not print a line for every memory sample.")
    var quiet = false

    @Flag(help: "Automation mode (tests/scripts over adb): never freeze or hibernate; only trim/kill background apps. Saved for the instance; `emuu automation off` turns it off.")
    var automation = false

    @Option(help: "Seconds to wait for Android to finish booting.")
    var bootTimeout: Int = 600

    @Option(help: "Video decoder (saved for the instance): auto, hardware, software or host-software. A change from host to guest decoders or back cold-boots once.")
    var videoDecoder: VideoDecoderMode?

    @Flag(help: "Self-healing: periodic health checks, automatic recovery of a hung or dead engine (saved for the instance).")
    var selfHeal = false

    @Flag(name: .customLong("supervise-child"), help: .hidden)
    var superviseChild = false

    func validate() throws {
        if headless && window { throw ValidationError("--headless and --window are mutually exclusive") }
        if window && detach { throw ValidationError("--window cannot be combined with --detach") }
        if let idleFreeze, idleFreeze < 1 { throw ValidationError("--idle-freeze must be at least 1 minute") }
        if bootTimeout < 10 { throw ValidationError("--boot-timeout must be at least 10 seconds") }
    }

    func supervisorOptions(for config: InstanceConfig, paths: EmuuPaths) -> SupervisorOptions {
        let p = profile?.memoryProfile ?? config.memoryProfile
        return SupervisorOptions(
            mode: window ? .window : .headless,
            governorEnabled: !noGovernor,
            governor: GovernorOptions(profile: p, guestRAMMB: EffectiveRAM.megabytes(for: config, paths: paths), headless: !window,
                                      idleFreezeAfter: idleFreeze.map { .minutes($0) },
                                      automation: automation || config.isAutomationMode),
            launch: EngineLaunchOptions(coldBoot: coldBoot, bootTimeout: .seconds(bootTimeout)),
            echo: true, quiet: quiet, selfHeal: selfHeal || config.isSelfHealing)
    }

    /// Arguments for the detached child (same choices, plus the internal flag).
    func childArguments(id: InstanceID) -> [String] {
        var args = ["start", id.rawValue, "--supervise-child"]
        if let profile { args += ["--profile", profile.rawValue] }
        if coldBoot { args.append("--cold-boot") }
        if noGovernor { args.append("--no-governor") }
        if let idleFreeze { args += ["--idle-freeze", String(idleFreeze)] }
        if quiet { args.append("--quiet") }
        if automation { args.append("--automation") }
        if selfHeal { args.append("--self-heal") }
        args += ["--boot-timeout", String(bootTimeout)]
        return args
    }

    func run() async throws {
        let ctx = try CLIContext.live()
        var config = try ctx.resolveInstance(target.explicit)
        let registry = SupervisorRegistry(paths: ctx.paths)
        if automation && !config.isAutomationMode && !superviseChild {
            config = try ctx.store.updatePreferences(config.id) { $0.automationMode = true }
        }
        if selfHeal && !config.isSelfHealing && !superviseChild {
            config = try ctx.store.updatePreferences(config.id) { $0.selfHeal = true }
        }
        if let videoDecoder, videoDecoder != config.videoDecoder, !superviseChild {
            config = try ctx.store.updatePreferences(config.id) { $0.videoDecoder = videoDecoder }
        }
        if let live = registry.liveSupervisor(for: config.id) {
            let state = live.status?.engineState ?? "unknown"
            if automation {
                _ = try? await ControlClient(socketPath: live.socketPath).send(ControlRequest(command: .automation, enabled: true))
                Out.line("\(config.id) is already supervised (pid \(live.pid), engine \(state)); automation mode turned on.")
                return
            }
            Out.line("\(config.id) is already supervised (pid \(live.pid), engine \(state)).")
            return
        }
        if let holder = registry.otherHolder(for: config.id) {
            throw CLIError("\(config.id) is governed by \(holder); close it there first (one governor per instance).")
        }
        if detach { return try await runDetached(ctx: ctx, config: config) }
        let options = supervisorOptions(for: config, paths: ctx.paths)
        if window {
            let code = try await WindowMode.run(ctx: ctx, config: config, options: options)
            if code != 0 { throw ExitCode(code) }
            return
        }
        let exit = try await Self.supervise(ctx: ctx, config: config, options: options, activity: SupervisorActivity())
        if exit.exitCode != 0 { throw ExitCode(exit.exitCode) }
    }

    /// Foreground supervision with SIGINT/SIGTERM handling. Returns how it ended.
    static func supervise(ctx: CLIContext, config: InstanceConfig, options: SupervisorOptions,
                          activity: SupervisorActivity) async throws -> SupervisorExit {
        let supervisor = Supervisor(config: config, ctx: ctx, options: options, activity: activity)
        let signals = SignalWatcher(signals: [SIGINT, SIGTERM, SIGHUP]) { sig in
            Task { await supervisor.requestShutdown(reason: "Signal \(sig)") }
        }
        defer { signals.cancel() }
        do {
            try await supervisor.boot()
        } catch {
            await supervisor.tearDown()
            throw error
        }
        let result = await supervisor.waitForExit()
        await supervisor.tearDown()
        switch result {
        case .stopped: Out.line("\(config.id) stopped.")
        case .detached: Out.line("Supervisor exited; \(config.id) is still running.")
        case .engineGone(let why), .failed(let why): Out.err("emuu: \(config.id): \(why)")
        }
        return result
    }

    private func runDetached(ctx: CLIContext, config: InstanceConfig) async throws {
        let registry = SupervisorRegistry(paths: ctx.paths)
        let me = Self.selfExecutable()
        let logURL = registry.logFile(for: config.id)
        let header = "\n=== emuu start --detach \(ISO8601DateFormatter().string(from: Date())) ===\n"
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(Data(header.utf8)); try? h.close()
        } else {
            try Data(header.utf8).write(to: logURL)
        }
        let child = try await SystemProcessRunner().spawn(ProcessRequest(
            executable: me, arguments: childArguments(id: config.id), workingDirectory: ctx.paths.root,
            stdin: Data(), stdout: .file(logURL), stderr: .file(logURL)))
        Out.err("Supervisor pid \(child.pid) starting \(config.id) in the background (log: \(logURL.path))…")
        let deadline = ContinuousClock.now + .seconds(bootTimeout + 60)
        var lastState = ""
        while ContinuousClock.now < deadline {
            if !child.isRunning {
                Out.endProgress()
                let tail = (try? String(contentsOf: logURL, encoding: .utf8))?.split(separator: "\n").suffix(15).joined(separator: "\n") ?? ""
                throw CLIError("supervisor exited during start (\(child.termination.map { "\($0)" } ?? "?")). Last log lines:\n\(tail)")
            }
            if let status = registry.readStatus(config.id), status.pid == child.pid {
                if status.engineState != lastState {
                    lastState = status.engineState
                    Out.progress("\(config.id): \(status.engineState)…")
                }
                if status.engineState == "running", status.serial != nil, registry.isLocked(config.id),
                   noGovernor || status.governor.enabled {
                    Out.endProgress()
                    Out.line("\(config.id) is running on \(status.serial!) (supervisor pid \(status.pid), \(status.governor.enabled ? "governor \(status.governor.profile)" : "no governor")).")
                    Out.line("Stop with `emuu stop \(config.id)`; follow with `emuu mem \(config.id)` or `emuu logs \(config.id) --supervisor -f`.")
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        Out.endProgress()
        throw CLIError("\(config.id) did not report running within \(bootTimeout + 60) s; the supervisor (pid \(child.pid)) is still trying. See \(logURL.path).")
    }

    static func selfExecutable() -> URL {
        if let url = Bundle.main.executableURL { return url.resolvingSymlinksInPath() }
        return URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    }
}

/// The guest RAM the engine really uses (see `EngineEffectiveRAM`; only accurate after the engine has
/// started with the current config, so the supervisor re-reads it after boot).
enum EffectiveRAM {
    static func megabytes(for config: InstanceConfig, paths: EmuuPaths) -> Int {
        EngineEffectiveRAM.megabytes(for: config, paths: paths)
    }
}

/// Turns POSIX signals into callbacks (the default action is disabled while active).
final class SignalWatcher: @unchecked Sendable {
    private var sources: [DispatchSourceSignal] = []
    private let count = Locked(0)

    init(signals: [Int32], handler: @escaping @Sendable (Int32) -> Void) {
        for sig in signals {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler { [count] in
                let n = count.withLock { c -> Int in c += 1; return c }
                if n >= 3 {
                    // Third signal: give up waiting (the engine is in its own process group and keeps running).
                    FileHandle.standardError.write(Data("\nemuu: forced exit; the engine may still be running (see `emuu status`)\n".utf8))
                    Darwin.exit(130)
                }
                handler(sig)
            }
            src.resume()
            sources.append(src)
        }
    }

    func cancel() {
        for s in sources { s.cancel() }
        sources.removeAll()
    }
}

// MARK: engine commands (routed through a supervisor when one runs)

/// Shared implementation of stop/freeze/thaw/hibernate/resume.
enum EngineCommand {
    enum Action: String, Sendable {
        case freeze, thaw, hibernate, resume, stop

        var controlCommand: ControlRequest.Command {
            switch self {
            case .freeze: return .freeze
            case .thaw: return .thaw
            case .hibernate: return .hibernate
            case .resume: return .resume
            case .stop: return .stop
            }
        }

        var timeout: Duration {
            switch self {
            case .freeze, .thaw: return .seconds(30)
            case .hibernate, .resume, .stop: return .seconds(240)
            }
        }
    }

    static func perform(_ action: Action, instance: String?, save: Bool = true, force: Bool = false) async throws {
        let ctx = try CLIContext.live()
        let config = try ctx.resolveInstance(instance)
        let id = config.id
        let t0 = ContinuousClock.now
        if let sup = SupervisorRegistry(paths: ctx.paths).liveSupervisor(for: id), !force {
            let reply = try await ControlClient(socketPath: sup.socketPath)
                .send(ControlRequest(command: action.controlCommand, save: save), timeout: action.timeout)
            guard reply.ok else { throw CLIError("\(action.rawValue) failed: \(reply.message ?? "unknown error")") }
            let state = reply.status?.engineState ?? "?"
            if action == .stop {
                // The supervisor replies before it tears down; wait (bounded) until it has exited and removed
                // its run files, so `list`/`status`/`start` right after `stop` see a consistent picture.
                let registry = SupervisorRegistry(paths: ctx.paths)
                let deadline = ContinuousClock.now + .seconds(15)
                while registry.liveSupervisor(for: id) != nil, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            Out.line("\(id): \(state) (\(action.rawValue) took \(Fmt.seconds(ContinuousClock.now - t0)) via supervisor pid \(sup.pid)).")
            return
        }
        let engine = try await ctx.engines.engine(for: id)
        let before = await engine.refresh()
        switch action {
        case .freeze: try await engine.freeze()
        case .thaw: try await engine.thaw()
        case .hibernate: try await engine.hibernate()
        case .resume:
            if before == .stopped || before == .hibernated || {
                if case .crashed = before { return true } else { return false }
            }() {
                Out.err("Note: no supervisor runs for \(id), so the memory governor is off. Prefer `emuu start \(id) --detach`.")
            }
            try await engine.resume()
        case .stop:
            if force {
                if let sup = SupervisorRegistry(paths: ctx.paths).liveSupervisor(for: id), sup.pid > 0 {
                    kill(sup.pid, SIGKILL)
                    SupervisorRegistry(paths: ctx.paths).cleanUp(id, socketPath: sup.socketPath)
                }
                try await engine.stop(.force)
            } else {
                try await engine.stop(.graceful(saveQuickBoot: save))
            }
        }
        Out.line("\(id): \(await engine.state()) (\(action.rawValue) took \(Fmt.seconds(ContinuousClock.now - t0))).")
    }
}

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop an instance (saves a quick-boot snapshot by default).")
    @OptionGroup var target: TargetInstance
    @Flag(help: "Do not keep the quick-boot snapshot; the next start cold-boots.")
    var noSnapshot = false
    @Flag(help: "SIGKILL the engine (and its supervisor). The quick-boot snapshot is discarded.")
    var force = false

    func run() async throws {
        try await EngineCommand.perform(.stop, instance: target.explicit, save: !noSnapshot, force: force)
    }
}

struct Freeze: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Pause the engine (T4, SIGSTOP): 0% CPU, memory stays allocated; adb hangs until thawed.")
    @OptionGroup var target: TargetInstance
    func run() async throws { try await EngineCommand.perform(.freeze, instance: target.explicit) }
}

struct Thaw: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Continue a frozen engine.")
    @OptionGroup var target: TargetInstance
    func run() async throws { try await EngineCommand.perform(.thaw, instance: target.explicit) }
}

struct Hibernate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Save a quick-boot snapshot and quit the engine (T5): all host memory returned; `resume` takes ~2 s.")
    @OptionGroup var target: TargetInstance
    func run() async throws { try await EngineCommand.perform(.hibernate, instance: target.explicit) }
}

struct Resume: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Resume a hibernated (or frozen) instance.")
    @OptionGroup var target: TargetInstance
    func run() async throws { try await EngineCommand.perform(.resume, instance: target.explicit) }
}

// MARK: status

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show instance state and a live memory line.")
    @OptionGroup var target: TargetInstance
    @Flag(help: "Show every instance.")
    var all = false
    @Flag(help: "JSON output.")
    var json = false

    struct Row: Codable, Sendable {
        var instance: String
        var state: String
        var serial: String?
        var enginePID: Int32?
        var supervisorPID: Int32?
        var governor: String?
        var memory: MemoryReading?
        var automationMode: Bool?
        /// Ready-to-paste adb command for this instance.
        var adbHint: String?
    }

    func run() async throws {
        let ctx = try CLIContext.live()
        let configs = all ? ctx.store.list() : [try ctx.resolveInstance(target.explicit)]
        var rows: [Row] = []
        for config in configs {
            var row = try await Self.row(ctx: ctx, config: config)
            row.automationMode = config.isAutomationMode
            if let serial = row.serial, row.state.hasPrefix("running") || row.state.hasPrefix("frozen") {
                row.adbHint = Self.adbHint(serial: serial)
            }
            rows.append(row)
        }
        if json { return try Out.json(all ? AnyCodableRows.many(rows) : AnyCodableRows.one(rows[0])) }
        for r in rows {
            var head = "\(r.instance): \(r.state)"
            if let s = r.serial { head += " on \(s)" }
            if let p = r.enginePID { head += ", engine pid \(p)" }
            head += r.supervisorPID.map { ", supervisor pid \($0)" } ?? ", no supervisor"
            if let g = r.governor { head += ", governor \(g)" }
            if r.automationMode == true { head += ", automation mode" }
            Out.line(head)
            if let m = r.memory { Out.line("  " + m.line) }
            if let hint = r.adbHint { Out.line("  adb: \(hint)") }
        }
    }

    /// `adb -s emulator-5554 shell` (pure; unit-tested).
    static func adbHint(serial: String) -> String { "adb -s \(serial) shell" }

    static func row(ctx: CLIContext, config: InstanceConfig) async throws -> Row {
        let id = config.id
        if let sup = SupervisorRegistry(paths: ctx.paths).liveSupervisor(for: id),
           let reply = try? await ControlClient(socketPath: sup.socketPath).send(ControlRequest(command: .status), timeout: .seconds(5)),
           let st = reply.status {
            var reading = MemoryReading(point: st.lastSample)
            if reading == nil || st.engineState != "running" {
                reading = await MemoryReading.sample(ctx: ctx, enginePID: st.enginePID, serial: nil)
            }
            let g = st.governor
            var gov = g.enabled ? "\(g.profile) level \(g.level), tier \(g.tier), \(g.actionsApplied) actions" + (g.creepActive ? ", creep detected" : "") : "off"
            if let h = st.selfHeal, h.enabled {
                gov += "; self-heal \(h.failed ? "GAVE UP" : "on")" + (h.lastVerdict.map { ", last check \($0)" } ?? "")
                    + (h.recoveries > 0 ? ", \(h.recoveries) recoveries" : "")
            }
            return Row(instance: id.rawValue, state: st.engineStateDetail, serial: st.serial, enginePID: st.enginePID,
                       supervisorPID: st.pid, governor: gov, memory: reading)
        }
        let engine = try await ctx.engines.engine(for: id)
        let state = await engine.refresh()
        let pid = await engine.enginePID()
        let serial = await engine.serial()
        let reading = state.isRunningEngine ? await MemoryReading.sample(ctx: ctx, enginePID: pid, serial: state == .running ? serial : nil) : nil
        return Row(instance: id.rawValue, state: state.description, serial: serial?.rawValue, enginePID: pid,
                   supervisorPID: nil, governor: SupervisorRegistry(paths: ctx.paths).otherHolder(for: id).map { "run by \($0)" },
                   memory: reading)
    }
}

/// JSON shape helper: one object for a single instance, an array for --all.
enum AnyCodableRows: Encodable {
    case one(Status.Row)
    case many([Status.Row])

    func encode(to encoder: Encoder) throws {
        switch self {
        case .one(let r): try r.encode(to: encoder)
        case .many(let rs): try rs.encode(to: encoder)
        }
    }
}

/// A point-in-time memory reading for display.
struct MemoryReading: Codable, Sendable, Hashable {
    var guestTotalBytes: UInt64?
    var guestAvailableBytes: UInt64?
    var guestSwapUsedBytes: UInt64?
    var engineFootprintBytes: UInt64?
    var enginePeakFootprintBytes: UInt64?
    var engineCPUPercent: Double?
    var hostPressure: MemoryPressureLevel?
    var sampledAt: Date

    init?(point: HistoryPoint?) {
        guard let p = point else { return nil }
        guestTotalBytes = p.guestTotalBytes
        guestAvailableBytes = p.guestAvailableBytes
        guestSwapUsedBytes = p.guestSwapUsedBytes
        engineFootprintBytes = p.engineFootprintBytes
        enginePeakFootprintBytes = p.engineLifetimeMaxFootprintBytes
        engineCPUPercent = p.engineCPUPercent
        hostPressure = p.hostPressure
        sampledAt = p.timestamp
    }

    init(sampledAt: Date) { self.sampledAt = sampledAt }

    var line: String {
        Fmt.memoryLine(guestTotal: guestTotalBytes, guestAvailable: guestAvailableBytes, engineFootprint: engineFootprintBytes,
                       enginePeak: enginePeakFootprintBytes, cpuPercent: engineCPUPercent, hostPressure: hostPressure,
                       swapUsed: guestSwapUsedBytes)
    }

    /// Host stats from syscalls; guest stats over adb when `serial` is given (one shell round trip).
    static func sample(ctx: CLIContext, enginePID: Int32?, serial: DeviceSerial?) async -> MemoryReading {
        var r = MemoryReading(sampledAt: Date())
        let host = HostSampler().sample(enginePID: enginePID)
        r.engineFootprintBytes = host.engine?.footprintBytes
        r.enginePeakFootprintBytes = host.engine?.lifetimeMaxFootprintBytes
        r.hostPressure = host.system.pressure
        if let serial, let snap = try? await GuestSampler(shell: ADBClient(serial: serial, server: ctx.adbServer())).sample() {
            r.guestTotalBytes = snap.memory.totalBytes
            r.guestAvailableBytes = snap.memory.availableBytes
            r.guestSwapUsedBytes = snap.memory.swapUsedBytes
        }
        return r
    }
}
