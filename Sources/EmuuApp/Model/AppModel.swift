import AppKit
import Foundation
import Observation
import EmuuBase
import EmuuEngine
import EmuuADB
import EmuuMemory
import EmuuDisplay

/// Process-wide shared services (one each, reused by every instance session).
final class AppServices: Sendable {
    let runner: any ProcessRunner
    let adbServer: ADBServer
    let activity: DisplayActivityTracker
    let pressureMonitor: HostPressureMonitor

    init(env: EngineEnvironment) {
        let runner = SystemProcessRunner()
        self.runner = runner
        self.adbServer = ADBServer(adbExecutable: env.sdk.adb, runner: runner)
        self.activity = DisplayActivityTracker()
        self.pressureMonitor = HostPressureMonitor()
    }
}

/// One row of the instance library.
struct InstanceRow: Identifiable, Hashable {
    var config: InstanceConfig
    var state: InstanceState
    /// A live front end other than this app attached to the instance (e.g. the CLI), if any.
    var otherOwner: InstanceRunState?
    var id: InstanceID { config.id }
}

/// App-wide state: the engine environment, the library rows and the attached sessions.
@MainActor
@Observable
final class AppModel {
    let settings = AppSettings()
    private(set) var env: EngineEnvironment?
    private(set) var services: AppServices?
    private(set) var setupError: String?
    private(set) var rows: [InstanceRow] = []
    private(set) var sessions: [InstanceID: InstanceSession] = [:] {
        didSet { updateNapAssertion() }
    }
    /// Ids with a lifecycle operation in flight (buttons disabled).
    private(set) var busy: Set<InstanceID> = []
    var libraryError: String?
    var showCreateSheet = false
    /// The instance whose emulator window is key (menu commands act on it).
    var activeInstanceID: InstanceID?
    /// Emulator windows, one per instance (plain AppKit windows; see `InstanceWindowController`).
    @ObservationIgnored private(set) var windowControllers: [InstanceID: InstanceWindowController] = [:]

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var napAssertion: NSObjectProtocol?
    @ObservationIgnored private let log = EmuuLogger(category: "app")

    init() {
        do {
            let env = try EngineEnvironment.live()
            self.env = env
            EmuuLogging.bootstrap(fileSink: LogFileSink(url: env.paths.mainLogFile), minimumFileLevel: .info)
            RunStateStore.removeStale(paths: env.paths)
            let services = AppServices(env: env)
            self.services = services
            services.pressureMonitor.onChange { [weak self] level in
                Task { @MainActor in self?.hostPressureChanged(level) }
            }
            log.notice("Emuu app \(Emuu.version) started (pid \(getpid()))")
        } catch {
            setupError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    var playStoreAdvice: String? { env?.missingPlayStoreImageAdvice }

    /// While instances are attached, opt out of App Nap: the governor must keep its cadence exactly when
    /// the windows are hidden (that is when it freezes/hibernates). Idle system sleep stays allowed.
    private func updateNapAssertion() {
        if sessions.isEmpty {
            if let a = napAssertion { ProcessInfo.processInfo.endActivity(a) }
            napAssertion = nil
        } else if napAssertion == nil {
            napAssertion = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Emuu memory governor for running Android instances")
        }
    }

    private func hostPressureChanged(_ level: MemoryPressureLevel) {
        log.notice("host memory pressure: \(level)")
        for s in sessions.values { s.note(level >= .high ? .warning : .info, "Mac memory pressure: \(level)") }
        Task { for s in sessions.values { await s.refreshStatus() } }
    }

    // MARK: Library

    /// Reloads configs and refreshes engine states (adopting engines started elsewhere).
    func reload() async {
        guard let env else { return }
        var result: [InstanceRow] = []
        for config in env.store.list() {
            let state: InstanceState
            if let s = sessions[config.id] {
                state = s.engineState
            } else if let engine = try? await env.engine(for: config.id) {
                state = await engine.refresh()
            } else {
                state = .stopped
            }
            let owner = RunStateStore.live(config.id, paths: env.paths).flatMap { $0.ownerPID == getpid() ? nil : $0 }
            result.append(InstanceRow(config: config, state: state, otherOwner: owner))
        }
        rows = result
    }

    /// Refreshes rows every few seconds while the library window is visible.
    func setLibraryVisible(_ visible: Bool) {
        refreshTask?.cancel()
        refreshTask = nil
        guard visible else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reload()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    /// At launch: attach to instances that are already running (started by the CLI or left running by a
    /// previous app session) and queue their windows.
    func attachRunningInstances() async {
        await reload()
        for row in rows where row.state.isRunningEngine && sessions[row.id] == nil {
            log.info("attaching to running instance \(row.id) (\(row.state))")
            openWindow(row.id)
        }
    }

    // MARK: Windows

    /// Attaches (if needed) and shows the instance's emulator window.
    func openWindow(_ id: InstanceID, coldBoot: Bool = false) {
        attach(id, coldBoot: coldBoot)
        if let existing = windowControllers[id] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = InstanceWindowController(id: id, model: self)
        windowControllers[id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Called by the window controller once its window has closed (the controller is released here).
    func windowControllerClosed(_ id: InstanceID) {
        windowControllers[id] = nil
        if activeInstanceID == id { activeInstanceID = nil }
        windowClosed(id)
    }

    /// The session of the key emulator window, if any.
    var activeSession: InstanceSession? { activeInstanceID.flatMap { sessions[$0] } }

    // MARK: Lifecycle

    func session(for id: InstanceID) -> InstanceSession? { sessions[id] }

    /// Creates (if needed) and opens a session; the caller opens the window.
    @discardableResult
    func attach(_ id: InstanceID, coldBoot: Bool = false) -> InstanceSession? {
        if let s = sessions[id] { return s }
        guard let env, let services else { return nil }
        guard let config = try? env.store.load(id) else {
            libraryError = "Instance \(id) not found"
            return nil
        }
        let session = InstanceSession(config: config, env: env, services: services, settings: settings)
        session.onEngineEnded = { [weak self] session, reason in self?.engineEnded(session, reason: reason) }
        sessions[id] = session
        session.begin(coldBoot: coldBoot)
        return session
    }

    /// Ends a session with `choice` (hibernate / shut down / keep running).
    func finish(_ id: InstanceID, _ choice: ShutdownChoice) async {
        guard let session = sessions[id] else {
            // Not attached: act on the engine directly (e.g. CLI-started instance stopped from the library).
            await withBusy(id) {
                guard let env = self.env, let engine = try? await env.engine(for: id) else { return }
                do {
                    switch choice {
                    case .hibernate: try await engine.hibernate()
                    case .shutDown: try await engine.stop(.graceful(saveQuickBoot: false))
                    case .keepRunning: break
                    }
                } catch {
                    self.libraryError = "\(choice.title) failed: \(error.localizedDescription)"
                }
            }
            await reload()
            return
        }
        sessions[id] = nil
        // Shut down / hibernated from the library (or at quit): the window goes too. The session is already
        // out of `sessions`, so the close does not apply the window-close choice a second time.
        closeWindow(id)
        await withBusy(id) { await session.finish(choice) }
        await reload()
    }

    /// The session's engine was shut down or hibernated on purpose (see `WindowAutoClosePolicy`): close the
    /// window and detach. Same teardown as the user closing the window (display, gRPC streams, governor; a
    /// recording is finalised), but no stop/hibernate is applied — the engine is already down.
    func engineEnded(_ session: InstanceSession, reason: String) {
        let id = session.id
        guard sessions[id] === session else { return }
        log.info("\(id) \(reason): closing its window")
        sessions[id] = nil
        closeWindow(id)
        Task {
            await withBusy(id) { await session.detachAfterEngineEnded() }
            await reload()
        }
    }

    /// Closes an instance window without asking (also when minimised or on another Space). Callers remove the
    /// session from `sessions` first, so `windowClosed` finds nothing to finish.
    private func closeWindow(_ id: InstanceID) {
        guard let controller = windowControllers[id], let window = controller.window else { return }
        let wasMinimised = window.isMiniaturized
        window.close()
        log.info("closed the window of \(id) (was minimised: \(wasMinimised); still visible: \(window.isVisible); instance windows open: \(windowControllers.count))")
    }

    /// Called when an emulator window closes.
    func windowClosed(_ id: InstanceID) {
        guard sessions[id] != nil else { return }
        let choice = ProcessInfo.processInfo.environment["EMUU_APP_SELFTEST"] != nil ? .keepRunning : settings.onWindowClose
        log.info("window for \(id) closed → \(choice.rawValue)")
        Task { await finish(id, choice) }
    }

    func createInstance(name: String, preset: InstancePreset) async throws -> InstanceID {
        guard let env else { throw EmuuError.sdkNotFound(searched: []) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = InstanceID.sanitized(from: trimmed.isEmpty ? "android" : trimmed) else {
            throw EmuuError.invalidInstanceID(trimmed)
        }
        var unique = id
        var n = 2
        while env.store.exists(unique), let next = InstanceID(rawValue: "\(id.rawValue)-\(n)") {
            unique = next
            n += 1
        }
        try env.createInstance(id: unique, preset: preset, displayName: trimmed.isEmpty ? nil : trimmed)
        await reload()
        return unique
    }

    func deleteInstance(_ id: InstanceID) async {
        guard let env else { return }
        if let s = sessions[id] {
            sessions[id] = nil
            await s.detach()
        }
        await withBusy(id) {
            do {
                try await env.deleteInstance(id)
                self.settings.clearInstance(id)
            } catch {
                self.libraryError = "Delete failed: \(error.localizedDescription)"
            }
        }
        await reload()
    }

    /// For quit: applies `choice` to every attached session.
    func finishAll(_ choice: ShutdownChoice) async {
        // Instances governed by a CLI supervisor stay with it: the app only detaches from them.
        let plan = sessions.map { ($0.key, $0.value.isCLISupervised ? ShutdownChoice.keepRunning : choice) }
        await withTaskGroup(of: Void.self) { group in
            for (id, c) in plan { group.addTask { await self.finish(id, c) } }
        }
    }

    /// Sessions whose engine is up and owned by this app (they need a quit decision).
    var runningSessions: [InstanceSession] {
        sessions.values.filter { !$0.isCLISupervised && ($0.engineState.isRunningEngine || $0.engineState == .booting) }
    }

    private func withBusy(_ id: InstanceID, _ body: () async -> Void) async {
        busy.insert(id)
        defer { busy.remove(id) }
        await body()
    }

    /// Applies changed settings to every governed session.
    func settingsChanged() {
        Task { for s in sessions.values { await s.applySettings() } }
    }
}
