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
    private let counters = Locked(PresentationStats())

    /// What the sink did with the frames it was given.
    public struct PresentationStats: Sendable, Hashable {
        public var received = 0
        /// Put on the layer.
        public var presented = 0
        /// Replaced by a newer frame before the main thread got to it (the main thread was busy).
        public var coalesced = 0
        /// Presented frames with a sequence number lower than the frame shown before (must stay 0).
        public var outOfOrder = 0
    }

    public var presentationStats: PresentationStats { counters.withLock { $0 } }
    private var lastPresentedSeq: UInt32?

    public init(layer: CALayer) {
        self.layer = layer
    }

    public func consume(_ frame: DisplayFrame) {
        let replaced = pending.withLock { p -> Bool in
            defer { p = frame }
            return p != nil
        }
        counters.withLock { c in
            c.received += 1
            if replaced { c.coalesced += 1 }
        }
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
        // seq restarts at 0/1 with every new frame stream (resume); that is not a step back.
        let backwards = lastPresentedSeq.map { frame.seq > 1 && frame.seq < $0 } ?? false
        lastPresentedSeq = frame.seq
        counters.withLock { c in
            c.presented += 1
            if backwards { c.outOfOrder += 1 }
        }
        onPresent?(frame)
    }

    /// The frame currently on screen (main thread).
    @MainActor
    public var currentFrame: DisplayFrame? { shown }

    /// Drops the retained frames and clears the layer (main thread).
    @MainActor
    public func clear() {
        pending.set(nil)
        lastPresentedSeq = nil
        shown = nil
        previous = nil
        layer?.contents = nil
    }
}
