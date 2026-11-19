import Foundation
import CoreVideo
import EmuuBase

/// A `DisplayFrameSink` that runs `FrameAnalyzer` on every delivered frame (off the reader thread, on its own
/// serial queue), optionally writes one CSV line per frame and saves PNGs of offending frames. Used by
/// `emuu debug display-probe` and, with `EMUU_DISPLAY_DIAG=1`, teed next to the window's renderer.
public final class DiagnosticFrameSink: DisplayFrameSink, @unchecked Sendable {
    public struct Options: Sendable {
        /// Directory for `flicker-<kind>-<seq>.png` (nil: save nothing).
        public var saveDirectory: URL?
        public var maxSaved: Int
        /// Per-frame CSV (nil: none).
        public var csv: URL?
        /// File-name prefix for saved PNGs.
        public var label: String

        public init(saveDirectory: URL? = nil, maxSaved: Int = 12, csv: URL? = nil, label: String = "flicker") {
            self.saveDirectory = saveDirectory
            self.maxSaved = maxSaved
            self.csv = csv
            self.label = label
        }
    }

    private let queue = DispatchQueue(label: "emuu.display.diagnostics", qos: .utility)
    private let analyzer = FrameAnalyzer()
    private let options: Options
    private var saved = 0
    private var previous: DisplayFrame?
    private var csvHandle: FileHandle?
    private let backlog = Locked(0)
    private let skippedBacklog = Locked(0)

    public init(options: Options = Options()) {
        self.options = options
        if let csv = options.csv {
            FileManager.default.createFile(atPath: csv.path, contents: Data("seq,arrival_ms,counter,markers,kinds,transport_ms,convert_us\n".utf8))
            csvHandle = try? FileHandle(forWritingTo: csv)
            _ = try? csvHandle?.seekToEnd()
        }
        if let dir = options.saveDirectory {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private let origin = ContinuousClock.now

    public func consume(_ frame: DisplayFrame) {
        // Bounded: never hold more than 4 pooled buffers (the display pool has 8).
        let accepted = backlog.withLock { n -> Bool in
            guard n < 4 else { return false }
            n += 1
            return true
        }
        guard accepted else {
            skippedBacklog.withLock { $0 += 1 }
            return
        }
        queue.async { [self] in
            defer { backlog.withLock { $0 -= 1 } }
            process(frame)
        }
    }

    private func process(_ frame: DisplayFrame) {
        let transport: Double? = frame.deviceTimestampUs > 0 ? transportMs(frame) : nil
        let convertUs = FrameAnalyzer.ms(frame.convertedAt - frame.receivedAt) * 1000
        guard let (verdict, prevFlash) = frame.pixelBuffer.withBGRAPixels({ px in
            analyzer.analyze(px, seq: frame.seq, arrival: frame.receivedAt, transportMs: transport, convertUs: convertUs)
        }) else { return }
        if let h = csvHandle {
            let m = verdict.markers.map { $0.map(String.init) ?? "-" }.joined(separator: "/")
            let kinds = verdict.kinds.map(\.rawValue).sorted().joined(separator: "+")
            let line = "\(frame.seq),\(String(format: "%.2f", FrameAnalyzer.ms(frame.receivedAt - origin))),\(verdict.counter.map(String.init) ?? ""),\(m),\(kinds),\(transport.map { String(format: "%.2f", $0) } ?? ""),\(String(format: "%.0f", convertUs))\n"
            h.write(Data(line.utf8))
        }
        if prevFlash, let p = previous { save(p, kind: "flash") }
        if let k = verdict.kinds.first { save(frame, kind: k.rawValue) }
        previous = frame
    }

    /// Engine timestamp → receipt. The engine stamps in Unix µs; convert receipt to Unix time via the offset now.
    private func transportMs(_ frame: DisplayFrame) -> Double? {
        let nowUnixUs = Date().timeIntervalSince1970 * 1_000_000
        let sinceReceipt = FrameAnalyzer.ms(ContinuousClock.now - frame.receivedAt) * 1000
        let receivedUnixUs = nowUnixUs - sinceReceipt
        let t = (receivedUnixUs - Double(frame.deviceTimestampUs)) / 1000
        return t >= 0 && t < 10_000 ? t : nil
    }

    private func save(_ frame: DisplayFrame, kind: String) {
        guard let dir = options.saveDirectory, saved < options.maxSaved, let png = frame.pixelBuffer.pngData() else { return }
        saved += 1
        try? png.write(to: dir.appendingPathComponent("\(options.label)-\(kind)-\(frame.seq).png"))
    }

    /// Waits for queued frames and returns the totals.
    public func finish() -> FrameAnalyzer.Summary {
        queue.sync {
            try? csvHandle?.close()
            csvHandle = nil
            previous = nil
            return analyzer.finish()
        }
    }

    /// Current totals (percentiles included).
    public func snapshot() -> FrameAnalyzer.Summary { queue.sync { analyzer.finish() } }

    /// Frames queued for analysis right now (file analysis waits on this instead of skipping).
    public var backlogCount: Int { backlog.withLock { $0 } }

    /// Frames not analysed because the analysis queue was behind (the display itself was unaffected).
    public var notAnalyzed: Int { skippedBacklog.withLock { $0 } }
}
