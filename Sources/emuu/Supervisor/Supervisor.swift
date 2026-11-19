import Darwin
import Foundation
import EmuuBase
import EmuuEngine
import EmuuADB
import EmuuMemory

/// How a supervisor run should look.
struct SupervisorOptions: Sendable {
    enum Mode: String, Sendable { case headless, window }

    var mode: Mode = .headless
    var governorEnabled = true
    var governor: GovernorOptions
    var launch = EngineLaunchOptions()
    /// Print state changes, tier changes, actions and (unless quiet) each sample to stdout.
    var echo = true
    var quiet = false
}

/// Why a supervisor ended.
enum SupervisorExit: Sendable, Equatable {
    case stopped          // engine stopped on request (signal or `emuu stop`)
    case detached         // supervisor left, engine still running
    case engineGone(String)
    case failed(String)

    var exitCode: Int32 {
        switch self {
        case .stopped, .detached: return 0
        case .engineGone, .failed: return 1
        }
    }
}

/// Runs one instance: owns (or adopts) the engine, drives the memory governor, publishes
/// `run/<id>.supervisor.json` and answers control requests on `run/<id>.sock`.
actor Supervisor {
    let config: InstanceConfig
    let ctx: CLIContext
    private(set) var options: SupervisorOptions
    let registry: SupervisorRegistry
    let activity: SupervisorActivity
    private let log: EmuuLogger

    private var engine: EngineInstance?
    private var bundle: GovernorBundle?
    private var shell: FollowingShell?
    private var server: ControlServer?
    private var lock: FileLock?
    private var socketPath: String
    private var ownsEngine = false
    private var startedAt = Date()
    private var lastEventText: String?
    private var tasks: [Task<Void, Never>] = []

    static let supervisorLogLimit: UInt64 = 4 * 1024 * 1024

    private var events: [SequencedEvent] = []
    private var nextSeq: UInt64 = 1
    private static let eventCapacity = 512

    private var exitContinuation: CheckedContinuation<SupervisorExit, Never>?
    private var pendingExit: SupervisorExit?
    private var shuttingDown = false

    init(config: InstanceConfig, ctx: CLIContext, options: SupervisorOptions, activity: SupervisorActivity) {
        self.config = config
        self.ctx = ctx
        self.options = options
        self.registry = SupervisorRegistry(paths: ctx.paths)
        self.activity = activity
        self.socketPath = SupervisorRegistry(paths: ctx.paths).socketPath(for: config.id)
        self.log = EmuuLogger(category: "cli.supervisor.\(config.id.rawValue)")
    }

    var id: InstanceID { config.id }

    // MARK: lifecycle

    /// Phase 1: claim the instance, publish the socket, boot (or adopt) the engine, start the governor.
    /// Throws when the instance is already supervised or the engine fails to boot.
    func boot() async throws {
        guard let lock = try FileLock(url: registry.lockFile(for: id)) else {
            let holder = registry.liveSupervisor(for: id).map { "a supervisor (pid \($0.pid))" } ?? registry.otherHolder(for: id) ?? "another process"
            throw CLIError("\(id) is already governed by \(holder); only one governor may run per instance. Use `emuu status \(id)`.")
        }
        self.lock = lock
        startedAt = Date()
        try "\(getpid())\n".write(to: registry.pidFile(for: id), atomically: true, encoding: .utf8)
        server = try ControlServer(socketPath: socketPath) { [weak self] request in
            guard let self else { return .failure("supervisor is shutting down") }
            return await self.handle(request)
        }

        let engine = try await ctx.engines.engine(for: id)
        self.engine = engine
        let initial = await engine.refresh()
        ownsEngine = !initial.isRunningEngine
        writeStatus()
        echo(initial.isRunningEngine
             ? "Adopting running engine for \(id) (pid \(await engine.enginePID().map(String.init) ?? "?")); it keeps running when this supervisor exits."
             : "Starting \(id) (\(EffectiveRAM.megabytes(for: config, paths: ctx.paths)) MB, \(config.cores) cores, \(initial == .hibernated ? "resume from hibernation" : options.launch.coldBoot ? "cold boot" : "quick boot if possible"))…")

        tasks.append(Task { [weak self] in
            for await state in await engine.stateUpdates() {
                await self?.engineStateChanged(state)
            }
        })
        let t0 = ContinuousClock.now
        do {
            if initial == .frozen {
                try await engine.thaw()
            } else {
                try await engine.start(options.launch)
            }
        } catch {
            writeStatus()
            throw CLIError("\(id) failed to start: \(describe(error)). Engine log: \(ctx.paths.engineLogFile(for: id).path)")
        }
        let bootTime = ContinuousClock.now - t0
        guard let serial = await engine.serial() else { throw CLIError("\(id) booted without an adb serial") }
        let effectiveRAM = EffectiveRAM.megabytes(for: config, paths: ctx.paths)
        echo("\(id) is running on \(serial) (ready in \(Fmt.seconds(bootTime)); guest RAM \(effectiveRAM) MB\(effectiveRAM != config.ramMB ? ", raised by the engine from \(config.ramMB) MB" : "")).")
        activity.noteInteraction()

        let shell = FollowingShell(serial: serial, server: ctx.adbServer())
        self.shell = shell
        // The engine writes the RAM it really uses (it may raise the configured size) at launch, so size the
        // governor's footprint budget from it now; before the first boot it was only the configured value.
        options.governor.guestRAMMB = EffectiveRAM.megabytes(for: config, paths: ctx.paths)
        if options.governorEnabled {
            let csv = SampleCSVLog(url: registry.samplesFile(for: id))
            let bundle = GovernorFactory.make(instanceID: id, options: options.governor, engine: engine, shell: shell,
                                              activity: activity, csv: csv)
            self.bundle = bundle
            let stream = await bundle.governor.events()
            tasks.append(Task { [weak self] in
                for await event in stream { await self?.record(event) }
            })
            await bundle.governor.start()
            let gc = options.governor.config()
            if options.governor.automation { echo("Automation mode on: the governor never freezes or hibernates \(id) and only trims/kills background apps.") }
            echo("Memory governor on (profile \(options.governor.profile.rawValue); idle freeze \(gc.freezeWhenHiddenAfter.map { "after \(Fmt.uptime($0.timeInterval))" } ?? "off"); samples → \(registry.samplesFile(for: id).path)).")
        } else {
            echo("Memory governor off (--no-governor).")
        }
        let supervisorLog = registry.logFile(for: id)
        tasks.append(Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self?.writeStatus()
                ticks += 1
                // A detached supervisor's stdout/stderr is an O_APPEND file that only grows; cap it in place.
                if ticks % 60 == 0 { LogFileCap.capInPlace(supervisorLog, limit: Self.supervisorLogLimit) }
            }
        })
        writeStatus()
    }

    /// Phase 2: waits until a stop/detach request, a signal or the engine going away.
    func waitForExit() async -> SupervisorExit {
        if let pendingExit { return pendingExit }
        return await withCheckedContinuation { exitContinuation = $0 }
    }

    private func finish(_ exit: SupervisorExit) {
        if let c = exitContinuation {
            exitContinuation = nil
            c.resume(returning: exit)
        } else if pendingExit == nil {
            pendingExit = exit
        }
    }

    /// SIGINT/SIGTERM or the window closing: stop the engine if this supervisor launched it, else leave it running.
    func requestShutdown(reason: String) async {
        guard !shuttingDown else { return }
        if ownsEngine {
            echo("\n\(reason): saving quick-boot snapshot and stopping \(id)…")
            let reply = await stopEngine(save: true)
            if !reply.ok { echo(reply.message ?? "stop failed") }
            finish(reply.ok ? .stopped : .failed(reply.message ?? "stop failed"))
        } else {
            echo("\n\(reason): leaving the adopted engine running.")
            finish(.detached)
        }
    }

    func engineControl() -> EngineInstance? { engine }

    /// Phase 3: stops the governor and removes the published files.
    func tearDown() async {
        shuttingDown = true
        if let bundle { await bundle.governor.stop() }
        for t in tasks { t.cancel() }
        tasks.removeAll()
        server?.close()
        server = nil
        registry.cleanUp(id, socketPath: socketPath)
        lock?.release()
        lock = nil
    }

    private func stopEngine(save: Bool) async -> ControlReply {
        guard let engine else { return .failure("no engine") }
        shuttingDown = true
        if let bundle { await bundle.governor.stop() }
        do {
            try await engine.stop(.graceful(saveQuickBoot: save))
            await refreshCaches()
            writeStatus()
            return ControlReply(ok: true, message: "\(id) stopped\(save ? " (quick-boot snapshot saved)" : "")", status: currentStatus())
        } catch {
            shuttingDown = false
            // The engine may still be running: keep governing it (the governor was stopped above).
            let state = await engine.state()
            if let bundle, state.isRunningEngine || state == .hibernated {
                await bundle.governor.start()
            }
            return .failure("stop failed: \(describe(error))")
        }
    }

    /// Set once the engine has been up under this supervisor; before that, `stopped` is just the
    /// initial state reported by `stateUpdates()`.
    private var engineWasUp = false

    private func engineStateChanged(_ state: InstanceState) async {
        if state.isRunningEngine { engineWasUp = true }
        if state == .running, let serial = await engine?.serial() { shell?.follow(serial) }
        writeStatus()
        if !shuttingDown { echo("[\(Fmt.time(Date()))] engine \(state)") }
        switch state {
        case .crashed(let reason):
            guard !shuttingDown, engineWasUp else { return }
            finish(.engineGone("engine crashed: \(reason)"))
        case .stopped:
            guard !shuttingDown, engineWasUp else { return }
            finish(.engineGone("engine stopped outside this supervisor"))
        default:
            break
        }
    }

    // MARK: events

    private func record(_ event: GovernorEvent) {
        events.append(SequencedEvent(seq: nextSeq, event: event))
        nextSeq += 1
        if events.count > Self.eventCapacity { events.removeFirst(events.count - Self.eventCapacity) }
        let text = EventText.render(event)
        if case .sampled = event.kind {
            if !options.quiet { echo(text) }
        } else {
            lastEventText = text
            echo(text)
            writeStatus()
        }
    }

    private func echo(_ text: String) {
        log.info(text)
        if options.echo { Out.line(text) }
    }

    // MARK: status

    private var cachedState: InstanceState = .stopped
    private var cachedPID: Int32?
    private var cachedSerial: DeviceSerial?
    private var cachedGovernor: GovernorStatus?
    private var cachedVisible = false

    private func refreshCaches() async {
        if let engine {
            cachedState = await engine.state()
            cachedPID = await engine.enginePID()
            cachedSerial = await engine.serial()
        }
        if let bundle { cachedGovernor = await bundle.governor.status() }
        cachedVisible = await activity.isDisplayVisible(id)
    }

    private func writeStatus() {
        Task { [weak self] in await self?.writeStatusNow() }
    }

    private func writeStatusNow() async {
        guard !(shuttingDown && server == nil) else { return }
        await refreshCaches()
        do { try registry.writeStatus(currentStatus(), for: id) } catch { log.warning("status write failed: \(error)") }
    }

    func currentStatus() -> SupervisorStatus {
        let gc = options.governor.config()
        let g = cachedGovernor
        return SupervisorStatus(
            instanceID: id.rawValue, pid: getpid(), mode: options.mode.rawValue, startedAt: startedAt, updatedAt: Date(),
            socketPath: socketPath, ownsEngine: ownsEngine, visible: cachedVisible,
            engineState: cachedState.keyword, engineStateDetail: cachedState.description,
            enginePID: cachedPID, serial: cachedSerial?.rawValue,
            governor: .init(enabled: bundle != nil, profile: options.governor.profile.rawValue,
                            level: g?.level.description ?? "-", tier: g?.tier.description ?? "-", tierNumber: g?.tier.rawValue ?? 0,
                            disabledTiers: (g?.disabledTiers ?? []).sorted().map(\.description), creepActive: g?.creepActive ?? false,
                            samplesTaken: g?.samplesTaken ?? 0, actionsApplied: g?.actionsApplied ?? 0, actionsFailed: g?.actionsFailed ?? 0,
                            maintenanceRuns: g?.maintenanceRuns ?? 0, consecutiveGuestSampleFailures: g?.consecutiveGuestSampleFailures ?? 0,
                            freezeWhenHiddenAfterSeconds: gc.automationMode ? nil : gc.freezeWhenHiddenAfter?.timeInterval,
                            hibernateWhenFrozenAfterSeconds: gc.automationMode ? nil : gc.hibernateWhenFrozenAfter?.timeInterval,
                            automationMode: gc.automationMode,
                            adbActivitySecondsAgo: g?.lastADBActivity.map { (SystemClock().monotonicNow() - $0).timeInterval }),
            lastSample: g?.lastSample, lastEvent: lastEventText)
    }

    // MARK: control requests

    func handle(_ request: ControlRequest) async -> ControlReply {
        guard let engine else { return .failure("supervisor is still starting") }
        if shuttingDown, request.command != .status, request.command != .events {
            return .failure("supervisor is shutting down")
        }
        do {
            switch request.command {
            case .status:
                break
            case .touch:
                activity.noteInteraction()
                bundle?.governor.nudge()
            case .automation:
                guard let enabled = request.enabled else { return .failure("automation needs `enabled`") }
                options.governor.automation = enabled
                if let bundle { await bundle.governor.updateConfig(options.governor.config()) }
                activity.noteInteraction()
                echo("[\(Fmt.time(Date()))] automation mode \(enabled ? "on: no freeze/hibernate, background trims only" : "off")")
            case .visibility:
                activity.setVisible(request.visible)
                bundle?.governor.nudge()
            case .wake:
                activity.noteInteraction()
                switch await engine.refresh() {
                case .frozen: try await engine.thaw()
                case .hibernated: try await engine.resume()
                case .booting: try await engine.waitForBoot(timeout: .seconds(600))
                default: break
                }
                bundle?.governor.nudge()
            case .freeze:
                try await engine.freeze()
                bundle?.governor.nudge()
            case .thaw:
                activity.noteInteraction()
                try await engine.thaw()
                bundle?.governor.nudge()
            case .hibernate:
                try await engine.hibernate()
                bundle?.governor.nudge()
            case .resume:
                activity.noteInteraction()
                try await engine.resume()
                bundle?.governor.nudge()
            case .stop:
                let reply = await stopEngine(save: request.save ?? true)
                if reply.ok { finishSoon(.stopped) }
                return reply
            case .detach:
                finishSoon(.detached)
                await refreshCaches()
                return ControlReply(ok: true, message: "supervisor detaching; engine left running", status: currentStatus())
            case .trim:
                guard let bundle else { return .failure("governor is off (--no-governor); use `emuu mem trim` without a supervisor") }
                activity.noteInteraction()
                let reports = await ManualTiers.trim(guest: bundle.guest, level: request.level ?? .moderate, kill: request.kill ?? false,
                                                   caches: request.cachesBytes)
                return ControlReply(ok: true, reports: reports)
            case .reclaim:
                guard let bundle else { return .failure("governor is off (--no-governor)") }
                let reports = await ManualTiers.reclaim(guest: bundle.guest, engine: bundle.engineEffector)
                return ControlReply(ok: true, reports: reports)
            case .events:
                let since = request.since ?? 0
                await refreshCaches()
                return ControlReply(ok: true, status: currentStatus(), events: events.filter { $0.seq > since }, nextSeq: nextSeq)
            }
        } catch {
            await refreshCaches()
            return ControlReply(ok: false, message: describe(error), status: currentStatus())
        }
        await refreshCaches()
        writeStatus()
        return ControlReply(ok: true, status: currentStatus())
    }

    /// Lets the reply reach the client before the process ends.
    private func finishSoon(_ exit: SupervisorExit) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            await self?.finish(exit)
        }
    }
}

/// One-line renderings of governor events (shared by the supervisor's echo and `emuu mem`).
enum EventText {
    static func render(_ event: GovernorEvent) -> String {
        let t = Fmt.time(event.timestamp)
        switch event.kind {
        case .sampled(let s):
            return "[\(t)] sample  " + Fmt.memoryLine(guestTotal: s.guest?.totalBytes, guestAvailable: s.guest?.availableBytes,
                                                     engineFootprint: s.host?.engineFootprintBytes, enginePeak: nil, cpuPercent: nil,
                                                     hostPressure: s.host?.systemPressure, swapUsed: s.guest?.swapUsedBytes)
        case .tierChanged(let from, let to, let reason):
            return "[\(t)] tier    \(from) → \(to) (\(reason))"
        case .actionPlanned(let action, let reason):
            return "[\(t)] plan    \(action) (\(reason))"
        case .actionApplied(let action, let outcome):
            var s = "[\(t)] action  \(action) → \(outcome.status.rawValue)"
            if !outcome.detail.isEmpty { s += ": \(outcome.detail)" }
            if let b = outcome.reclaimedBytes { s += " (+\(ByteCount.format(b)) guest available)" }
            return s
        case .actionFailed(let action, let message):
            return "[\(t)] failed  \(action): \(message)"
        case .creepDetected(let perHour, let window):
            return "[\(t)] creep   \(ByteCount.format(signed: perHour))/h over \(Fmt.uptime(window.timeInterval))"
        case .stateChanged(let state):
            return "[\(t)] state   \(state)"
        case .maintenanceRan(let summary):
            return "[\(t)] maint   \(summary)"
        case .guestRebooted(let uptime, let recent):
            return "[\(t)] REBOOT  guest restarted (uptime \(Fmt.uptime(uptime.timeInterval))); last actions: \(recent.isEmpty ? "none" : recent.joined(separator: " | "))"
        }
    }
}
