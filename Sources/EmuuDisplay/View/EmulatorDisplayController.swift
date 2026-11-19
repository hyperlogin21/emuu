import AppKit
import SwiftUI
import Observation
import EmuuBase
import EmuuGRPC

/// Glue between an `EmulatorDisplaySession` and an `EmulatorDisplayView`: installs the renderer, routes
/// input, mirrors session events for SwiftUI, bridges the clipboard, reports activity to the governor and
/// applies the visibility policy (close the frame stream while hidden, reopen when shown).
@MainActor
@Observable
public final class EmulatorDisplayController {
    public let session: EmulatorDisplaySession
    public let view: EmulatorDisplayView
    public let instanceID: InstanceID?

    public private(set) var state: DisplaySessionState = .idle
    /// Size of the frames shown (rotated as the device is held).
    public private(set) var videoSize: VideoSize?
    public private(set) var rotation: SkinRotation = .portrait
    /// Refreshed once per second while visible.
    public private(set) var stats: DisplayStats = .zero
    public private(set) var isVisible = false
    public private(set) var isFocused = false
    public private(set) var recordingURL: URL?
    public private(set) var recordingStartedAt: Date?
    public var isRecording: Bool { recorder != nil }

    public var policy: DisplayActivityPolicy {
        didSet { scheduleDirective() }
    }

    @ObservationIgnored private let tracker: DisplayActivityTracker?
    @ObservationIgnored private let clock: any EmuuClock
    @ObservationIgnored private var observerID: UUID?
    @ObservationIgnored private var hiddenSince: Duration?
    @ObservationIgnored private var directiveTask: Task<Void, Never>?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var wantsRunning = false
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryAttempts = 0
    /// Bounded automatic reconnects after the stream fails while visible (engine hibernated/resumed or
    /// restarted). Delays double from `retryBaseDelay`, capped at 30 s.
    public var maxRetries = 10
    public var retryBaseDelay: Duration = .seconds(1)
    @ObservationIgnored private let logger = EmuuLogger(category: "display.controller")
    @ObservationIgnored private var recorder: FrameRecorder?
    /// `EMUU_DISPLAY_DIAG` set: analyses presented frames and logs counts (see DisplayDiagnosticsMonitor).
    @ObservationIgnored private var diagnostics: DisplayDiagnosticsMonitor?

    public init(session: EmulatorDisplaySession, instanceID: InstanceID? = nil, activityTracker: DisplayActivityTracker? = nil,
                policy: DisplayActivityPolicy = DisplayActivityPolicy(), clock: any EmuuClock = SystemClock()) {
        self.session = session
        self.instanceID = instanceID
        self.tracker = activityTracker
        self.policy = policy
        self.clock = clock
        self.view = EmulatorDisplayView(frame: NSRect(x: 0, y: 0, width: 360, height: 800))
        wire()
    }

    private func wire() {
        let session = self.session
        session.setFrameSink(view.frameSink)
        view.sendInput = { events in session.send(events) }
        view.pressKey = { key in session.pressKey(key) }
        view.onRotate = { [weak self] in self?.rotate() }
        view.setDeviceClipboard = { text, paste in
            Task { try? await session.setClipboard(text, paste: paste) }
        }
        view.requestDeviceCopy = { cut in
            // Ctrl+C / Ctrl+X in the focused field; the clipboard stream brings the result to the host.
            let key: UInt16 = cut ? 0x07 : 0x08   // kVK_ANSI_X / kVK_ANSI_C
            session.send([.key(.macKey(0x3B, .keydown)), .key(.macKey(key, .keypress)), .key(.macKey(0x3B, .keyup))])
        }
        view.onUserInteraction = { [weak self] in
            guard let self, let id = self.instanceID else { return }
            self.tracker?.noteInteraction(for: id)
        }
        view.onVisibilityChange = { [weak self] visible, focused in
            self?.visibilityChanged(visible: visible, focused: focused)
        }
        observerID = session.addObserver { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        if let diag = DisplayDiagnosticsMonitor.fromEnvironment(label: instanceID?.rawValue ?? "display") {
            diag.attach(renderer: view.frameSink, session: session)
            diagnostics = diag
            // Keep streaming while the window is covered, so the run is not interrupted by occlusion.
            policy.pauseWhenHidden = false
        }
    }

    /// Starts the frame stream.
    public func start() async throws {
        wantsRunning = true
        try await session.start()
        startStatsLoop()
        scheduleDirective()
    }

    /// Restarts a stream that failed or was stopped; resets the retry budget.
    public func restart() async throws {
        wantsRunning = true
        retryTask?.cancel()
        retryAttempts = 0
        if session.currentState != .streaming { try await session.resume() }
        startStatsLoop()
        scheduleDirective()
    }

    public func stop() async {
        if recorder != nil { _ = await stopRecording() }
        wantsRunning = false
        retryTask?.cancel()
        directiveTask?.cancel()
        statsTask?.cancel()
        view.releaseAllInput()
        diagnostics?.log(renderer: view.frameSink, session: session)
        await session.stop()
    }

    // MARK: Device actions

    @discardableResult
    public func press(_ key: DeviceKey) -> Bool { session.pressKey(key) }

    /// Rotate button / ⌘R: portrait ↔ landscape (from whatever the device shows now).
    public func rotate() {
        let next: SkinRotation = rotation.isLandscape ? .portrait : .landscape
        rotate(to: next)
    }

    public func rotate(to target: SkinRotation) {
        let session = self.session
        Task { [weak self] in
            do { try await session.setRotation(target) } catch {
                self?.logger.warning("rotate failed: \(error.localizedDescription)")
            }
        }
    }

    /// The frame currently on screen as PNG (exactly what the display pipeline received).
    public func currentFramePNG() -> Data? {
        view.frameSink.currentFrame?.pixelBuffer.pngData()
    }

    // MARK: Recording

    /// Starts H.264 encoding of the frames to `url`. While recording the stream stays open whatever the
    /// window does, and the activity tracker reports the instance as visible (no freeze/hibernate).
    public func startRecording(to url: URL) async throws {
        guard recorder == nil else { throw EmuuError.invalidConfiguration("already recording") }
        let rec = FrameRecorder(url: url)
        recorder = rec
        recordingURL = url
        recordingStartedAt = Date()
        if let id = instanceID { tracker?.setRecording(true, for: id) }
        session.setFrameSink(TeeFrameSink([view.frameSink, rec]))
        wantsRunning = true
        directiveTask?.cancel()
        do {
            if session.currentState != .streaming { try await session.resume() }
        } catch {
            _ = await stopRecording()
            throw error
        }
        rec.start(seed: view.frameSink.currentFrame)
        startStatsLoop()
        logger.notice("recording started → \(url.path)")
    }

    @discardableResult
    public func stopRecording() async -> RecordingResult? {
        guard let rec = recorder else { return nil }
        recorder = nil
        recordingURL = nil
        recordingStartedAt = nil
        session.setFrameSink(view.frameSink)
        if let id = instanceID { tracker?.setRecording(false, for: id) }
        let result = await rec.finish()
        logger.notice("recording stopped: \(result.frameCount) frames, \(result.files.count) file(s)")
        if wantsRunning { scheduleDirective() }
        return result
    }

    /// Detaches from the session (call before discarding the controller).
    public func invalidate() {
        if let observerID { session.removeObserver(observerID) }
        session.setFrameSink(nil)
        retryTask?.cancel()
        directiveTask?.cancel()
        statsTask?.cancel()
        diagnostics?.stop()
        view.frameSink.clear()
        if let id = instanceID { tracker?.remove(id) }
    }

    private func handle(_ event: DisplaySessionEvent) {
        switch event {
        case .stateChanged(let s):
            state = s
            switch s {
            case .streaming: retryAttempts = 0
            case .failed: scheduleRetry()
            default: break
            }
        case .frameGeometryChanged(let size, let rot):
            videoSize = size
            rotation = rot
            view.setGeometry(frame: size, rotation: rot, physical: session.physicalSize)
        case .clipboardChanged(let text):
            guard view.hostClipboardEnabled else { return }
            let pb = NSPasteboard.general
            if pb.string(forType: .string) != text {
                pb.clearContents()
                pb.setString(text, forType: .string)
            }
        }
    }

    private func visibilityChanged(visible: Bool, focused: Bool) {
        isFocused = focused
        if visible != isVisible {
            isVisible = visible
            if visible {
                retryAttempts = 0
                if session.currentState.isFailed { retryTask?.cancel() }
            }
            hiddenSince = visible ? nil : clock.monotonicNow()
            if let id = instanceID { tracker?.setVisible(visible, for: id) }
            if visible { startStatsLoop() } else { statsTask?.cancel() }
        } else if !visible && hiddenSince == nil {
            hiddenSince = clock.monotonicNow()
            if let id = instanceID { tracker?.setVisible(false, for: id) }
        }
        scheduleDirective()
    }

    /// Re-evaluates the policy: showing reopens at once; hiding closes after `pauseAfterHidden`.
    private func scheduleDirective() {
        directiveTask?.cancel()
        guard wantsRunning else { return }
        if recorder != nil {
            directiveTask = Task { [weak self] in await self?.apply(.stream) }
            return
        }
        let hiddenFor = hiddenSince.map { clock.monotonicNow() - $0 }
        let directive = policy.directive(visible: isVisible, hiddenFor: hiddenFor)
        if directive == .stream, !isVisible, policy.pauseWhenHidden {
            let remaining = policy.pauseAfterHidden - (hiddenFor ?? .zero)
            directiveTask = Task { [weak self, clock] in
                try? await clock.sleep(for: max(remaining, .zero))
                guard !Task.isCancelled else { return }
                self?.scheduleDirective()
            }
            return
        }
        directiveTask = Task { [weak self] in await self?.apply(directive) }
    }

    private func apply(_ directive: DisplayStreamDirective) async {
        do {
            switch directive {
            case .pause:
                if session.currentState.isActive {
                    view.releaseAllInput()
                    logger.info("display hidden: closing frame stream")
                }
                await session.pause()
            case .stream:
                if session.currentState != .streaming {
                    logger.info("display visible: opening frame stream")
                    try await session.resume()
                }
            }
        } catch {
            logger.warning("display policy action failed: \(error.localizedDescription)")
        }
    }

    /// After a failure: retry while wanted and visible (or recording), with bounded backoff.
    private func scheduleRetry() {
        retryTask?.cancel()
        guard wantsRunning, isVisible || recorder != nil, retryAttempts < maxRetries else { return }
        retryAttempts += 1
        let delay = min(retryBaseDelay * (1 << min(retryAttempts - 1, 10)), .seconds(30))
        let attempt = retryAttempts
        logger.info("display stream failed; reconnect \(attempt)/\(maxRetries) in \(delay)")
        retryTask = Task { [weak self, clock] in
            try? await clock.sleep(for: delay)
            guard !Task.isCancelled, let self, self.wantsRunning, self.isVisible || self.recorder != nil,
                  self.session.currentState.isFailed else { return }
            do { try await self.session.resume() } catch {
                self.logger.info("reconnect \(attempt) failed: \(error.localizedDescription)")
            }
        }
    }

    private func startStatsLoop() {
        statsTask?.cancel()
        statsTask = Task { [weak self, clock] in
            while !Task.isCancelled {
                guard let self else { return }
                let fresh = self.session.stats()
                if fresh != self.stats { self.stats = fresh }
                try? await clock.sleep(for: .seconds(1))
            }
        }
    }
}

/// SwiftUI wrapper around the controller's view.
public struct EmulatorDisplay: NSViewRepresentable {
    public let controller: EmulatorDisplayController

    public init(controller: EmulatorDisplayController) {
        self.controller = controller
    }

    public func makeNSView(context: Context) -> EmulatorDisplayView {
        controller.view
    }

    public func updateNSView(_ nsView: EmulatorDisplayView, context: Context) {}
}
