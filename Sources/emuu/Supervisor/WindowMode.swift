import AppKit
import Foundation
import EmuuBase
import EmuuEngine
import EmuuADB
import EmuuDisplay

/// `emuu start --window`: the supervisor plus a small AppKit window showing the engine's framebuffer (gRPC).
/// The display's activity tracker feeds the governor, so a hidden/minimised window lets it freeze the
/// engine (and the frame stream closes 1 s after the window is hidden).
enum WindowMode {
    static func run(ctx: CLIContext, config: InstanceConfig, options: SupervisorOptions) async throws -> Int32 {
        let tracker = DisplayActivityTracker()
        let activity = SupervisorActivity(display: tracker)
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
        guard let engine = await supervisor.engineControl(), let serial = await engine.serial() else {
            await supervisor.tearDown()
            throw CLIError("engine has no adb serial")
        }
        let host = await MainActor.run {
            WindowHost(ctx: ctx, config: config, tracker: tracker) {
                Task { await supervisor.requestShutdown(reason: "Window closed") }
            }
        }
        do {
            try await host.show(serial: serial)
            Out.line("Display window open (engine framebuffer over gRPC, shared memory). Hidden or minimised, the frame stream closes and the governor may freeze the engine.")
        } catch {
            Out.err("emuu: display failed: \(describe(error)). The instance keeps running headless; stop with Ctrl-C.")
        }
        // Follow the engine across hibernate/resume (it may come back on another port).
        let follow = Task {
            for await state in await engine.stateUpdates() where state == .running {
                if let s = await engine.serial() { try? await host.show(serial: s) }
            }
        }
        // The main thread is already running NSApplication (see `EmuuCLI.main`).
        let exit = await supervisor.waitForExit()
        await host.close()
        follow.cancel()
        await supervisor.tearDown()
        switch exit {
        case .stopped: Out.line("\(config.id) stopped.")
        case .detached: Out.line("Supervisor exited; \(config.id) is still running.")
        case .engineGone(let why), .failed(let why): Out.err("emuu: \(config.id): \(why)")
        }
        return exit.exitCode
    }
}

@MainActor
final class WindowHost: NSObject, NSWindowDelegate {
    let ctx: CLIContext
    let config: InstanceConfig
    let tracker: DisplayActivityTracker
    let onClose: @Sendable () -> Void
    private var window: NSWindow?
    private var controller: EmulatorDisplayController?
    private var currentSerial: DeviceSerial?
    private var closing = false

    init(ctx: CLIContext, config: InstanceConfig, tracker: DisplayActivityTracker, onClose: @escaping @Sendable () -> Void) {
        self.ctx = ctx
        self.config = config
        self.tracker = tracker
        self.onClose = onClose
        super.init()
    }

    /// Shows the window (creating it once) and (re)starts the stream for `serial`.
    func show(serial: DeviceSerial) async throws {
        if serial == currentSerial, let controller {
            // Same device: the stream may have ended while the engine was frozen/hibernated; reconnect.
            switch controller.session.currentState {
            case .failed, .stopped, .idle: try await controller.restart()
            default: break
            }
            return
        }
        if let old = controller {
            await old.stop()
            old.invalidate()
        }
        let session = ctx.displaySession(config.id)
        let controller = EmulatorDisplayController(session: session, instanceID: config.id, activityTracker: tracker)
        self.controller = controller
        currentSerial = serial
        let window = self.window ?? makeWindow()
        window.contentView = controller.view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(controller.view)
        NSApplication.shared.activate(ignoringOtherApps: true)
        // Rotation: the frames turn W×H ↔ H×W; re-aspect the window.
        session.addObserver { [weak self] event in
            guard case .frameGeometryChanged(let size, _) = event else { return }
            Task { @MainActor in self?.fit(size) }
        }
        try await controller.start()
    }

    private func makeWindow() -> NSWindow {
        let w = CGFloat(config.display.width), h = CGFloat(config.display.height)
        let height: CGFloat = min(860, (NSScreen.main?.visibleFrame.height ?? 900) - 60)
        let size = NSSize(width: (height * w / h).rounded(), height: height)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Emuu — \(config.displayName)"
        window.contentAspectRatio = NSSize(width: w, height: h)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        return window
    }

    private func fit(_ size: VideoSize) {
        guard let window, !size.isEmpty else { return }
        let aspect = NSSize(width: size.width, height: size.height)
        guard window.contentAspectRatio != aspect else { return }
        window.contentAspectRatio = aspect
        let long: CGFloat = min(860, (NSScreen.main?.visibleFrame.height ?? 900) - 60)
        let content = size.width > size.height
            ? NSSize(width: long, height: (long * aspect.height / aspect.width).rounded())
            : NSSize(width: (long * aspect.width / aspect.height).rounded(), height: long)
        window.setContentSize(content)
    }

    /// Stops the stream and closes the window.
    func close() async {
        closing = true
        if let controller {
            await controller.stop()
            controller.invalidate()
        }
        controller = nil
        window?.close()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard !closing else { return }
            onClose()
        }
    }
}
