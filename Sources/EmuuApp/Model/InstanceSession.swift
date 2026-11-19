import AppKit
import Foundation
import Observation
import EmuuBase
import EmuuEngine
import EmuuADB
import EmuuMemory
import EmuuDisplay
import EmuuGRPC

/// One entry in the memory HUD's action timeline.
struct TimelineEntry: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case info, action, warning, error }
    let id: UInt64
    let date: Date
    let kind: Kind
    let text: String
}

/// State of a drag-and-drop / menu install.
struct InstallJob: Identifiable, Hashable {
    enum Status: Hashable {
        case running(stage: String, fraction: Double?)
        case succeeded(String)
        case failed(String)
    }
    let id = UUID()
    let fileName: String
    var status: Status
}

/// Everything the app holds for one attached instance: engine controller, adb client, display pipeline,
/// memory governor, HUD data and install jobs. Lives independently of its window, so closing and reopening
/// the window reuses it; `detach()` releases every resource (tasks, gRPC connection, governor).
///
/// Memory discipline: no frame buffers are kept here (the display layer owns the only frame), the timeline
/// is capped at `timelineCapacity`, the governor's history is a fixed ring buffer and is never copied
/// wholesale (only `status().lastSample` is read).
@MainActor
@Observable
final class InstanceSession: Identifiable {
    enum Phase: Equatable {
        /// Booting, resuming or (re)building the display pipeline.
        case working(String)
        /// Engine running, display pipeline built.
        case ready
        /// Engine hibernated or stopped while the session stays attached. Shown only briefly: a shutdown or
        /// hibernation closes the window (see `WindowAutoClosePolicy`); an exit seen from outside is shown here
        /// while it is confirmed not to be a restart.
        case parked(InstanceState)
        case failed(String)
    }

    nonisolated let id: InstanceID
    let config: InstanceConfig
    private(set) var phase: Phase = .working("Connecting…")
    private(set) var engineState: InstanceState = .stopped
    private(set) var display: EmulatorDisplayController?
    private(set) var client: ADBClient?
    /// False when another Emuu process (e.g. the CLI) already governs this instance.
    private(set) var governsMemory = false
    private(set) var otherGovernorOwner: InstanceRunState?
    /// pid of the `emuu run` supervisor that governs this instance (the app is then display-only).
    private(set) var cliSupervisorPID: Int32?
    /// Governor summary published by the CLI supervisor (level/tier/profile), when supervised.
    private(set) var cliGovernorSummary: String?
    private(set) var profile: MemoryProfile
    private(set) var latestSample: HistoryPoint?
    private(set) var governorStatus: GovernorStatus?
    private(set) var timeline: [TimelineEntry] = []
    private(set) var installJobs: [InstallJob] = []
    private(set) var toast: String?
    private(set) var reclaimInProgress = false
    /// Whether this session started the engine (vs. attaching to one started by the CLI / a previous run).
    private(set) var startedEngine = false
    /// Sheets/popovers of this instance's window (shared with the menu commands).
    let ui = WindowUIState()
    /// Automation mode (instance setting): no freeze/hibernate, background trims only.
    private(set) var automationMode: Bool
    /// Show Android's soft keyboard for text fields (instance setting).
    private(set) var softKeyboardEnabled: Bool
    /// A keyboard show/hide is running on the device.
    private(set) var keyboardBusy = false
    /// Recording state mirrored from the display controller (for the strip).
    private(set) var recordingStartedAt: Date?
    private(set) var recordingBusy = false
    /// File the last toast refers to ("Show in Finder").
    private(set) var toastRevealURL: URL?

    static let timelineCapacity = 80

    @ObservationIgnored private let env: EngineEnvironment
    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var engine: EngineInstance?
    @ObservationIgnored private var governor: MemoryGovernor?
    @ObservationIgnored private var engineWatch: Task<Void, Never>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var displayWanted = false
    @ObservationIgnored private var displayStarting = false
    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    @ObservationIgnored private var nextTimelineID: UInt64 = 0
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var governorLock: GovernorLock?
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var cachedEnginePID: Int32?
    @ObservationIgnored private var visibilitySeq: UInt64 = 0
    /// Set once the session is being finished/detached: in-flight boots must not build a pipeline.
    @ObservationIgnored private var isClosing = false
    @ObservationIgnored private var cliLink: CLISupervisorLink?
    /// While display-only under a CLI supervisor: re-sends visibility (the supervisor expires it after 60 s)
    /// and takes over governing if the supervisor goes away.
    @ObservationIgnored private var cliLinkTask: Task<Void, Never>?
    @ObservationIgnored private var lastTouchSent: ContinuousClock.Instant?
    @ObservationIgnored private var keyboardEnforceTask: Task<Void, Never>?
    /// Last tap on the device screen (device pixels): re-tapped to bring the keyboard back.
    @ObservationIgnored private(set) var lastTap: (x: Int, y: Int)?
    @ObservationIgnored private var prefsTask: Task<Void, Never>?
    @ObservationIgnored private var recordingKeepAliveTask: Task<Void, Never>?
    /// Called once when the engine was shut down or hibernated on purpose: the app closes this session's window
    /// and detaches it (without applying the window-close choice). Set by `AppModel`.
    @ObservationIgnored var onEngineEnded: (@MainActor (InstanceSession, String) -> Void)?
    /// The pipeline was built at least once (a later stop is a shutdown, not a failed start).
    @ObservationIgnored private var wasUp = false
    /// "Restart Engine" is hibernating and resuming the engine: its exit must not close the window.
    @ObservationIgnored private var restartingEngine = false
    /// This window asked a CLI supervisor to hibernate (that exit looks external but is intentional).
    @ObservationIgnored private var exitRequestedHere = false
    /// Confirms an exit seen from outside (see `WindowAutoClosePolicy.confirm`).
    @ObservationIgnored private var exitCheckTask: Task<Void, Never>?
    @ObservationIgnored private(set) var endReported = false
    /// The engine's last exit, reported as a crash, was Android powering off (see `WindowAutoClosePolicy`).
    @ObservationIgnored private var crashWasShutdown = false
    /// Live-object counters for the self-test's retention check.
    nonisolated(unsafe) static var liveCount = 0
    @ObservationIgnored private let log: EmuuLogger

    init(config: InstanceConfig, env: EngineEnvironment, services: AppServices, settings: AppSettings) {
        self.id = config.id
        self.config = config
        self.env = env
        self.services = services
        self.settings = settings
        self.profile = settings.profile(for: config.id, default: config.memoryProfile)
        self.automationMode = config.isAutomationMode
        self.softKeyboardEnabled = config.softKeyboardEnabled
        self.log = EmuuLogger(category: "app.session.\(config.id.rawValue)")
        Self.liveCount += 1
    }

    isolated deinit { Self.liveCount -= 1 }

    var displayName: String { config.displayName.isEmpty ? id.rawValue : config.displayName }

    // MARK: Attach / boot

    /// Starts (or adopts) the engine, waits for Android, then builds the adb client, display and governor.
    /// Starts `open` in the background; `finish`/`detach` wait for it so nothing is built after closing.
    func begin(coldBoot: Bool = false) {
        guard openTask == nil else { return }
        openTask = Task { [weak self] in
            await self?.open(coldBoot: coldBoot)
        }
    }

    func open(coldBoot: Bool = false) async {
        do {
            let engine = try await env.engine(for: id)
            self.engine = engine
            watchEngine(engine)
            var state = await engine.refresh()
            engineState = state
            let link = CLISupervisorLink(id: id, paths: env.paths)
            if state == .hibernated, link.isLive() {
                // Hibernated under a CLI supervisor (its window closed then): let the supervisor resume it, so it
                // keeps governing the engine; starting it from here would leave the supervisor thinking it is
                // still hibernated. Falls back to starting it here below.
                phase = .working("Resuming from hibernation…")
                let r = await link.sendAsync(["command": "wake"], timeout: 180)
                if !r.ok { log.warning("wake via supervisor failed: \(r.message ?? "?"); starting the engine here") }
                state = await engine.refresh()
            }
            switch state {
            case .running:
                break
            case .frozen:
                phase = .working("Thawing…")
                try await engine.thaw()
            case .booting:
                phase = .working("Booting Android…")
                try await engine.waitForBoot(timeout: .seconds(600))
            case .stopped, .hibernated, .crashed:
                phase = .working(state == .hibernated ? "Resuming from hibernation…" : "Booting Android…")
                startedEngine = true
                try await engine.start(EngineLaunchOptions(coldBoot: coldBoot))
            case .stopping, .hibernating:
                phase = .working("Waiting for the engine to finish \(state)…")
                state = try await waitWhileTransitioning(engine)
                if !state.isRunningEngine {
                    startedEngine = true
                    try await engine.start(EngineLaunchOptions(coldBoot: coldBoot))
                }
            }
            try await buildPipeline(engine: engine)
        } catch {
            fail(error)
        }
    }

    private func waitWhileTransitioning(_ engine: EngineInstance) async throws -> InstanceState {
        for _ in 0..<240 {
            let s = await engine.refresh()
            if s != .stopping && s != .hibernating { return s }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw EmuuError.engine("engine stayed in a transitional state for 2 minutes")
    }

    /// Builds adb client, display and governor for the engine's current serial. Re-run after a resume that
    /// changed ports.
    private func buildPipeline(engine: EngineInstance) async throws {
        guard !isClosing else { return }
        guard let serial = await engine.serial() else {
            let state = await engine.state()
            throw EmuuError.engine("\(id) has no adb serial (state \(state))")
        }
        await teardownPipeline()
        guard !isClosing else { return }
        phase = .working("Connecting display…")
        let client = ADBClient(serial: serial, server: services.adbServer)
        self.client = client

        // The engine's own framebuffer/input over its gRPC service (endpoint re-read on every reconnect: a
        // resume or restart gives the engine a new pid, port and token).
        let native = EmulatorDisplaySession(endpoint: { [weak engine] in
            guard let pid = await engine?.enginePID() else { return nil }
            return EmulatorDiscovery.endpoint(forPID: pid)
        })
        let controller = EmulatorDisplayController(session: native, instanceID: id, activityTracker: services.activity)
        interposeVisibility(controller)
        controller.view.onPointerUp = { [weak self] x, y in self?.pointerUp(x: x, y: y) }
        controller.view.onFileDrop = { [weak self] urls in self?.install(urls: urls) }
        controller.view.onDropTargeted = { [weak self] t in self?.ui.dropTargeted = t }
        display = controller

        // Exactly one governor per instance: another app process (frontend.json), a CLI supervisor (its
        // flock), or us (we take that same flock so `emuu run` will not start a second one).
        let link = CLISupervisorLink(id: id, paths: env.paths)
        otherGovernorOwner = nil
        cliLink = nil
        cliSupervisorPID = nil
        if let other = RunStateStore.otherGovernor(of: id, paths: env.paths) {
            otherGovernorOwner = other
            note(.warning, "Memory governor is run by Emuu pid \(other.ownerPID); this window is display-only")
        } else if link.isLive() {
            cliLink = link
            cliSupervisorPID = link.supervisorPID
            note(.info, "Governed by the emuu CLI supervisor (pid \(cliSupervisorPID.map(String.init) ?? "?")); window sends visibility hints")
            watchCLILink(link, engine: engine, shell: client)
        } else {
            governorLock = GovernorLock(url: link.lockURL)
            if governorLock == nil { log.warning("could not take \(link.lockURL.lastPathComponent); governing anyway") }
            startGovernor(engine: engine, shell: client)
        }
        cachedEnginePID = await engine.enginePID()
        phase = .ready
        wasUp = true
        exitRequestedHere = false
        writeRunState()
        watchPreferences()
        // Keep Android's "use on-screen keyboard" setting in line with the instance preference.
        // Auto-rotate on, so apps follow the Rotate button (the engine rotates the virtual device's sensors).
        let showKeyboard = softKeyboardEnabled
        Task {
            _ = try? await client.shell(SoftKeyboardCommands.setting(show: showKeyboard) + "; " + Self.autoRotateCommand,
                                        timeout: .seconds(10))
        }
        if displayWanted { await startDisplay() }
        log.info("attached to \(id) on \(serial)")
    }

    /// Every 20 s while display-only: if the supervisor's lock is free (it was stopped, detached, killed or
    /// crashed while the engine kept running), take the lock and govern from here; otherwise refresh the
    /// visibility hint so the supervisor's 60 s expiry does not treat a visible window as hidden.
    private func watchCLILink(_ link: CLISupervisorLink, engine: EngineInstance, shell: ADBClient) {
        cliLinkTask?.cancel()
        cliLinkTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self, self.cliLink != nil else { return }
                if !link.isLive() {
                    self.takeOverGovernance(from: link, engine: engine, shell: shell)
                    return
                }
                if self.display?.isVisible == true || self.display?.isRecording == true {
                    _ = await link.sendAsync(["command": "visibility", "visible": true])
                }
            }
        }
    }

    private func takeOverGovernance(from link: CLISupervisorLink, engine: EngineInstance, shell: ADBClient) {
        guard !isClosing, cliLink != nil, governor == nil, self.client === shell else { return }
        let pid = cliSupervisorPID
        cliLink = nil
        cliSupervisorPID = nil
        cliGovernorSummary = nil
        cliLinkTask = nil
        if let other = RunStateStore.otherGovernor(of: id, paths: env.paths) {
            otherGovernorOwner = other
            note(.warning, "CLI supervisor is gone; Emuu pid \(other.ownerPID) governs this instance")
            return
        }
        guard let lock = GovernorLock(url: link.lockURL) else {
            // A new supervisor took the lock in between: stay display-only and follow it.
            if link.isLive() {
                cliLink = link
                cliSupervisorPID = link.supervisorPID
                watchCLILink(link, engine: engine, shell: shell)
            }
            return
        }
        governorLock = lock
        note(.warning, "CLI supervisor (pid \(pid.map(String.init) ?? "?")) is gone; this window now governs memory")
        startGovernor(engine: engine, shell: shell)
        writeRunState()
    }

    private func startGovernor(engine: EngineInstance, shell: ADBClient) {
        let config = settings.governorConfig(profile: profile, guestRAMMB: EngineEffectiveRAM.megabytes(for: self.config, paths: env.paths),
                                             automation: automationMode)
        let csv = SampleCSVLog(url: env.paths.logsDirectory.appendingPathComponent("memory-\(id.rawValue).csv"))
        let monitor = services.pressureMonitor
        let governor = MemoryGovernor.standard(
            instanceID: id, config: config, engine: engine, shell: shell, activity: services.activity,
            hostSampler: HostSampler(pressureHint: { monitor.latest }), csvLog: csv)
        self.governor = governor
        governsMemory = true
        eventsTask = Task { [weak self] in
            let stream = await governor.events()
            await governor.start()
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
        note(.info, "Memory governor started (\(profile.title))")
    }

    private func teardownPipeline() async {
        // A recording in progress is finalized first, so the file is complete whatever ends the session.
        if display?.isRecording == true { await stopRecording() }
        let display = self.display
        let governor = self.governor
        self.display = nil
        self.governor = nil
        self.client = nil
        governsMemory = false
        statusTask?.cancel()
        statusTask = nil
        cliLinkTask?.cancel()
        cliLinkTask = nil
        if let display {
            await display.stop()
            display.invalidate()
        }
        if let governor { await governor.stop() }
        eventsTask?.cancel()
        eventsTask = nil
        governorLock?.release()
        governorLock = nil
    }

    // MARK: Display

    /// Called when the window shows the display. Starts streaming (the controller pauses it again when hidden).
    func startDisplay() async {
        displayWanted = true
        guard phase == .ready, let display else { return }
        switch display.state {
        case .idle, .stopped, .failed: break
        default: return
        }
        guard !displayStarting else { return }
        displayStarting = true
        defer { displayStarting = false }
        do {
            try await display.start()
            writeRunState()
        } catch {
            note(.error, "Display failed: \(error.localizedDescription)")
            showToast("Display failed: \(error.localizedDescription)")
        }
    }

    /// Called when the window goes away while the session stays attached (keep-running close).
    func stopDisplay() async {
        displayWanted = false
        await display?.stop()
        writeRunState()
    }

    /// Wraps the view's visibility callback so a frozen engine is thawed (and a hibernated one resumed)
    /// *before* the display controller reopens the frame stream (a SIGSTOPped engine does not answer gRPC). Also nudges the governor so it reacts immediately.
    private func interposeVisibility(_ controller: EmulatorDisplayController) {
        let forward = controller.view.onVisibilityChange
        let interaction = controller.view.onUserInteraction
        controller.view.onUserInteraction = { [weak self] in
            interaction?()
            self?.sendTouchToSupervisor()
        }
        controller.view.onVisibilityChange = { [weak self] visible, focused in
            guard let self else { forward?(visible, focused); return }
            self.governor?.nudge()
            // Newer events win: an async "visible" path (thaw first) must not deliver after a later "hidden".
            self.visibilitySeq &+= 1
            let seq = self.visibilitySeq
            let deliver: @MainActor () -> Void = { [weak self] in
                guard let self, self.visibilitySeq == seq else { return }
                forward?(visible, focused)
            }
            if let link = self.cliLink {
                // The CLI supervisor governs: tell it, and let it wake the engine (it owns freeze/hibernate).
                if !visible { deliver() }
                Task { @MainActor [weak self] in
                    _ = await link.sendAsync(["command": "visibility", "visible": visible])
                    guard visible else { return }
                    let state = await self?.engine?.refresh()
                    if state == .frozen || state == .hibernated {
                        self?.note(.action, "Asking the CLI supervisor to wake the instance")
                        let r = await link.sendAsync(["command": "wake"], timeout: 180)
                        if !r.ok { self?.note(.error, "Wake via supervisor failed: \(r.message ?? "?")") }
                        if state == .hibernated { self?.resumeEngine(); return }
                    }
                    deliver()
                }
                return
            }
            guard visible, let engine = self.engine else {
                deliver()
                return
            }
            Task { @MainActor [weak self] in
                let state = await engine.state()
                switch state {
                case .frozen:
                    let t0 = ContinuousClock.now
                    do {
                        try await engine.thaw()
                        self?.note(.info, "Thawed on show in \(Self.format(ContinuousClock.now - t0))")
                    } catch {
                        self?.note(.error, "Thaw failed: \(error.localizedDescription)")
                    }
                    deliver()
                case .hibernated, .stopped, .crashed:
                    // The pipeline is rebuilt by resume; the old controller's view is gone.
                    self?.resumeEngine()
                default:
                    deliver()
                }
            }
        }
    }

    /// Resumes a hibernated/stopped engine and rebuilds the pipeline (ports can change across launches).
    func resumeEngine(coldBoot: Bool = false) {
        guard resumeTask == nil, !isClosing, let engine else { return }
        resumeTask = Task { [weak self] in
            guard let self else { return }
            defer { self.resumeTask = nil }
            let state = await engine.state()
            self.phase = .working(state == .hibernated ? "Resuming from hibernation…" : "Booting Android…")
            self.note(.action, state == .hibernated ? "Resuming from hibernation" : "Starting engine")
            let started = ContinuousClock.now
            do {
                if coldBoot { try await engine.start(EngineLaunchOptions(coldBoot: true)) } else { try await engine.resume() }
                self.note(.info, "Engine ready in \(Self.format(ContinuousClock.now - started))")
                try await self.buildPipeline(engine: engine)
            } catch {
                self.fail(error)
            }
        }
    }

    /// User input → `touch` for a CLI supervisor (at most every 20 s).
    private func sendTouchToSupervisor() {
        guard let link = cliLink else { return }
        let now = ContinuousClock.now
        if let last = lastTouchSent, now - last < .seconds(20) { return }
        lastTouchSent = now
        Task { _ = await link.sendAsync(["command": "touch"]) }
    }

    var isCLISupervised: Bool { cliLink != nil }

    // MARK: Engine state

    private func watchEngine(_ engine: EngineInstance) {
        engineWatch?.cancel()
        engineWatch = Task { [weak self] in
            for await state in await engine.stateUpdates() {
                guard let self else { return }
                self.engineStateChanged(state)
            }
        }
    }

    private func engineStateChanged(_ state: InstanceState) {
        let previous = engineState
        engineState = state
        guard previous != state else { return }
        if case .crashed(let reason) = state, wasUp, !isClosing, resumeTask == nil, !restartingEngine,
           WindowAutoClosePolicy.engineLogShowsShutdown(Self.logTail(env.paths.engineLogFile(for: id))) {
            // Not a crash: Android powered off; the engine saved, hung and killed itself (its snapshot was
            // discarded, so the next start cold-boots). Close like any external stop, after confirming that no
            // supervisor restarts it.
            crashWasShutdown = true
            note(.info, "Android powered off (engine exit: \(reason))")
            log.info("\(id): Android powered off; engine exit reported as \(reason)")
            CrashMarker.clear(for: id, paths: env.paths)
            if phase == .ready { phase = .parked(.stopped) }
            confirmExternalExit()
            writeRunState()
            return
        }
        switch WindowAutoClosePolicy.decide(previous: previous, new: state, context: autoCloseContext) {
        case .keepOpen: break
        case .close(let reason): engineEnded(reason)
        case .confirm: confirmExternalExit()
        }
        if state.isRunningEngine { crashWasShutdown = false }
        switch state {
        case .hibernated, .stopped:
            if phase == .ready { phase = .parked(state) }
        case .crashed(let reason):
            phase = .failed("Engine crashed: \(reason)")
            note(.error, "Engine crashed: \(reason)")
        case .running:
            if case .parked = phase, display != nil, resumeTask == nil { phase = .ready }
        default:
            break
        }
        writeRunState()
    }

    private var autoCloseContext: WindowAutoClosePolicy.Context {
        var failed = false
        if case .failed = phase { failed = true }
        return WindowAutoClosePolicy.Context(wasUp: wasUp, showsFailure: failed,
                                             restartInProgress: restartingEngine || resumeTask != nil,
                                             exitRequestedHere: exitRequestedHere, crashWasShutdown: crashWasShutdown)
    }

    /// The last 64 KiB of a log file.
    private static func logTail(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    /// The engine vanished without this process stopping it: wait `confirmDelay`, look for an engine again
    /// and close only if none came back (a restart by the CLI, a supervisor or self-healing starts a new
    /// engine within about a second).
    private func confirmExternalExit() {
        guard exitCheckTask == nil, !isClosing, !endReported, let engine else { return }
        exitCheckTask = Task { [weak self] in
            try? await Task.sleep(for: WindowAutoClosePolicy.confirmDelay)
            var checks = 0
            while !Task.isCancelled {
                guard let self, !self.isClosing, !self.endReported else { return }
                let state = await engine.refresh()
                let supervisor = self.cliLink.flatMap { $0.isLive() ? $0.status()?["engineState"] as? String : nil }
                var verdict = WindowAutoClosePolicy.confirm(state: state, supervisorEngineState: supervisor, context: self.autoCloseContext)
                if verdict == .checkAgain, checks >= WindowAutoClosePolicy.maxRechecks {
                    verdict = .close(reason: WindowAutoClosePolicy.reason(state))
                }
                switch verdict {
                case .close(let reason):
                    self.exitCheckTask = nil
                    if WindowAutoClosePolicy.isCrash(state) {
                        // Power-off: clear the controller's crash state (no engine is running, just checked) so
                        // the library shows the instance as stopped.
                        try? await engine.stop(.force)
                    }
                    self.engineEnded(reason)
                    return
                case .engineBack:
                    self.exitCheckTask = nil
                    self.note(.info, "Engine is back (\(state)) after a restart elsewhere; reconnecting")
                    self.log.info("\(self.id): engine restarted elsewhere (\(state)); window stays open")
                    self.resumeEngine()
                    return
                case .keepOpen:
                    self.exitCheckTask = nil
                    return
                case .checkAgain:
                    checks += 1
                    try? await Task.sleep(for: WindowAutoClosePolicy.recheckInterval)
                }
            }
        }
    }

    /// Shut down or hibernated on purpose: hand the window to the app to close (once).
    private func engineEnded(_ reason: String) {
        guard !endReported, !isClosing else { return }
        endReported = true
        exitCheckTask?.cancel()
        exitCheckTask = nil
        note(.info, "Instance \(reason); closing the window")
        log.info("\(id) \(reason); closing its window")
        onEngineEnded?(self, reason)
    }

    // MARK: Governor events / HUD

    private func handle(_ event: GovernorEvent) {
        switch event.kind {
        case .sampled:
            break // the HUD reads `status().lastSample` (one value, no history copy)
        case .tierChanged(let from, let to, let reason):
            note(.info, "Tier \(from) → \(to): \(reason)", at: event.timestamp)
        case .actionPlanned:
            break
        case .actionApplied(let action, let outcome):
            var text = "\(action.shortTitle): \(outcome.status.rawValue)"
            if let b = outcome.reclaimedBytes, b > 0 { text += ", freed \(ByteCount.format(b))" }
            if !outcome.detail.isEmpty { text += " — \(outcome.detail)" }
            note(outcome.status == .applied ? .action : .info, text, at: event.timestamp)
        case .actionFailed(let action, let message):
            note(.error, "\(action.shortTitle) failed: \(message)", at: event.timestamp)
        case .creepDetected(let perHour, let window):
            note(.warning, "Memory creep \(ByteCount.format(signed: perHour))/h over \(Self.format(window))", at: event.timestamp)
        case .stateChanged(let state):
            note(.info, "Engine \(state)", at: event.timestamp)
        case .guestRebooted(let uptime, let recent):
            note(.warning, "Android restarted (uptime \(Self.format(uptime))); last governor actions: \(recent.isEmpty ? "none" : recent.suffix(3).joined(separator: "; "))", at: event.timestamp)
        case .maintenanceRan(let summary):
            note(.action, "Maintenance: \(summary)", at: event.timestamp)
        }
    }

    /// Refreshes the HUD from the governor every 2 s while `active` (the HUD popover is open).
    func setHUDActive(_ active: Bool) {
        statusTask?.cancel()
        statusTask = nil
        guard active else { return }
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func refreshStatus() async {
        if let governor {
            let status = await governor.status()
            governorStatus = status
            latestSample = status.lastSample
        } else {
            // Display-only attachment: sample directly (one adb round trip + syscalls, only while the HUD is open).
            let pid = await engine?.enginePID()
            let host = HostSampler().sample(enginePID: pid)
            var p = HistoryPoint(timestamp: Date(), monotonic: .zero, level: .normal, tier: .none)
            p.engineFootprintBytes = host.engine?.footprintBytes
            p.engineCPUPercent = host.engine?.cpuPercent
            p.hostPressure = host.system.pressure
            p.hostFreeBytes = host.system.freeBytes
            if engineState == .running, let client, let g = try? await GuestSampler(shell: client).sample() {
                p.guestTotalBytes = g.memory.totalBytes
                p.guestAvailableBytes = g.memory.availableBytes
                p.guestSwapUsedBytes = g.memory.swapUsedBytes
            }
            latestSample = p
            if let link = cliLink, let gov = link.status()?["governor"] as? [String: Any] {
                let enabled = gov["enabled"] as? Bool ?? false
                cliGovernorSummary = enabled
                    ? "CLI governor: \(gov["profile"] as? String ?? "?"), level \(gov["level"] as? String ?? "?"), \(gov["tier"] as? String ?? "?")"
                    : "CLI supervisor runs without a governor"
            }
        }
    }

    func setProfile(_ profile: MemoryProfile) async {
        guard profile != self.profile else { return }
        self.profile = profile
        settings.setProfile(profile, for: id)
        await applySettings()
        note(.info, "Profile → \(profile.title)")
        writeRunState()
    }

    /// Pushes the current settings (freeze/hibernate) into the running governor.
    func applySettings() async {
        guard let governor else { return }
        await governor.updateConfig(settings.governorConfig(profile: profile, guestRAMMB: EngineEffectiveRAM.megabytes(for: config, paths: env.paths),
                                                            automation: automationMode))
    }

    /// Manual reclaim: trim background apps, kill cached processes, compact system_server. Measures guest
    /// MemAvailable before/after. (Returning RAM to the host needs hibernate — the guest has no balloon.)
    func reclaimNow() async {
        guard !reclaimInProgress, let client, engineState == .running else {
            if engineState != .running { showToast("Reclaim needs a running instance (now \(engineState))") }
            return
        }
        reclaimInProgress = true
        defer { reclaimInProgress = false }
        note(.action, "Reclaim now (manual)")
        let sampler = GuestSampler(shell: client)
        let effector = GuestEffector(shell: client)
        let before = try? await sampler.sample().memory.availableBytes
        var parts: [String] = []
        let steps: [(String, () async throws -> EffectorOutcome)] = [
            ("trim", { try await effector.trim(level: .complete, packages: []) }),
            ("kill cached", { try await effector.killBackground(packages: []) }),
            ("compact", { try await effector.compactSystem() }),
        ]
        for (name, step) in steps {
            do {
                let outcome = try await step()
                parts.append("\(name) \(outcome.status.rawValue)")
            } catch {
                parts.append("\(name) failed")
                note(.error, "Reclaim \(name) failed: \(error.localizedDescription)")
            }
        }
        let after = try? await sampler.sample().memory.availableBytes
        var summary = parts.joined(separator: ", ")
        if let before, let after {
            let delta = Int64(after) - Int64(before)
            summary += "; guest available \(delta >= 0 ? "+" : "")\(ByteCount.format(signed: delta))"
        }
        note(.action, "Reclaim: \(summary)")
        showToast("Reclaim: \(summary)")
        governor?.nudge()
        await refreshStatus()
    }

    // MARK: Device actions

    @discardableResult
    func press(_ key: DeviceKey) -> Bool {
        noteInputActivity()
        return display?.press(key) ?? false
    }

    func back() { press(.back) }
    func home() { press(.home) }
    func recents() { press(.appSwitch) }
    func volumeUp() { press(.volumeUp) }
    func volumeDown() { press(.volumeDown) }
    func power() { press(.power) }

    /// `settings put system accelerometer_rotation 1`: Android follows the device's (sensor) orientation.
    static let autoRotateCommand = "settings put system accelerometer_rotation 1"

    /// Rotate button / ⌘R: physically turns the virtual device portrait ↔ landscape (the engine's
    /// orientation sensors, like Android Studio's rotate buttons). The window follows the frames' size.
    func rotate() {
        guard let display else { return }
        noteInputActivity()
        display.rotate()
    }

    private func noteInputActivity() {
        services.activity.noteInteraction(for: id)
        sendTouchToSupervisor()
    }

    func takeScreenshot() async {
        guard let client, engineState == .running else { return showToast("Screenshot needs a running instance") }
        do {
            // The engine's host framebuffer (secure windows included); adb screencap only as a fallback.
            let png: Data
            if let display, let shot = try? await display.session.screenshotPNG() {
                png = shot
            } else {
                png = try await DeviceHelpers(client: client).screenshotPNG()
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            // ~/.emuu/screenshots needs no privacy prompt (Desktop/Pictures are TCC-protected and would block).
            let dir = Self.screenshotsDirectory(env.paths)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("Emuu \(displayName) \(formatter.string(from: Date())).png")
            try png.write(to: url, options: .atomic)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([url as NSURL])
            pb.setData(png, forType: .png)
            note(.info, "Screenshot saved: \(url.lastPathComponent)")
            showToast("Screenshot copied to clipboard and saved in ~/.emuu/screenshots")
        } catch {
            showToast("Screenshot failed: \(error.localizedDescription)")
        }
    }

    static func screenshotsDirectory(_ paths: EmuuPaths) -> URL {
        paths.root.appendingPathComponent("screenshots", isDirectory: true)
    }

    func revealScreenshots() {
        let dir = Self.screenshotsDirectory(env.paths)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    // MARK: Recording

    static func recordingsDirectory(_ paths: EmuuPaths) -> URL {
        paths.root.appendingPathComponent("recordings", isDirectory: true)
    }

    var isRecording: Bool { recordingStartedAt != nil }

    func toggleRecording() {
        Task { if isRecording { await stopRecording() } else { await startRecording() } }
    }

    /// Records the frames to `~/.emuu/recordings/Emuu <name> <date>.mp4` (hardware H.264 while recording).
    func startRecording() async {
        guard let display, !recordingBusy, !isRecording else { return }
        guard engineState == .running else { return showToast("Recording needs a running instance") }
        recordingBusy = true
        defer { recordingBusy = false }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let dir = Self.recordingsDirectory(env.paths)
        let url = dir.appendingPathComponent("Emuu \(displayName) \(formatter.string(from: Date())).mp4")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try await display.startRecording(to: url)
            recordingStartedAt = display.recordingStartedAt ?? Date()
            note(.action, "Recording started")
            // A CLI supervisor must also hear that the instance is in use (it expires hints after 60 s).
            if let link = cliLink {
                recordingKeepAliveTask?.cancel()
                recordingKeepAliveTask = Task {
                    while !Task.isCancelled {
                        _ = await link.sendAsync(["command": "visibility", "visible": true])
                        _ = await link.sendAsync(["command": "touch"])
                        try? await Task.sleep(for: .seconds(20))
                    }
                }
            }
        } catch {
            showToast("Recording failed: \(error.localizedDescription)")
        }
    }

    /// Stops and finalizes the recording; shows where it went.
    func stopRecording() async {
        guard let display, isRecording else { return }
        recordingBusy = true
        defer { recordingBusy = false }
        recordingKeepAliveTask?.cancel()
        recordingKeepAliveTask = nil
        let result = await display.stopRecording()
        recordingStartedAt = nil
        guard let result, let first = result.files.first else {
            return showToast("Recording stopped; no frames were recorded")
        }
        let secs = Double(result.duration.components.seconds) + Double(result.duration.components.attoseconds) / 1e18
        let text = result.files.count == 1
            ? String(format: "Recording saved (%.1f s): %@", secs, first.lastPathComponent)
            : String(format: "Recording saved in %d parts (%.1f s, rotated)", result.files.count, secs)
        note(.info, text)
        showToast(text, reveal: first)
        lastRecording = result
    }

    /// The last finished recording (self-test / diagnostics).
    @ObservationIgnored private(set) var lastRecording: RecordingResult?

    // MARK: Soft keyboard

    /// Keyboard button: turns Android's on-screen keyboard on (shows it for a focused field) or off (hides it).
    func toggleSoftKeyboard() {
        Task { await setSoftKeyboard(!softKeyboardEnabled) }
    }

    func setSoftKeyboard(_ on: Bool) async {
        guard let client, !keyboardBusy else { return }
        keyboardBusy = true
        defer { keyboardBusy = false }
        softKeyboardEnabled = on
        _ = try? env.store.updatePreferences(id) { $0.showSoftKeyboard = on }
        do {
            let outcome = try await SoftKeyboard(shell: client).apply(show: on, lastTap: lastTap)
            switch outcome {
            case .shown: showToast("On-screen keyboard on")
            case .hidden: showToast("On-screen keyboard off")
            case .noTextField: showToast(on ? "On-screen keyboard on: it appears in text fields" : "On-screen keyboard off")
            case .unchanged: showToast(on ? "On-screen keyboard on" : "On-screen keyboard off")
            }
            note(.info, "On-screen keyboard \(on ? "on" : "off") (\(outcome))")
        } catch {
            showToast("Keyboard: \(error.localizedDescription)")
        }
    }

    /// After a tap with the keyboard turned off: close the IME if the tap focused a text field.
    func pointerUp(x: Int, y: Int) {
        lastTap = (x, y)
        guard !softKeyboardEnabled, let client else { return }
        keyboardEnforceTask?.cancel()
        keyboardEnforceTask = Task {
            for delay in [600, 900] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { return }
                if (try? await SoftKeyboard(shell: client).enforceHidden()) == true { return }
            }
        }
    }

    // MARK: Automation mode

    func setAutomationMode(_ on: Bool) async {
        guard on != automationMode else { return }
        automationMode = on
        _ = try? env.store.updatePreferences(id) { $0.automationMode = on }
        if let link = cliLink {
            let r = await link.sendAsync(["command": "automation", "enabled": on])
            if !r.ok { note(.error, "Automation via supervisor failed: \(r.message ?? "?")") }
        } else {
            await applySettings()
        }
        note(.info, "Automation mode \(on ? "on: never freeze/hibernate, background trims only" : "off")")
        writeRunState()
    }

    /// Picks up preference changes made elsewhere (`emuu automation on`, `emuu keyboard off`): one small JSON
    /// read every 5 s while attached.
    private func watchPreferences() {
        prefsTask?.cancel()
        prefsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                // Memory indicator in the strip: the governor's last sample (in-process, no adb traffic).
                if self.governor != nil { await self.refreshStatus() }
                guard let fresh = try? self.env.store.load(self.id) else { continue }
                if fresh.isAutomationMode != self.automationMode, self.cliLink == nil {
                    self.automationMode = fresh.isAutomationMode
                    await self.applySettings()
                    self.note(.info, "Automation mode \(fresh.isAutomationMode ? "on" : "off") (changed from the CLI)")
                } else if fresh.isAutomationMode != self.automationMode {
                    self.automationMode = fresh.isAutomationMode
                }
                if fresh.softKeyboardEnabled != self.softKeyboardEnabled, !self.keyboardBusy {
                    self.softKeyboardEnabled = fresh.softKeyboardEnabled
                }
            }
        }
    }

    func revealRecordings() {
        let dir = Self.recordingsDirectory(env.paths)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    func copySerial() {
        guard let serial = client?.serial.rawValue else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(serial, forType: .string)
        showToast("Copied \(serial) — adb -s \(serial) shell")
    }

    func openPlayStore() async {
        guard let client else { return }
        do {
            let store = PlayStore(shell: client)
            let status = try await store.status()
            guard status.storeInstalled else {
                return showToast("This system image has no Play Store. Create an instance from a google_apis_playstore image.")
            }
            try await store.open()
            if case .signedOut = try await store.accountState() {
                showToast("Play Store opened — sign in with a Google account to install apps")
            }
        } catch {
            showToast("Play Store: \(error.localizedDescription)")
        }
    }

    func openGoogleSignIn() async {
        guard let client else { return }
        do { try await PlayStore(shell: client).openAddGoogleAccount() } catch {
            showToast("Sign-in: \(error.localizedDescription)")
        }
    }

    // MARK: Install

    /// File types accepted for install (drag & drop and the open panel).
    static let installExtensions: Set<String> = ["apk", "xapk", "apks", "apkm"]

    /// Installs dropped/selected files: a set of .apk files that contains `base.apk` (or split_*.apk) is
    /// installed as one split set; everything else one by one.
    func install(urls: [URL]) {
        let files = urls.filter { Self.installExtensions.contains($0.pathExtension.lowercased()) }
        guard !files.isEmpty else {
            return showToast("Drop .apk, .xapk, .apks or .apkm files to install")
        }
        let apks = files.filter { $0.pathExtension.lowercased() == "apk" }
        let looksSplit = apks.count > 1 && apks.contains {
            let n = $0.lastPathComponent.lowercased()
            return n == "base.apk" || n.hasPrefix("split_") || n.contains("config.")
        }
        var sources: [(String, InstallSource)] = []
        if looksSplit {
            sources.append(("\(apks.count) split APKs", .splitAPKs(apks)))
            for f in files where f.pathExtension.lowercased() != "apk" {
                if let s = InstallSource.detect(fileURL: f) { sources.append((f.lastPathComponent, s)) }
            }
        } else {
            for f in files { if let s = InstallSource.detect(fileURL: f) { sources.append((f.lastPathComponent, s)) } }
        }
        Task { [weak self] in
            for (name, source) in sources { await self?.runInstall(name: name, source: source) }
        }
    }

    private func runInstall(name: String, source: InstallSource) async {
        guard let client else { return showToast("Install needs a running instance") }
        var job = InstallJob(fileName: name, status: .running(stage: "Preparing", fraction: nil))
        let jobID = job.id
        installJobs.append(job)
        trimInstallJobs()
        let installer = APKInstaller(client: client, cacheDirectory: env.paths.cacheDirectory)
        // An install is user activity: keep the governor (ours or the CLI supervisor's) from freezing or
        // hibernating the engine mid-push while the window is hidden. Refreshed well inside the shortest idle
        // freeze (2 min on frugal), progress callbacks or not.
        noteInstallActivity()
        let keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                self?.noteInstallActivity()
            }
        }
        defer { keepAlive.cancel() }
        do {
            let result = try await installer.install(source) { [weak self] progress in
                Task { @MainActor in
                    self?.updateJob(jobID, .running(stage: progress.stage.title, fraction: progress.fraction))
                }
            }
            switch result.status {
            case .installed:
                var text = "Installed \(result.packageName ?? name)"
                if result.obbCount > 0 { text += " with \(result.obbCount) game data file\(result.obbCount == 1 ? "" : "s")" }
                job.status = .succeeded(text)
                note(.info, text)
            case .openedInPlayStore:
                job.status = .succeeded("Opened in Play Store")
            case .failed(let code, let message):
                job.status = .failed(message.isEmpty ? code : message)
                note(.error, "Install of \(name) failed: \(code)")
            }
        } catch {
            job.status = .failed(error.localizedDescription)
            note(.error, "Install of \(name) failed: \(error.localizedDescription)")
        }
        updateJob(jobID, job.status)
    }

    private func noteInstallActivity() {
        services.activity.noteInteraction(for: id)
        sendTouchToSupervisor()
    }

    private func updateJob(_ id: UUID, _ status: InstallJob.Status) {
        guard let i = installJobs.firstIndex(where: { $0.id == id }) else { return }
        // A late progress callback must not overwrite a final status.
        if case .running = status, !installJobs[i].isRunning { return }
        installJobs[i].status = status
        if case .running = status { return }
        let finishedID = id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            self?.installJobs.removeAll { $0.id == finishedID && !$0.isRunning }
        }
    }

    func dismissInstallJob(_ id: UUID) { installJobs.removeAll { $0.id == id && !$0.isRunning } }

    private func trimInstallJobs() {
        while installJobs.count > 6, let i = installJobs.firstIndex(where: { !$0.isRunning }) { installJobs.remove(at: i) }
    }

    // MARK: Lifecycle end

    /// Releases display, governor and watchers. The engine keeps whatever state it is in.
    func detach() async {
        isClosing = true
        await openTask?.value
        await resumeTask?.value
        openTask = nil
        displayWanted = false
        resumeTask?.cancel()
        resumeTask = nil
        await teardownPipeline()
        engineWatch?.cancel()
        engineWatch = nil
        exitCheckTask?.cancel()
        exitCheckTask = nil
        prefsTask?.cancel()
        prefsTask = nil
        keyboardEnforceTask?.cancel()
        recordingKeepAliveTask?.cancel()
        toastTask?.cancel()
        RunStateStore.remove(id, paths: env.paths)
        services.activity.remove(id)
        engine = nil
    }

    /// Detaches after the engine was shut down or hibernated elsewhere (the window closed by itself). Same
    /// teardown as a user close; a CLI supervisor is told the display is gone so it does not resume the engine.
    func detachAfterEngineEnded() async {
        isClosing = true
        if let link = cliLink {
            await teardownPipeline()
            _ = await link.sendAsync(["command": "visibility", "visible": false])
        }
        await detach()
    }

    /// Applies a quit/close choice, then detaches.
    func finish(_ choice: ShutdownChoice) async {
        // Let an in-flight boot/resume reach a stable state first (it builds nothing once closing).
        isClosing = true
        await openTask?.value
        await resumeTask?.value
        let engine = self.engine
        if cliLink == nil, let engine, await engine.state() == .frozen {
            // Nobody will govern after we detach, and adb teardown would hang on a stopped engine.
            do { try await engine.thaw() } catch { log.error("thaw before detach failed: \(error.localizedDescription)") }
        }
        if let link = cliLink {
            // The CLI supervisor owns this engine: route the request to it (keepRunning just detaches).
            await teardownPipeline()
            _ = await link.sendAsync(["command": "visibility", "visible": false])
            switch choice {
            case .hibernate: _ = await link.sendAsync(["command": "hibernate"], timeout: 180)
            case .shutDown: _ = await link.sendAsync(["command": "stop", "save": false], timeout: 240)
            case .keepRunning: break
            }
            await detach()
            return
        }
        await teardownPipeline()
        if let engine {
            do {
                switch choice {
                case .hibernate:
                    let state = await engine.state()
                    if state == .running || state == .frozen { try await engine.hibernate() }
                case .shutDown:
                    try await engine.stop(.graceful(saveQuickBoot: false))
                case .keepRunning:
                    break
                }
            } catch {
                log.error("\(choice.rawValue) of \(id) failed: \(error.localizedDescription)")
            }
        }
        await detach()
    }

    /// An engine adopted from an older Emuu has no gRPC endpoint (no `-grpc`): save it (quick-boot snapshot)
    /// and launch it again with the current command line. Nothing is lost; takes a few seconds.
    func restartEngineForDisplay() {
        Task { [weak self] in
            guard let self, !self.restartingEngine else { return }
            // A restart, not a hibernation: the window stays open (see `WindowAutoClosePolicy`).
            self.restartingEngine = true
            defer { self.restartingEngine = false }
            if let link = self.cliLink {
                self.note(.action, "Restarting the engine through the CLI supervisor (display service)")
                _ = await link.sendAsync(["command": "hibernate"], timeout: 180)
                _ = await link.sendAsync(["command": "wake"], timeout: 180)
                if let engine = self.engine {
                    _ = await engine.refresh()
                    try? await self.buildPipeline(engine: engine)
                }
                return
            }
            await self.hibernateNow()
            self.resumeEngine()
            await self.resumeTask?.value
        }
    }

    /// Hibernate from the window/HUD/menu. The window then closes (the library resumes the instance); during
    /// "Restart Engine" it stays open and the engine is resumed.
    func hibernateNow() async {
        guard let engine else { return }
        if let link = cliLink {
            note(.action, "Hibernate via CLI supervisor")
            if !restartingEngine {
                // The window is about to close: finalise a recording and tell the supervisor nobody is looking,
                // or its governor resumes the instance at once (a visible display is a resume trigger).
                exitRequestedHere = true
                displayWanted = display != nil
                await teardownPipeline()
                phase = .working("Hibernating…")
                _ = await link.sendAsync(["command": "visibility", "visible": false])
            }
            let r = await link.sendAsync(["command": "hibernate"], timeout: 180)
            if !r.ok {
                exitRequestedHere = false
                if restartingEngine { showToast("Hibernate failed: \(r.message ?? "?")") } else { fail(EmuuError.engine("Hibernate failed: \(r.message ?? "?")")) }
            }
            return
        }
        displayWanted = display != nil
        await teardownPipeline()
        phase = .working("Hibernating…")
        note(.action, "Hibernate (manual)")
        do {
            try await engine.hibernate()
            phase = .parked(.hibernated)
        } catch {
            fail(error)
        }
        writeRunState()
    }

    // MARK: Helpers

    private func fail(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        phase = .failed(message)
        note(.error, message)
        log.error("session \(id): \(message)")
    }

    func note(_ kind: TimelineEntry.Kind, _ text: String, at date: Date = Date()) {
        nextTimelineID &+= 1
        timeline.append(TimelineEntry(id: nextTimelineID, date: date, kind: kind, text: text))
        if timeline.count > Self.timelineCapacity { timeline.removeFirst(timeline.count - Self.timelineCapacity) }
    }

    func showToast(_ text: String, reveal: URL? = nil) {
        toast = text
        toastRevealURL = reveal
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.toast = nil
            self?.toastRevealURL = nil
        }
    }

    func revealToastFile() {
        guard let url = toastRevealURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func writeRunState() {
        guard engine != nil, !isClosing, !endReported else { return }
        let state = InstanceRunState(
            instanceID: id, ownerKind: .app, enginePID: nil, serial: client?.serial,
            governorActive: governsMemory, displayActive: display?.state.isActive ?? false,
            profile: governsMemory ? profile : nil, startedAt: startedAt, updatedAt: Date())
        var record = state
        record.enginePID = cachedEnginePID
        // Synchronous (a few hundred bytes) so a later `RunStateStore.remove` can never be overtaken.
        try? RunStateStore.write(record, paths: env.paths)
    }

    static func format(_ d: Duration) -> String {
        let s = d.components.seconds
        if s < 60 { return String(format: "%.1f s", Double(s) + Double(d.components.attoseconds) / 1e18) }
        if s < 3600 { return "\(s / 60) min" }
        return String(format: "%.1f h", Double(s) / 3600)
    }
}

extension InstallJob {
    var isRunning: Bool { if case .running = status { return true } else { return false } }
}

extension InstallStage {
    var title: String {
        switch self {
        case .inspecting: return "Inspecting"
        case .extracting: return "Extracting"
        case .uploading: return "Uploading"
        case .committing: return "Installing"
        case .copyingExpansionFiles: return "Copying game data"
        case .finished: return "Finishing"
        }
    }
}

extension GovernorAction {
    var shortTitle: String {
        switch self {
        case .trimMemory(let level, let pkgs): return "Trim \(level.rawValue)" + (pkgs.isEmpty ? "" : " (\(pkgs.count) apps)")
        case .trimCaches: return "Trim caches"
        case .killBackground(let pkgs): return "Kill background" + (pkgs.isEmpty ? "" : " (\(pkgs.count))")
        case .reclaimGuestMemory: return "Reclaim to host"
        case .freeze: return "Freeze"
        case .thaw: return "Thaw"
        case .hibernate: return "Hibernate"
        case .resume: return "Resume"
        }
    }
}
