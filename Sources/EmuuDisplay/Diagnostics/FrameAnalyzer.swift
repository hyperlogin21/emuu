import Foundation
import CoreVideo

// Display-artefact diagnostics ("Diagnosing display artefacts" in docs/ARCHITECTURE.md). Pure logic over
// BGRA pixels, so it is unit-tested with synthetic frames; `DiagnosticFrameSink` runs it on live frames.

/// Read-only view of BGRA8888 pixels.
public struct BGRAPixels {
    public let base: UnsafeRawPointer
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int

    public init(base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int) {
        self.base = base
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
    }

    /// (r, g, b) at (x, y), clamped to the image.
    @inline(__always)
    public func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let xx = min(max(x, 0), width - 1), yy = min(max(y, 0), height - 1)
        let p = base.advanced(by: yy * bytesPerRow + xx * 4).assumingMemoryBound(to: UInt8.self)
        return (Int(p[2]), Int(p[1]), Int(p[0]))
    }
}

/// Geometry of the test pattern drawn by scripts/flicker-test (video generator and the test APK's GL
/// activity): inside a `w × h` picture, border = w/40 (magenta), cell = w/10, five markers (four corners,
/// centre) of three cells each, cell k showing palette[(n >> 3·(2−k)) & 7].
public enum TestPattern {
    /// Palette index for an (r, g, b) bit triple: black, red, green, blue, yellow, cyan, magenta, white.
    static let indexForBits: [Int] = {
        let palette = [(0, 0, 0), (1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0), (0, 1, 1), (1, 0, 1), (1, 1, 1)]
        var t = [Int](repeating: 0, count: 8)
        for (i, c) in palette.enumerated() { t[c.0 << 2 | c.1 << 1 | c.2] = i }
        return t
    }()
    public static let period = 512
    public static let markerNames = ["top-left", "top-right", "bottom-left", "bottom-right", "centre"]

    /// Marker origins (top-left of cell 0) and the cell size, in picture coordinates.
    public static func markers(width w: Double, height h: Double) -> (origins: [(Double, Double)], cell: Double) {
        let border = max(4, w / 40), cell = w / 10
        let m = border + cell / 3
        return ([(m, m), (w - m - 3 * cell, m), (m, h - m - cell), (w - m - 3 * cell, h - m - cell),
                 (w / 2 - 3 * cell / 2, h / 2 - cell / 2)], cell)
    }

    static func isMagenta(_ c: (Int, Int, Int)) -> Bool { c.0 > 190 && c.1 < 80 && c.2 > 190 }

    /// Finds the magenta-bordered picture on screen: the side borders from three rows, then the top and bottom
    /// along the inside of the left border, and checks that all four borders are there. nil when the pattern is
    /// not on screen or a border is covered (system bars, UI): positions would be guessed wrong otherwise.
    public static func locate(_ px: BGRAPixels) -> PatternRect? {
        var xs: [(Int, Int, Int)] = []   // (x0, x1, left border thickness)
        for fy in [0.5, 0.42, 0.58] {
            let y = Int(Double(px.height) * fy)
            guard let f = (0..<px.width).first(where: { isMagenta(px.rgb($0, y)) }),
                  let l = (0..<px.width).reversed().first(where: { isMagenta(px.rgb($0, y)) }), l - f > px.width / 8 else { continue }
            var t = 0
            while f + t < l, isMagenta(px.rgb(f + t, y)) { t += 1 }
            xs.append((f, l + 1, t))
        }
        guard !xs.isEmpty else { return nil }
        let (x0, x1, b) = xs.sorted { $0.0 + $0.1 < $1.0 + $1.1 }[xs.count / 2]
        let w = x1 - x0
        guard w >= 40, b >= 2, abs(Double(b) - max(4, Double(w) / 40)) <= max(3, Double(w) / 80) else { return nil }
        // Along the inside of the left border: the contiguous magenta run through the middle row is the picture height.
        let cx = x0 + b / 2, midY = px.height / 2
        guard isMagenta(px.rgb(cx, midY)) else { return nil }
        var y0 = midY, y1 = midY
        while y0 > 0, isMagenta(px.rgb(cx, y0 - 1)) { y0 -= 1 }
        while y1 < px.height - 1, isMagenta(px.rgb(cx, y1 + 1)) { y1 += 1 }
        let r = PatternRect(x: x0, y: y0, width: w, height: y1 + 1 - y0)
        guard r.height >= 40, bordersPresent(px, r, border: b) else { return nil }
        return r
    }

    /// All four borders magenta at their middles (and the right border at mid-height).
    static func bordersPresent(_ px: BGRAPixels, _ r: PatternRect, border b: Int) -> Bool {
        let midX = r.x + r.width / 2, midY = r.y + r.height / 2, h = max(1, b / 2)
        return isMagenta(px.rgb(midX, r.y + h)) && isMagenta(px.rgb(midX, r.y + r.height - 1 - h))
            && isMagenta(px.rgb(r.x + h, midY)) && isMagenta(px.rgb(r.x + r.width - 1 - h, midY))
    }

    /// Decodes one 3-bit cell: averages a 5×5 grid over the cell's middle half. nil if a channel is ambiguous
    /// (a blend of two frames, an overlay, or not the pattern at all).
    static func decodeCell(_ px: BGRAPixels, x: Double, y: Double, size: Double) -> Int? {
        var r = 0, g = 0, b = 0
        for i in 0..<5 {
            for j in 0..<5 {
                let c = px.rgb(Int(x + size * (0.25 + 0.125 * Double(i))), Int(y + size * (0.25 + 0.125 * Double(j))))
                r += c.0; g += c.1; b += c.2
            }
        }
        r /= 25; g /= 25; b /= 25
        func bit(_ v: Int) -> Int? { v >= 170 ? 1 : (v <= 85 ? 0 : nil) }
        guard let rb = bit(r), let gb = bit(g), let bb = bit(b) else { return nil }
        return indexForBits[rb << 2 | gb << 1 | bb]
    }

    /// The counter in each of the five markers (nil = not readable).
    public static func decode(_ px: BGRAPixels, in rect: PatternRect) -> [Int?] {
        let (origins, cell) = markers(width: Double(rect.width), height: Double(rect.height))
        return origins.map { o in
            var v = 0
            for k in 0..<3 {
                guard let d = decodeCell(px, x: Double(rect.x) + o.0 + Double(k) * cell, y: Double(rect.y) + o.1, size: cell) else { return nil }
                v = v << 3 | d
            }
            return v
        }
    }
}

extension TestPattern {
    /// Whether a single picture is torn (two counters, each in ≥ 2 markers). nil when the pattern is not readable.
    public static func isTorn(_ pb: CVPixelBuffer) -> Bool? {
        pb.withBGRAPixels { px -> Bool? in
            guard let r = locate(px) else { return nil }
            let read = decode(px, in: r).compactMap { $0 }
            guard read.count >= 2 else { return nil }
            let votes = Dictionary(read.map { ($0, 1) }, uniquingKeysWith: +).values.sorted(by: >)
            return votes.count > 1 && votes[1] >= 2
        } ?? nil
    }
}

public struct PatternRect: Sendable, Hashable, CustomStringConvertible {
    public var x, y, width, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) { self.x = x; self.y = y; self.width = width; self.height = height }
    public var description: String { "\(width)x\(height)+\(x)+\(y)" }
}

/// What one frame looked like.
public struct FrameVerdict: Sendable, Hashable {
    public enum Kind: String, Sendable, CaseIterable {
        /// Test pattern: the five markers disagree (parts of different frames in one picture).
        case torn
        /// Test pattern: counter went backwards (an older frame shown after a newer one).
        case outOfOrder = "out-of-order"
        /// Test pattern was visible on the previous frame but cannot be found/read on this one.
        case patternLost = "pattern-lost"
        /// Almost all black while the previous frame was not.
        case blank
        /// A quarter or more of the screen is decoder green (a video frame whose YUV planes were never written,
        /// RGB ≈ (0, 135, 0)); see `isDecoderGreen`.
        case green
        /// Generic flicker: differs strongly from both neighbours while the neighbours match each other (A-B-A).
        case flash
    }
    public var seq: UInt32
    public var counter: Int?
    public var markers: [Int?]
    public var kinds: Set<Kind>
}

/// Counts artefacts over a stream of frames (call `analyze` in order). Not thread-safe.
public final class FrameAnalyzer {
    public struct Summary: Sendable, Hashable, Codable {
        public var frames = 0
        /// Frames where the test pattern was found.
        public var patternFrames = 0
        public var torn = 0
        public var outOfOrder = 0
        public var patternLost = 0
        public var blank = 0
        public var green = 0
        public var flash = 0
        /// Test pattern: same counter as the previous frame (normal when the screen updates faster than the
        /// video, e.g. 30 fps video under a 60 Hz animated UI).
        public var duplicates = 0
        /// Test pattern: frames where one marker disagreed with the rest (UI drawn over it; not counted as torn).
        public var occludedMarkers = 0
        /// Test pattern: counters skipped between consecutive frames (frames the display never received).
        public var skippedCounters = 0
        /// Test pattern: distinct counters seen per second.
        public var distinctPerSecond = 0.0
        public var seconds = 0.0
        public var framesPerSecond = 0.0
        /// Arrival gaps (ms).
        public var gapP50Ms = 0.0, gapP95Ms = 0.0, gapP99Ms = 0.0, gapMaxMs = 0.0
        /// Arrival gaps over 50 ms while frames were flowing (visible stutter).
        public var lateGaps = 0
        /// Engine timestamp → Emuu receipt (ms).
        public var transportP50Ms = 0.0, transportP95Ms = 0.0
        /// Receipt → pixels in the pooled buffer (Emuu's read/convert) (µs).
        public var convertP50Us = 0.0, convertP95Us = 0.0
        public var artefacts: Int { torn + outOfOrder + patternLost + blank + green + flash }
    }

    public private(set) var summary = Summary()
    private var rect: PatternRect?
    private var lastCounter: Int?
    private var seen = Set<Int>()
    private var distinct = 0
    private var lastArrival: ContinuousClock.Instant?
    private var firstArrival: ContinuousClock.Instant?
    private var lastBlank = false
    private var lastHadPattern = false
    private var gaps: [Double] = []
    private var transport: [Double] = []
    private var convert: [Double] = []
    /// Thumbnails (luma, 24×48) of the previous two frames for A-B-A detection.
    private var thumbs: [[UInt8]] = []
    static let thumbW = 24, thumbH = 48

    public init() {}

    /// The colour of a video frame whose YUV planes are all zero (never written by the decoder): Y = U = V = 0
    /// converts to RGB ≈ (0, 135, 0) with BT.601 (limited or full range) and ≈ (0, 77, 0) with BT.709. Bright
    /// pure green (G up to 255) is included too.
    static func isDecoderGreen(_ c: (Int, Int, Int)) -> Bool {
        c.1 >= 60 && c.0 < 40 && c.2 < 40
    }

    /// Analyses one frame. Returns the verdict of this frame and, separately, a late verdict for the frame
    /// before it (A-B-A flicker needs the next frame).
    public func analyze(_ px: BGRAPixels, seq: UInt32, arrival: ContinuousClock.Instant,
                        transportMs: Double? = nil, convertUs: Double? = nil) -> (FrameVerdict, previousFlash: Bool) {
        summary.frames += 1
        if firstArrival == nil { firstArrival = arrival }
        if let last = lastArrival {
            let gap = Self.ms(arrival - last)
            gaps.append(gap)
            if gap > 50 && gap < 1000 { summary.lateGaps += 1 }   // ≥ 1 s: the screen was simply static
        }
        lastArrival = arrival
        if let t = transportMs { transport.append(t) }
        if let c = convertUs { convert.append(c) }
        var verdict = FrameVerdict(seq: seq, counter: nil, markers: [], kinds: [])

        // Blank / green over a coarse grid.
        var black = 0, green = 0, total = 0
        for gy in 0..<40 {
            for gx in 0..<20 {
                let c = px.rgb(px.width * (2 * gx + 1) / 40, px.height * (2 * gy + 1) / 80)
                total += 1
                if c.0 < 16 && c.1 < 16 && c.2 < 16 { black += 1 }
                if Self.isDecoderGreen(c) { green += 1 }
            }
        }
        let isBlank = Double(black) / Double(total) > 0.97
        if isBlank && !lastBlank && summary.frames > 1 { verdict.kinds.insert(.blank) }
        lastBlank = isBlank
        // A quarter of the screen: a green video area under the app's own UI (TikTok's feed) still counts.
        if Double(green) / Double(total) > 0.25 { verdict.kinds.insert(.green) }

        // Test pattern.
        if rect == nil || !rectStillValid(px) { rect = TestPattern.locate(px) }
        if let rect {
            let m = TestPattern.decode(px, in: rect)
            verdict.markers = m
            let read = m.compactMap { $0 }
            if read.count >= 2 {
                summary.patternFrames += 1
                lastHadPattern = true
                // Torn = two different counters each shown by ≥ 2 markers (a tear line between marker rows).
                // A single odd marker is an overlay over that marker (UI drawn on the video), not a tear.
                let votes = Dictionary(read.map { ($0, 1) }, uniquingKeysWith: +).sorted { $0.value > $1.value }
                if votes.count > 1 && votes[1].value >= 2 {
                    verdict.kinds.insert(.torn)
                } else if votes[0].value < 2 && read.count > 1 {
                    // No majority at all: unreadable this frame.
                } else {
                    if votes.count > 1 { summary.occludedMarkers += 1 }
                    let c = votes[0].key
                    verdict.counter = c
                    if seen.insert(c).inserted { distinct += 1 }
                    if seen.count > TestPattern.period / 2 { seen.removeAll(keepingCapacity: true) }
                    if let p = lastCounter {
                        let d = (c - p + TestPattern.period) % TestPattern.period
                        if d == 0 { summary.duplicates += 1 }
                        else if d > TestPattern.period / 2 { verdict.kinds.insert(.outOfOrder) }
                        else { summary.skippedCounters += d - 1 }
                    }
                    lastCounter = c
                }
            } else if lastHadPattern {
                verdict.kinds.insert(.patternLost)
                lastHadPattern = false
            }
        } else if lastHadPattern {
            verdict.kinds.insert(.patternLost)
            lastHadPattern = false
        }

        // A-B-A on thumbnails: judge the previous frame now that its successor is known.
        let thumb = Self.thumbnail(px)
        var previousFlash = false
        if thumbs.count == 2 {
            let a = thumbs[0], b = thumbs[1]
            let dab = Self.diff(a, b), dbc = Self.diff(b, thumb), dac = Self.diff(a, thumb)
            if min(dab, dbc) > 20 && dac < 0.25 * min(dab, dbc) {
                previousFlash = true
                summary.flash += 1
            }
        }
        thumbs.append(thumb)
        if thumbs.count > 2 { thumbs.removeFirst() }

        for k in verdict.kinds {
            switch k {
            case .torn: summary.torn += 1
            case .outOfOrder: summary.outOfOrder += 1
            case .patternLost: summary.patternLost += 1
            case .blank: summary.blank += 1
            case .green: summary.green += 1
            case .flash: break
            }
        }
        return (verdict, previousFlash)
    }

    /// Final numbers (percentiles are computed here).
    public func finish() -> Summary {
        var s = summary
        if let f = firstArrival, let l = lastArrival {
            s.seconds = Self.ms(l - f) / 1000
            if s.seconds > 0 {
                s.framesPerSecond = Double(s.frames - 1) / s.seconds
                s.distinctPerSecond = Double(distinct) / s.seconds
            }
        }
        func pct(_ v: [Double], _ p: Double) -> Double {
            guard !v.isEmpty else { return 0 }
            let s = v.sorted()
            return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
        }
        s.gapP50Ms = pct(gaps, 0.5); s.gapP95Ms = pct(gaps, 0.95); s.gapP99Ms = pct(gaps, 0.99); s.gapMaxMs = gaps.max() ?? 0
        s.transportP50Ms = pct(transport, 0.5); s.transportP95Ms = pct(transport, 0.95)
        s.convertP50Us = pct(convert, 0.5); s.convertP95Us = pct(convert, 0.95)
        return s
    }

    private func rectStillValid(_ px: BGRAPixels) -> Bool {
        guard let r = rect, r.x + r.width <= px.width, r.y + r.height <= px.height else { return false }
        return TestPattern.bordersPresent(px, r, border: max(2, Int(max(4, Double(r.width) / 40))))
    }

    static func thumbnail(_ px: BGRAPixels) -> [UInt8] {
        var t = [UInt8](repeating: 0, count: thumbW * thumbH)
        for y in 0..<thumbH {
            for x in 0..<thumbW {
                let c = px.rgb(px.width * (2 * x + 1) / (2 * thumbW), px.height * (2 * y + 1) / (2 * thumbH))
                t[y * thumbW + x] = UInt8((c.0 * 77 + c.1 * 150 + c.2 * 29) >> 8)
            }
        }
        return t
    }

    static func diff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 255 }
        var s = 0
        for i in 0..<a.count { s += abs(Int(a[i]) - Int(b[i])) }
        return Double(s) / Double(a.count)
    }

    public static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
}

extension CVPixelBuffer {
    /// Runs `body` with read access to a BGRA buffer's pixels.
    public func withBGRAPixels<R>(_ body: (BGRAPixels) -> R) -> R? {
        CVPixelBufferLockBaseAddress(self, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(self, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(self) else { return nil }
        return body(BGRAPixels(base: base, width: CVPixelBufferGetWidth(self), height: CVPixelBufferGetHeight(self),
                               bytesPerRow: CVPixelBufferGetBytesPerRow(self)))
    }
}
