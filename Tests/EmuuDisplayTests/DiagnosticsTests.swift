import Testing
import Foundation
import CoreVideo
import IOSurface
import EmuuBase
import EmuuGRPC
@testable import EmuuDisplay

/// Draws the scripts/flicker-test pattern for counter `n` (BGRA) into a `screenW × screenH` canvas, the
/// picture `w × h` at (`ox`, `oy`) on black — like a letterboxed video on the device screen.
struct PatternCanvas {
    let screenW: Int, screenH: Int
    var bytes: [UInt8]

    init(screenW: Int, screenH: Int) {
        self.screenW = screenW
        self.screenH = screenH
        bytes = [UInt8](repeating: 0, count: screenW * screenH * 4)
        for i in 0..<(screenW * screenH) { bytes[i * 4 + 3] = 255 }
    }

    mutating func fill(_ x0: Int, _ y0: Int, _ w: Int, _ h: Int, _ c: (UInt8, UInt8, UInt8)) {
        for y in max(0, y0)..<min(screenH, y0 + h) {
            for x in max(0, x0)..<min(screenW, x0 + w) {
                let i = (y * screenW + x) * 4
                bytes[i] = c.2; bytes[i + 1] = c.1; bytes[i + 2] = c.0; bytes[i + 3] = 255
            }
        }
    }

    static let palette: [(UInt8, UInt8, UInt8)] = [(0, 0, 0), (255, 0, 0), (0, 255, 0), (0, 0, 255),
                                                   (255, 255, 0), (0, 255, 255), (255, 0, 255), (255, 255, 255)]

    mutating func drawPattern(_ n: Int, x ox: Int = 0, y oy: Int = 0, w W: Int, h H: Int) {
        let border = max(4, W / 40), cell = W / 10
        let g = UInt8(40 + (n * 7) % 160)
        fill(ox, oy, W, H, (g, g, g))
        let (origins, c) = TestPattern.markers(width: Double(W), height: Double(H))
        _ = c
        for o in origins {
            let x = ox + Int(o.0), y = oy + Int(o.1)
            fill(x - cell / 8, y - cell / 8, 3 * cell + cell / 4, cell + cell / 4, (128, 128, 128))
            for k in 0..<3 { fill(x + k * cell, y, cell, cell, Self.palette[(n >> (3 * (2 - k))) & 7]) }
        }
        fill(ox, oy, W, border, (255, 0, 255)); fill(ox, oy + H - border, W, border, (255, 0, 255))
        fill(ox, oy, border, H, (255, 0, 255)); fill(ox + W - border, oy, border, H, (255, 0, 255))
    }

    func withPixels<R>(_ body: (BGRAPixels) -> R) -> R {
        bytes.withUnsafeBytes { body(BGRAPixels(base: $0.baseAddress!, width: screenW, height: screenH, bytesPerRow: screenW * 4)) }
    }
}

@Suite struct FrameAnalyzerTests {
    static let W = 360, H = 800

    func frame(_ n: Int) -> PatternCanvas {
        var c = PatternCanvas(screenW: Self.W, screenH: Self.H)
        c.drawPattern(n, x: 0, y: 80, w: 360, h: 640)   // 9:16 video letterboxed on a 9:20 screen
        return c
    }

    @Test func locatesAndDecodesTheLetterboxedPattern() throws {
        let f = frame(300)
        let rect = try #require(f.withPixels { TestPattern.locate($0) })
        #expect(rect == PatternRect(x: 0, y: 80, width: 360, height: 640))
        #expect(f.withPixels { TestPattern.decode($0, in: rect) } == [300, 300, 300, 300, 300])
    }

    @Test func cleanSequenceHasNoArtefacts() {
        let a = FrameAnalyzer()
        let t0 = ContinuousClock.now
        for n in 0..<40 {
            _ = frame(n % 512).withPixels { a.analyze($0, seq: UInt32(n), arrival: t0 + .milliseconds(n * 16)) }
        }
        let s = a.finish()
        #expect(s.frames == 40 && s.patternFrames == 40 && s.artefacts == 0 && s.duplicates == 0 && s.skippedCounters == 0)
    }

    @Test func countsTornOutOfOrderBlankAndFlash() {
        let a = FrameAnalyzer()
        var t = ContinuousClock.now
        func feed(_ c: PatternCanvas, _ seq: Int) -> FrameVerdict {
            t = t + .milliseconds(16)
            return c.withPixels { a.analyze($0, seq: UInt32(seq), arrival: t) }.0
        }
        _ = feed(frame(10), 1)
        // Torn: top half (incl. top markers) from 11, bottom half from 12.
        var torn = frame(11)
        let bottom = frame(12)
        let half = Self.H / 2 * Self.W * 4
        torn.bytes.replaceSubrange(half..., with: bottom.bytes[half...])
        #expect(feed(torn, 2).kinds == [.torn])
        _ = feed(frame(12), 3)
        #expect(feed(frame(5), 4).kinds.contains(.outOfOrder))
        _ = feed(frame(13), 5)
        let black = PatternCanvas(screenW: Self.W, screenH: Self.H)
        #expect(feed(black, 6).kinds.isSuperset(of: [.blank, .patternLost]))
        _ = feed(frame(14), 7)
        let s = a.finish()
        #expect(s.torn == 1 && s.outOfOrder == 1 && s.blank == 1 && s.patternLost == 1)
        #expect(s.flash >= 1)   // 13 → black → 14 is an A-B-A flash
    }

    @Test func oneCoveredMarkerIsNotATear() {
        let a = FrameAnalyzer()
        var f = frame(42)
        f.fill(24, 80 + 640 - 80, 140, 60, (0, 255, 255))   // UI drawn over the bottom-left marker (not the border)
        let v = f.withPixels { a.analyze($0, seq: 1, arrival: .now) }.0
        #expect(v.counter == 42)
        #expect(!v.kinds.contains(.torn))
    }

    @Test func duplicatesAndSkipsAreCountedNotFlagged() {
        let a = FrameAnalyzer()
        let t0 = ContinuousClock.now
        for (i, n) in [1, 1, 2, 4, 5].enumerated() {
            _ = frame(n).withPixels { a.analyze($0, seq: UInt32(i), arrival: t0 + .milliseconds(i * 16)) }
        }
        let s = a.finish()
        #expect(s.duplicates == 1 && s.skippedCounters == 1 && s.artefacts == 0)
    }

    @Test func wrapsAroundThePeriod() {
        let a = FrameAnalyzer()
        let t0 = ContinuousClock.now
        for (i, n) in [510, 511, 0, 1].enumerated() {
            _ = frame(n).withPixels { a.analyze($0, seq: UInt32(i), arrival: t0 + .milliseconds(i * 16)) }
        }
        #expect(a.finish().artefacts == 0)
    }
}

@Suite struct StableConversionTests {
    func rgba(_ w: Int, _ h: Int, value: UInt8) -> [UInt8] { [UInt8](repeating: value, count: w * h * 4) }

    func firstByte(_ b: CVPixelBuffer) -> UInt8 {
        b.withBGRAPixels { $0.base.load(as: UInt8.self) }!
    }

    @Test func stableRegionConvertsInOneAttempt() throws {
        let src = rgba(32, 16, value: 9)
        let conv = FrameConverter()
        let r = src.withUnsafeBytes { conv.convertStable(rgba: $0.baseAddress!, width: 32, height: 16) }
        guard case .frame(let b, let attempts) = r else { Issue.record("expected a frame"); return }
        #expect(attempts == 1)
        #expect(firstByte(b) == 9)
    }

    @Test func aWriteDuringTheCopyIsDetectedAndReRead() throws {
        let w = 32, h = 16
        let region = UnsafeMutableRawPointer.allocate(byteCount: w * h * 4, alignment: 64)
        defer { region.deallocate() }
        memset(region, 1, w * h * 4)
        let conv = FrameConverter()
        var writes = 0
        conv.afterCopyForTesting = {
            // The engine writes the next frame (value 2) between our copy and our compare — once.
            if writes == 0 { memset(region.advanced(by: w * h * 2), 2, w * h * 2) }   // only the bottom half so far
            writes += 1
        }
        let r = conv.convertStable(rgba: region, width: w, height: h)
        guard case .frame(let b, let attempts) = r else { Issue.record("expected a frame"); return }
        #expect(attempts == 2)
        // The second copy is consistent: top still 1, bottom 2 — what the region holds now, compared equal.
        b.withBGRAPixels { px in
            #expect(px.base.load(as: UInt8.self) == 1)
            #expect(px.base.load(fromByteOffset: (h - 1) * px.bytesPerRow, as: UInt8.self) == 2)
        }
    }

    @Test func aRegionThatNeverSettlesIsDropped() {
        let w = 8, h = 8
        let region = UnsafeMutableRawPointer.allocate(byteCount: w * h * 4, alignment: 64)
        defer { region.deallocate() }
        memset(region, 0, w * h * 4)
        let conv = FrameConverter()
        var v: UInt8 = 0
        conv.afterCopyForTesting = { v &+= 1; memset(region, Int32(v), w * h * 4) }
        guard case .unstable(let attempts) = conv.convertStable(rgba: region, width: w, height: h, maxAttempts: 3) else {
            Issue.record("expected unstable"); return
        }
        #expect(attempts == 3)
    }

    @Test func swappedCompareFindsASingleChangedPixelAtAnyWidth() {
        for w in [1, 7, 8, 33] {
            let h = 3
            var rgba = [UInt8](repeating: 0, count: w * h * 4)
            for i in 0..<(w * h) { rgba[i * 4] = UInt8(i & 255); rgba[i * 4 + 1] = 2; rgba[i * 4 + 2] = 200; rgba[i * 4 + 3] = 255 }
            let conv = FrameConverter()
            let pb = rgba.withUnsafeBytes { conv.convert(rgba: $0.baseAddress!, width: w, height: h)! }
            #expect(rgba.withUnsafeBytes { src in pb.withBGRAPixels { FrameConverter.matches(bgra: $0, rgba: src.baseAddress!) }! })
            rgba[(w * h - 1) * 4 + 2] = 201   // last pixel's blue
            #expect(!rgba.withUnsafeBytes { src in pb.withBGRAPixels { FrameConverter.matches(bgra: $0, rgba: src.baseAddress!) }! })
        }
    }

    /// The pool must not hand out a buffer whose IOSurface is still in use (Core Animation / the window
    /// server mark the surface they show); recycling is only safe because of this.
    @Test func poolSkipsSurfacesStillInUse() throws {
        let src = rgba(16, 16, value: 3)
        let conv = FrameConverter()
        var first: CVPixelBuffer? = src.withUnsafeBytes { conv.convert(rgba: $0.baseAddress!, width: 16, height: 16) }
        let surface = try #require(CVPixelBufferGetIOSurface(first!)?.takeUnretainedValue())
        let id = IOSurfaceGetID(surface)
        IOSurfaceIncrementUseCount(surface)
        first = nil
        let next = try #require(src.withUnsafeBytes { conv.convert(rgba: $0.baseAddress!, width: 16, height: 16) })
        #expect(IOSurfaceGetID(CVPixelBufferGetIOSurface(next)!.takeUnretainedValue()) != id)
        IOSurfaceDecrementUseCount(surface)
    }
}

@Suite @MainActor struct PresentationTests {
    func frame(seq: UInt32) -> DisplayFrame {
        let rgba = [UInt8](repeating: 5, count: 8 * 8 * 4)
        let pb = rgba.withUnsafeBytes { FrameConverter().convert(rgba: $0.baseAddress!, width: 8, height: 8)! }
        return DisplayFrame(pixelBuffer: pb, size: VideoSize(width: 8, height: 8), rotation: .portrait,
                            deviceTimestampUs: 0, receivedAt: .now, seq: seq)
    }

    @Test func coalescesToTheNewestFrameAndPresentsInOrder() async throws {
        let layer = CALayerProbe.make()
        let sink = LayerFrameSink(layer: layer)
        for s in 10...12 { sink.consume(frame(seq: UInt32(s))) }   // the main thread has not run yet
        for _ in 0..<50 where sink.presentationStats.presented == 0 { try await Task.sleep(for: .milliseconds(5)) }
        var p = sink.presentationStats
        #expect(p.received == 3 && p.presented == 1 && p.coalesced == 2 && p.outOfOrder == 0)
        #expect(sink.currentFrame?.seq == 12)
        sink.consume(frame(seq: 11))   // an older frame after a newer one must be visible in the counters
        for _ in 0..<50 where sink.presentationStats.presented == 1 { try await Task.sleep(for: .milliseconds(5)) }
        p = sink.presentationStats
        #expect(p.outOfOrder == 1)
        sink.consume(frame(seq: 1))    // a new stream (resume) starts again at 1: not out of order
        for _ in 0..<50 where sink.presentationStats.presented == 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(sink.presentationStats.outOfOrder == 1)
    }
}

import QuartzCore
enum CALayerProbe {
    @MainActor static func make() -> CALayer { CALayer() }
}
