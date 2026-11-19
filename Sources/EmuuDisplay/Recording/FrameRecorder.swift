import Foundation
import AVFoundation
import CoreVideo
import EmuuBase

/// Result of a recording.
public struct RecordingResult: Sendable, Hashable {
    /// One file per segment, in order. A frame-size change (rotation) starts a new segment.
    public var files: [URL]
    public var frameCount: Int
    /// Sum of the segments' durations.
    public var duration: Duration
    /// Frames skipped because the encoder was busy.
    public var droppedFrames: Int

    public init(files: [URL], frameCount: Int, duration: Duration, droppedFrames: Int) {
        self.files = files
        self.frameCount = frameCount
        self.duration = duration
        self.droppedFrames = droppedFrames
    }
}

/// Encodes display frames to H.264 MP4 with `AVAssetWriter` (VideoToolbox hardware encoder) — only while a
/// recording runs; nothing is encoded otherwise.
///
/// * Timestamps are host receive times relative to the first frame, so a static screen (no frames) still
///   gives a correctly timed file; at the end the last frame is repeated at the stop time so the file's
///   duration matches the wall time.
/// * A frame-size change (rotation) finishes the segment and starts `<name>-2.mp4`, `-3`, …
/// * Back-pressure: if the encoder is not ready the frame is dropped (bounded memory).
public final class FrameRecorder: DisplayFrameSink, @unchecked Sendable {
    public let baseURL: URL
    private let queue = DispatchQueue(label: "emuu.recorder", qos: .userInitiated)
    private let lock = NSLock()
    private var started = false
    private var finished = false
    private var segment: Segment?
    private var files: [URL] = []
    private var frames = 0
    private var dropped = 0
    private var total: Duration = .zero
    private var lastFrame: DisplayFrame?
    private let log = EmuuLogger(category: "display.recorder")

    private final class Segment {
        let url: URL
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let size: VideoSize
        let origin: ContinuousClock.Instant
        var lastTime: CMTime = .invalid

        init(url: URL, size: VideoSize, origin: ContinuousClock.Instant) throws {
            self.url = url
            self.size = size
            self.origin = origin
            try? FileManager.default.removeItem(at: url)
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let pixels = Double(size.width * size.height)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: size.width,
                AVVideoHeightKey: size.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Int(pixels * 60 * 0.1),   // ~7 Mbit/s at 720x1600
                    AVVideoExpectedSourceFrameRateKey: 60,
                    AVVideoMaxKeyFrameIntervalDurationKey: 2,
                    AVVideoAllowFrameReorderingKey: false,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ]
            input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? EmuuError.io(path: url.path, message: "cannot start writing") }
            writer.startSession(atSourceTime: .zero)
        }

        func time(_ t: ContinuousClock.Instant) -> CMTime {
            let d = t - origin
            let ns = d.components.seconds * 1_000_000_000 + d.components.attoseconds / 1_000_000_000
            return CMTime(value: max(ns, 0), timescale: 1_000_000_000)
        }
    }

    public init(url: URL) {
        self.baseURL = url
    }

    /// Frames are accepted from now on. `seed` (the frame on screen) starts the file immediately, so a static
    /// screen is recorded too.
    public func start(seed: DisplayFrame? = nil) {
        lock.withLock { started = true }
        if let seed {
            consume(DisplayFrame(pixelBuffer: seed.pixelBuffer, size: seed.size, rotation: seed.rotation,
                                 deviceTimestampUs: seed.deviceTimestampUs, receivedAt: .now, seq: seed.seq))
        }
    }

    public func consume(_ frame: DisplayFrame) {
        guard lock.withLock({ started && !finished }) else { return }
        queue.async { [self] in append(frame) }
    }

    private func segmentURL(_ index: Int) -> URL {
        guard index > 1 else { return baseURL }
        let stem = baseURL.deletingPathExtension().lastPathComponent
        return baseURL.deletingLastPathComponent().appendingPathComponent("\(stem)-\(index).\(baseURL.pathExtension)")
    }

    /// Recorder queue.
    private func append(_ frame: DisplayFrame) {
        guard lock.withLock({ !finished }) else { return }
        if let s = segment, s.size != frame.size {
            close(s, at: frame.receivedAt)
            segment = nil
        }
        if segment == nil {
            do {
                segment = try Segment(url: segmentURL(files.count + 1), size: frame.size, origin: frame.receivedAt)
                files.append(segment!.url)
            } catch {
                log.error("recording segment failed: \(error.localizedDescription)")
                return
            }
        }
        guard let s = segment else { return }
        var t = s.time(frame.receivedAt)
        if s.lastTime.isValid, t <= s.lastTime { t = s.lastTime + CMTime(value: 1, timescale: 1000) }
        guard s.input.isReadyForMoreMediaData, s.adaptor.append(frame.pixelBuffer, withPresentationTime: t) else {
            lock.withLock { dropped += 1 }
            return
        }
        s.lastTime = t
        lastFrame = frame
        lock.withLock { frames += 1 }
    }

    /// Recorder queue: repeat the last frame at `end` (static tail), then finalize.
    private func close(_ s: Segment, at end: ContinuousClock.Instant) {
        let endTime = s.time(end)
        if let last = lastFrame, s.lastTime.isValid, endTime > s.lastTime + CMTime(value: 1, timescale: 100) {
            while !s.input.isReadyForMoreMediaData { usleep(2000) }
            if s.adaptor.append(last.pixelBuffer, withPresentationTime: endTime) { s.lastTime = endTime }
        }
        s.input.markAsFinished()
        let sema = DispatchSemaphore(value: 0)
        s.writer.endSession(atSourceTime: s.lastTime.isValid ? s.lastTime : .zero)
        s.writer.finishWriting { sema.signal() }
        sema.wait()
        if s.writer.status != .completed {
            log.error("recording finalize failed: \(s.writer.error?.localizedDescription ?? "status \(s.writer.status.rawValue)")")
        }
        let secs = s.lastTime.isValid ? s.lastTime.seconds : 0
        lock.withLock { total += .milliseconds(Int(secs * 1000)) }
        lastFrame = nil
    }

    /// Stops and finalizes every segment.
    public func finish() async -> RecordingResult {
        let end = ContinuousClock.now
        lock.withLock { finished = true }
        return await withCheckedContinuation { cont in
            queue.async { [self] in
                if let s = segment { close(s, at: end) }
                segment = nil
                let written = files.filter { FileManager.default.fileExists(atPath: $0.path) }
                let r = lock.withLock { RecordingResult(files: written, frameCount: frames, duration: total, droppedFrames: dropped) }
                cont.resume(returning: r)
            }
        }
    }
}
