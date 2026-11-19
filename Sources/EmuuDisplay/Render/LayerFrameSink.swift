import Foundation
import QuartzCore
import CoreVideo
import EmuuBase

/// Shows frames by setting the pixel buffer's IOSurface as a `CALayer`'s contents: zero-copy to the
/// window server, no decoder, no Metal pipeline.
///
/// Frames arrive on the gRPC reader thread; at most one main-queue hop is pending at a time and only the
/// newest frame is shown (older pending ones are replaced, so a busy main thread never queues frames). The
/// sink keeps the shown buffer and the one before it (the compositor may still be reading it); there is no
/// other frame history.
public final class LayerFrameSink: DisplayFrameSink, @unchecked Sendable {
    private weak var layer: CALayer?
    private let pending = Locked<DisplayFrame?>(nil)
    private let scheduled = Locked(false)
    /// Main thread only.
    private var shown: DisplayFrame?
    private var previous: DisplayFrame?
    /// Called on the main thread after a frame was put on screen (latency measurement, first-frame signal).
    public var onPresent: (@MainActor (DisplayFrame) -> Void)?

    public init(layer: CALayer) {
        self.layer = layer
    }

    public func consume(_ frame: DisplayFrame) {
        pending.set(frame)
        let needsHop = scheduled.withLock { s -> Bool in
            if s { return false }
            s = true
            return true
        }
        guard needsHop else { return }
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { present() }
        }
    }

    @MainActor
    private func present() {
        scheduled.set(false)
        guard let frame = pending.withLock({ p -> DisplayFrame? in defer { p = nil }; return p }) else { return }
        guard let layer, let surface = CVPixelBufferGetIOSurface(frame.pixelBuffer)?.takeUnretainedValue() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = surface
        CATransaction.commit()
        previous = shown
        shown = frame
        onPresent?(frame)
    }

    /// The frame currently on screen (main thread).
    @MainActor
    public var currentFrame: DisplayFrame? { shown }

    /// Drops the retained frames and clears the layer (main thread).
    @MainActor
    public func clear() {
        pending.set(nil)
        shown = nil
        previous = nil
        layer?.contents = nil
    }
}
