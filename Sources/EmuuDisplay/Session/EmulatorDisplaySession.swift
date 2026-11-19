import Foundation
import EmuuBase
import EmuuGRPC
import CoreVideo

/// The engine's own screen, input and clipboard over its gRPC `EmulatorController` service — the same
/// mechanism Android Studio's embedded emulator uses.
///
/// * **Frames** come from the engine's *host-side* framebuffer (`streamScreenshot`), so windows with
///   `FLAG_SECURE` (sign-in password pages, Play purchase sheets, banking apps) are visible, unlike guest-side
///   capture (`screencap`, scrcpy), which SurfaceFlinger blanks. Pixels are written by the engine into a POSIX
///   shared-memory region (`ImageTransport.MMAP`); only ~100 bytes of metadata per frame cross the socket.
/// * The engine sends a frame **only when the guest screen changes**: a static screen costs no CPU here.
/// * `pause()` closes the frame stream (hidden window); `resume()` reopens it and the current frame arrives at
///   once (no encoder to restart, no frame-rate switching).
/// * Input goes through one ordered `streamInputEvent` client stream (touch, keys, wheel).
///
/// Lifecycle calls are serialized by the actor. `send`, `pressKey`, `stats` and the frame path are synchronous
/// and thread-safe.
public actor EmulatorDisplaySession {
    public typealias EndpointProvider = @Sendable () async -> EmulatorGRPCEndpoint?

    /// How frames travel from the engine and how they are read.
    public struct FrameOptions: Sendable, Hashable {
        public enum Transport: String, Sendable, Hashable, CaseIterable {
            /// Pixels in a shared-memory region (≈100 bytes per frame on the socket). Default.
            case mmap
            /// Pixels inside each gRPC message (≈4.6 MB per 720x1600 frame; atomic, more CPU). Diagnostics.
            case inline
        }
        public var transport: Transport
        /// MMAP only: copy-then-compare so a frame the engine overwrites while it is being read is never shown
        /// (see `FrameConverter.convertStable`). `false` reads the region directly (the pre-fix behaviour;
        /// kept for `emuu debug display-probe --no-validate`).
        public var validateSharedMemory: Bool

        public init(transport: Transport = .mmap, validateSharedMemory: Bool = true) {
            self.transport = transport
            self.validateSharedMemory = validateSharedMemory
        }

        /// MMAP + validation, unless `EMUU_DISPLAY_SHM_VALIDATE=0` (diagnostics: measure the unvalidated path in the
        /// real window).
        public static var `default`: FrameOptions {
            FrameOptions(validateSharedMemory: ProcessInfo.processInfo.environment["EMUU_DISPLAY_SHM_VALIDATE"] != "0")
        }
    }

    private let endpointProvider: EndpointProvider
    private let logger = EmuuLogger(category: "display.session")
    /// State shared with the reader thread and synchronous callers.
    private let shared: SharedState
    public nonisolated let frameOptions: FrameOptions

    public init(endpoint: @escaping EndpointProvider, frameOptions: FrameOptions = .default) {
        self.endpointProvider = endpoint
        self.frameOptions = frameOptions
        self.shared = SharedState(options: frameOptions)
    }

    // MARK: Observation

    public nonisolated var currentState: DisplaySessionState { shared.locked { $0.state } }

    @discardableResult
    public nonisolated func addObserver(_ observer: @escaping @Sendable (DisplaySessionEvent) -> Void) -> UUID {
        let id = UUID()
        shared.locked { $0.observers[id] = observer }
        return id
    }

    public nonisolated func removeObserver(_ id: UUID) {
        shared.locked { $0.observers[id] = nil }
    }

    /// Diagnostics: called (reader thread) for every shared-memory race the validation detects, with the torn
    /// copy. Set before `start()`. nil (default) costs nothing.
    public nonisolated func setRaceObserver(_ observer: (@Sendable (FrameConverter.RaceInfo) -> Void)?) {
        shared.setRaceObserver(observer)
    }

    /// Where frames go (display layer, recorder tee, capture). nil drops them without converting.
    public nonisolated func setFrameSink(_ sink: (any DisplayFrameSink)?) {
        shared.locked { $0.sink = sink }
    }

    public nonisolated func stats() -> DisplayStats {
        shared.locked { s in
            var st = s.stats
            st.framesPerSecond = s.rate.rate(now: .now)
            return st
        }
    }

    /// Physical (unrotated) display size, once connected.
    public nonisolated var physicalSize: VideoSize? { shared.locked { $0.physical } }
    /// Orientation of the last frame.
    public nonisolated var rotation: SkinRotation { shared.locked { $0.stats.rotation } }

    // MARK: Lifecycle

    /// Connects (if needed) and opens the frame stream.
    public func start() async throws {
        try await openFrameStream()
    }

    public func resume() async throws {
        try await openFrameStream()
    }

    /// Closes the frame stream only (input/clipboard stay up). No-op unless streaming.
    public func pause() {
        let handle = shared.locked { s -> GRPCStreamHandle? in
            guard s.state.isActive else { return nil }
            s.generation &+= 1
            let h = s.frameStream
            s.frameStream = nil
            return h
        }
        guard handle != nil || currentState.isActive else { return }
        handle?.cancel()
        setState(.paused)
    }

    /// Closes everything (frame, input, clipboard streams and the connection).
    public func stop() {
        let (controller, streams) = shared.locked { s -> (EmulatorController?, [GRPCStreamHandle]) in
            s.generation &+= 1
            let streams = [s.frameStream, s.inputStream, s.clipboardStream].compactMap { $0 }
            s.frameStream = nil
            s.inputStream = nil
            s.clipboardStream = nil
            let c = s.controller
            s.controller = nil
            s.region = nil
            return (c, streams)
        }
        streams.forEach { $0.cancel() }
        controller?.close()
        setState(.stopped)
    }

    private func setState(_ new: DisplaySessionState) {
        let observers = shared.locked { s -> [@Sendable (DisplaySessionEvent) -> Void] in
            guard s.state != new || new.isFailed else { return [] }
            s.state = new
            return Array(s.observers.values)
        }
        observers.forEach { $0(.stateChanged(new)) }
    }

    private var connectTask: Task<EmulatorController, any Error>?

    /// The connected controller, connecting (and reading the display geometry) when needed. Concurrent
    /// callers share one connection attempt.
    private func connected() async throws -> EmulatorController {
        if let c = shared.locked({ $0.controller }), !c.isClosed { return c }
        if let t = connectTask { return try await t.value }
        let t = Task { try await self.connect() }
        connectTask = t
        defer { connectTask = nil }
        return try await t.value
    }

    private func connect() async throws -> EmulatorController {
        guard let endpoint = await endpointProvider() else {
            throw EmuuError.unsupported("the engine has no gRPC endpoint (it was started without -grpc; restart it with this version of Emuu)")
        }
        let controller: EmulatorController
        do {
            controller = try EmulatorController(endpoint: endpoint) { [weak self] reason in
                Task { await self?.connectionLost(reason) }
            }
        } catch {
            throw EmuuError.io(path: "grpc \(endpoint)", message: "\(error)")
        }
        let status: EmulatorStatus
        do { status = try await controller.status() } catch {
            controller.close()
            throw EmuuError.io(path: "grpc \(endpoint)", message: "\(error)")
        }
        let physical = status.lcdSize.map { VideoSize(width: $0.width, height: $0.height) }
        shared.locked { s in
            s.controller = controller
            s.physical = physical ?? s.physical
            s.inputStream = nil
        }
        logger.info("connected to engine gRPC \(endpoint), \(status.version), display \(physical?.description ?? "?")")
        openClipboardStream(controller)
        return controller
    }

    private func connectionLost(_ reason: String) {
        let wasActive = shared.locked { s -> Bool in
            let active = s.state.isActive
            s.controller = nil
            s.frameStream = nil
            s.inputStream = nil
            s.clipboardStream = nil
            s.generation &+= 1
            return active
        }
        logger.info("engine gRPC connection closed: \(reason)")
        if wasActive { setState(.failed(reason: "engine connection lost (\(reason))")) }
    }

    private func openFrameStream() async throws {
        if currentState == .streaming, shared.locked({ $0.frameStream != nil && !($0.frameStream!.isFinished) }) { return }
        setState(.starting)
        do {
            let controller = try await connected()
            let side = shared.locked { s in max(s.physical?.width ?? 1080, s.physical?.height ?? 2400) }
            let inline = frameOptions.transport == .inline
            let region = try shared.locked { s -> SharedMemoryRegion? in
                if inline { return nil }
                // Square region: frames are delivered already rotated (W×H or H×W), and the engine sizes its
                // mapping from the requested width × height.
                if let r = s.region, r.size >= side * side * 4 { return r }
                let r = try SharedMemoryRegion(size: side * side * 4)
                s.region = r
                return r
            }
            let generation = shared.locked { s -> UInt64 in
                s.generation &+= 1
                s.stats.streamsOpened &+= 1
                return s.generation
            }
            let shared = self.shared
            // Inline: 0×0 asks for the native (rotated) size; MMAP needs an explicit size (0×0 crashed 36.4.9).
            let format = inline ? EmulatorImageFormat(format: .rgba8888)
                                : EmulatorImageFormat(format: .rgba8888, width: side, height: side, mmapHandle: region?.name)
            let handle = try controller.streamScreenshots(format, onImage: { image in
                shared.handleFrame(image, generation: generation)
            }, onEnd: { [weak self] status in
                Task { await self?.frameStreamEnded(status, generation: generation) }
            })
            shared.locked { $0.frameStream = handle }
            setState(.streaming)
        } catch {
            setState(.failed(reason: "\(error.localizedDescription)"))
            throw error
        }
    }

    private func frameStreamEnded(_ status: GRPCStatus, generation: UInt64) {
        let current = shared.locked { s -> Bool in
            guard s.generation == generation else { return false }
            s.frameStream = nil
            return true
        }
        guard current, currentState == .streaming else { return }
        logger.warning("frame stream ended: \(status)")
        setState(.failed(reason: "\(status)"))
    }

    private func openClipboardStream(_ controller: EmulatorController) {
        let shared = self.shared
        let opened = ContinuousClock.now
        let handle = try? controller.streamClipboard(onText: { text in
            // On open the engine sends the current (non-empty) clipboard right away (verified on 36.4.9): that
            // is not a change and must not overwrite the Mac's pasteboard. Host-side setClipboard is not echoed.
            if ContinuousClock.now - opened < .milliseconds(500) { return }
            shared.emit(.clipboardChanged(text))
        }, onEnd: { _ in })
        shared.locked { $0.clipboardStream = handle }
    }

    // MARK: Input (synchronous, any thread)

    /// Sends input events in order over the input stream (opened on first use). Returns false when the engine
    /// is not connected.
    @discardableResult
    public nonisolated func send(_ events: [EmulatorInputEvent]) -> Bool {
        guard !events.isEmpty else { return true }
        for attempt in 0..<2 {
            guard let stream = shared.inputStream() else { return false }
            do {
                for e in events { try stream.send(e.encoded()) }
                return true
            } catch {
                shared.locked { if $0.inputStream === stream { $0.inputStream = nil } }
                if attempt == 1 { return false }
            }
        }
        return false
    }

    @discardableResult
    public nonisolated func pressKey(_ key: DeviceKey) -> Bool {
        send([.key(.key(key.w3cKey, .keydown)), .key(.key(key.w3cKey, .keyup))])
    }

    /// Sets the guest clipboard; with `paste`, also sends Ctrl+V to the focused field (after a short settle: the
    /// guest reads the clipboard when it handles the key). Interactive typing uses `TypingSequencer` instead.
    public func setClipboard(_ text: String, paste: Bool) async throws {
        let c = try await connected()
        try await c.setClipboard(text)
        if paste {
            try? await Task.sleep(for: .milliseconds(40))
            send(KeyEventTranslator().pasteChord)
        }
    }

    public func clipboard() async throws -> String {
        try await connected().clipboard()
    }

    /// PNG of the engine's host framebuffer (secure windows included), encoded by the engine.
    public func screenshotPNG() async throws -> Data {
        let image = try await connected().screenshot(EmulatorImageFormat(format: .png))
        guard !image.image.isEmpty else { throw EmuuError.unsupported("the display is off (empty frame)") }
        return Data(image.image)
    }

    /// Physically rotates the virtual device (sensors). The guest follows when auto-rotate is on.
    public func setRotation(_ rotation: SkinRotation) async throws {
        try await connected().setRotation(EmulatorRotationValue(z: rotation.zAngle))
    }

    /// Current device rotation as the engine reports it in frames (portrait before the first frame).
    public func currentRotation() async throws -> SkinRotation {
        let c = try await connected()
        let z = try await c.rotation().z
        let normalized = ((Int(z.rounded()) % 360) + 360) % 360
        switch normalized {
        case 45..<135: return .landscape
        case 135..<225: return .reversePortrait
        case 225..<315: return .reverseLandscape
        default: return .portrait
        }
    }
}

/// Lock-protected state reachable from the gRPC reader thread.
final class SharedState: @unchecked Sendable {
    struct Fields {
        var state: DisplaySessionState = .idle
        var observers: [UUID: @Sendable (DisplaySessionEvent) -> Void] = [:]
        var controller: EmulatorController?
        var frameStream: GRPCStreamHandle?
        var inputStream: GRPCStreamHandle?
        var clipboardStream: GRPCStreamHandle?
        var region: SharedMemoryRegion?
        var physical: VideoSize?
        var sink: (any DisplayFrameSink)?
        var generation: UInt64 = 0
        var stats = DisplayStats.zero
        var rate = FrameRateCounter()
        var geometry: (VideoSize, SkinRotation)?
        /// Newest frame message not yet converted (latest wins; see `handleFrame`).
        var pendingFrame: PendingFrame?
        var conversionScheduled = false
    }

    struct PendingFrame {
        var image: EmulatorImage
        var generation: UInt64
        var receivedAt: ContinuousClock.Instant
    }

    private let lock = NSLock()
    private var fields = Fields()
    /// Conversion-queue only.
    private let converter = FrameConverter()
    private let options: EmulatorDisplaySession.FrameOptions
    /// Frames are converted here, never on the gRPC reader thread (which also delivers every other reply on the
    /// connection: `setPhysicalModel`, clipboard, status).
    private let conversionQueue = DispatchQueue(label: "emuu.display.convert", qos: .userInteractive)

    init(options: EmulatorDisplaySession.FrameOptions = .default) {
        self.options = options
    }

    /// Set before the stream starts (the converter is reader-thread state).
    func setRaceObserver(_ observer: (@Sendable (FrameConverter.RaceInfo) -> Void)?) {
        converter.raceObserver = observer
    }

    func locked<R>(_ body: (inout Fields) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&fields)
    }

    func emit(_ event: DisplaySessionEvent) {
        let observers = locked { Array($0.observers.values) }
        observers.forEach { $0(event) }
    }

    func inputStream() -> GRPCStreamHandle? {
        locked { s -> GRPCStreamHandle? in
            if let h = s.inputStream, !h.isFinished { return h }
            guard let c = s.controller, !c.isClosed else { return nil }
            s.inputStream = try? c.openInputStream(onEnd: { _ in })
            return s.inputStream
        }
    }

    /// Reader thread: one `Image` from the frame stream. Only records it as the newest frame and wakes the
    /// conversion queue; returns at once.
    ///
    /// Why not convert here: this thread reads the whole HTTP/2 connection. When converting took longer than a
    /// frame interval (debug builds: the validated MMAP read is ≈ 50 ms per 720x1600 frame), frame messages
    /// piled up in the socket, every other reply on the connection waited behind them (the Rotate button's
    /// `setPhysicalModel` hit its 10 s deadline), and the queued messages' sizes were applied to the region's
    /// *current* pixels: portrait metadata over a landscape picture (garbled, window not resized). With MMAP only
    /// the newest message describes the region, so older unconverted messages are superseded (counted as dropped).
    func handleFrame(_ image: EmulatorImage, generation: UInt64) {
        let receivedAt = ContinuousClock.now
        guard !image.isEmpty else { return }   // display off / not yet composed
        let schedule = locked { s -> Bool in
            guard s.generation == generation else { return false }
            if s.pendingFrame != nil { s.stats.droppedFrames &+= 1 }
            s.pendingFrame = PendingFrame(image: image, generation: generation, receivedAt: receivedAt)
            guard !s.conversionScheduled else { return false }
            s.conversionScheduled = true
            return true
        }
        if schedule { conversionQueue.async { self.drainPendingFrames() } }
    }

    /// Conversion queue: converts the newest pending frame until none is left.
    private func drainPendingFrames() {
        while let next = locked({ s -> PendingFrame? in
            let p = s.pendingFrame
            s.pendingFrame = nil
            if p == nil { s.conversionScheduled = false }
            return p
        }) {
            convert(next.image, generation: next.generation, receivedAt: next.receivedAt)
        }
    }

    /// Tests: waits until every frame handed to `handleFrame` so far has been converted (or superseded).
    func waitForPendingConversions() {
        conversionQueue.sync {}
        while locked({ $0.conversionScheduled }) { conversionQueue.sync {} }
    }

    private func convert(_ image: EmulatorImage, generation: UInt64, receivedAt: ContinuousClock.Instant) {
        let w = image.width, h = image.height
        let inline = options.transport == .inline
        let snapshot = locked { s -> (SharedMemoryRegion?, (any DisplayFrameSink)?, Bool)? in
            guard s.generation == generation else { return nil }
            if inline {
                guard image.image.count >= w * h * 4 else { return nil }
            } else {
                guard let region = s.region, w * h * 4 <= region.size else { return nil }
            }
            s.rate.record(receivedAt)
            s.stats.totalFrames &+= 1
            let size = VideoSize(width: w, height: h)
            s.stats.videoSize = size
            s.stats.rotation = image.format.rotation
            let nowUs = UInt64(Date().timeIntervalSince1970 * 1_000_000)
            if image.timestampUs > 0, nowUs >= image.timestampUs {
                s.stats.lastTransportLatencyMs = Double(nowUs - image.timestampUs) / 1000
            }
            let changed = s.geometry.map { $0.0 != size || $0.1 != image.format.rotation } ?? true
            if changed { s.geometry = (size, image.format.rotation) }
            return (s.region, s.sink, changed)
        }
        guard let (region, sink, changed) = snapshot else { return }
        if changed { emit(.frameGeometryChanged(VideoSize(width: w, height: h), image.format.rotation)) }
        guard let sink else { return }
        var attempts = 1
        let buffer: CVPixelBuffer?
        if inline {
            buffer = image.image.withUnsafeBytes { converter.convert(rgba: $0.baseAddress!, width: w, height: h) }
        } else if let region, options.validateSharedMemory {
            if converter.raceObserver != nil {
                let nowUs = UInt64(Date().timeIntervalSince1970 * 1_000_000)
                let late = image.timestampUs > 0 && nowUs >= image.timestampUs ? Double(nowUs - image.timestampUs) / 1000 : -1
                converter.raceContext = String(format: "seq %u, engine→read %.1f ms", image.seq, late)
            }
            switch converter.convertStable(rgba: region.base, width: w, height: h) {
            case .frame(let b, let n):
                buffer = b
                attempts = n
            case .poolExhausted:
                buffer = nil
            case .unstable(let n):
                locked { $0.stats.racedFrames &+= 1; $0.stats.unstableFrames &+= 1; $0.stats.droppedFrames &+= 1 }
                _ = n
                return
            }
        } else if let region {
            buffer = converter.convert(rgba: region.base, width: w, height: h)
        } else {
            buffer = nil
        }
        guard let buffer else {
            locked { $0.stats.droppedFrames &+= 1 }
            return
        }
        if attempts > 1 { locked { $0.stats.racedFrames &+= 1 } }
        sink.consume(DisplayFrame(pixelBuffer: buffer, size: VideoSize(width: w, height: h), rotation: image.format.rotation,
                                  deviceTimestampUs: image.timestampUs, receivedAt: receivedAt, seq: image.seq,
                                  convertedAt: .now))
    }
}
