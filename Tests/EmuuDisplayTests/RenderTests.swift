import Testing
import Foundation
import AVFoundation
import CoreVideo
import EmuuBase
import EmuuGRPC
import EmuuTestSupport
@testable import EmuuDisplay

@Suite struct FrameConverterTests {
    @Test func convertsRGBAToBGRAIntoIOSurfaceBuffers() throws {
        let w = 64, h = 32
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) { rgba[i * 4] = 10; rgba[i * 4 + 1] = 20; rgba[i * 4 + 2] = 30; rgba[i * 4 + 3] = 255 }
        let conv = FrameConverter()
        let pb = try #require(rgba.withUnsafeBytes { conv.convert(rgba: $0.baseAddress!, width: w, height: h) })
        #expect(CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA)
        #expect(CVPixelBufferGetIOSurface(pb) != nil)
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        #expect([p[0], p[1], p[2], p[3]] == [30, 20, 10, 255])
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        #expect(pb.pngData()?.starts(with: [0x89, 0x50, 0x4e, 0x47]) == true)
    }

    @Test func poolIsBoundedUnderBackPressure() {
        let w = 16, h = 16
        let rgba = [UInt8](repeating: 7, count: w * h * 4)
        let conv = FrameConverter(maxOutstanding: 3)
        var held: [CVPixelBuffer] = []
        var nils = 0
        for _ in 0..<10 {
            if let b = rgba.withUnsafeBytes({ conv.convert(rgba: $0.baseAddress!, width: w, height: h) }) { held.append(b) } else { nils += 1 }
        }
        #expect(held.count <= 4)
        #expect(nils >= 6)
        held.removeAll()
        #expect(rgba.withUnsafeBytes { conv.convert(rgba: $0.baseAddress!, width: w, height: h) } != nil)   // recycled
    }

    @Test func frameRateCounterGoesToZeroWhenStatic() {
        var c = FrameRateCounter(window: .seconds(2), capacity: 16)
        let t0 = ContinuousClock.now
        for i in 0..<60 { c.record(t0 + .milliseconds(i * 16)) }
        #expect(c.rate(now: t0 + .milliseconds(960)) > 10)
        #expect(c.rate(now: t0 + .seconds(10)) == 0)
    }
}

@Suite struct FrameRecorderTests {
    func frame(_ w: Int, _ h: Int, _ conv: FrameConverter, at t: ContinuousClock.Instant, value: UInt8) -> DisplayFrame {
        let rgba = [UInt8](repeating: value, count: w * h * 4)
        let pb = rgba.withUnsafeBytes { FrameConverter().convert(rgba: $0.baseAddress!, width: w, height: h)! }
        return DisplayFrame(pixelBuffer: pb, size: VideoSize(width: w, height: h), rotation: w > h ? .landscape : .portrait,
                            deviceTimestampUs: 0, receivedAt: t, seq: 0)
    }

    @Test func encodesH264AndSplitsOnRotation() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("emuu-rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rec.mp4")
        let rec = FrameRecorder(url: url)
        let conv = FrameConverter(maxOutstanding: 16)
        let t0 = ContinuousClock.now
        rec.start()
        for i in 0..<30 {
            let (w, h) = i < 20 ? (160, 320) : (320, 160)
            rec.consume(frame(w, h, conv, at: t0 + .milliseconds(i * 33), value: UInt8(i * 5)))
            try await Task.sleep(for: .milliseconds(15))   // real-time arrival
        }
        try await Task.sleep(for: .milliseconds(300))
        let result = await rec.finish()
        #expect(result.files.map(\.lastPathComponent) == ["rec.mp4", "rec-2.mp4"])
        #expect(result.frameCount + result.droppedFrames == 30)
        #expect(result.frameCount >= 24)
        for (file, size) in zip(result.files, [CGSize(width: 160, height: 320), CGSize(width: 320, height: 160)]) {
            let asset = AVURLAsset(url: file)
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            #expect(try await track.load(.naturalSize) == size)
            let codec = try await track.load(.formatDescriptions).first.map { CMFormatDescriptionGetMediaSubType($0) }
            #expect(codec == kCMVideoCodecType_H264)
        }
    }
}

@Suite struct DisplayActivityTests {
    @Test func policy() {
        let p = DisplayActivityPolicy(pauseAfterHidden: .seconds(1))
        #expect(p.directive(visible: true, hiddenFor: nil) == .stream)
        #expect(p.directive(visible: false, hiddenFor: .milliseconds(500)) == .stream)
        #expect(p.directive(visible: false, hiddenFor: .seconds(1)) == .pause)
        var keep = p
        keep.pauseWhenHidden = false
        #expect(keep.directive(visible: false, hiddenFor: .seconds(3600)) == .stream)
    }

    @Test func trackerReportsVisibilityAndInteraction() async throws {
        let clock = FakeClock()
        let tracker = DisplayActivityTracker(clock: clock)
        let id = try InstanceID(validating: "emuu-dev")
        #expect(await tracker.isDisplayVisible(id) == false)
        #expect(await tracker.lastUserInteraction(id) == nil)
        tracker.setVisible(true, for: id)
        clock.advance(by: .seconds(42))
        tracker.noteInteraction(for: id)
        #expect(await tracker.isDisplayVisible(id))
        #expect(await tracker.lastUserInteraction(id) == clock.monotonicNow())
        tracker.remove(id)
        #expect(await tracker.isDisplayVisible(id) == false)
        tracker.setRecording(true, for: id)
        #expect(await tracker.isDisplayVisible(id))
    }
}

/// Opt-in, against a running engine with `-grpc … -grpc-use-token`:
/// `EMUU_GRPC_PID=<qemu pid> swift test --filter LiveDisplaySessionTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["EMUU_GRPC_PID"] != nil))
struct LiveDisplaySessionTests {
    final class Sink: DisplayFrameSink, @unchecked Sendable {
        let frames = Locked<Int>(0)
        let last = Locked<DisplayFrame?>(nil)
        func consume(_ frame: DisplayFrame) { frames.withLock { $0 += 1 }; last.set(frame) }
    }

    @Test func streamsPausesAndResumes() async throws {
        let pid = Int32(ProcessInfo.processInfo.environment["EMUU_GRPC_PID"]!)!
        let session = EmulatorDisplaySession(endpoint: { EmulatorDiscovery.endpoint(forPID: pid) })
        let sink = Sink()
        session.setFrameSink(sink)
        try await session.start()
        try await Task.sleep(for: .milliseconds(500))
        #expect(sink.frames.current >= 1)          // the current frame arrives at once
        #expect(session.physicalSize != nil)
        await session.pause()
        let paused = sink.frames.current
        try await Task.sleep(for: .milliseconds(500))
        #expect(sink.frames.current == paused)
        let t = ContinuousClock.now
        try await session.resume()
        while sink.frames.current == paused, ContinuousClock.now - t < .seconds(3) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(sink.frames.current > paused)
        let png = try await session.screenshotPNG()
        #expect(png.starts(with: [0x89, 0x50, 0x4e, 0x47]))
        await session.stop()
        print("LIVE session resume→frame \(ContinuousClock.now - t), stats \(session.stats())")
    }
}
