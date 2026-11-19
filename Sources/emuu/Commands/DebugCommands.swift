import Foundation
import ArgumentParser
import EmuuBase
import EmuuGRPC
import EmuuDisplay
import EmuuMemory
import AVFoundation

/// Hidden diagnostics (`emuu debug …`). Not part of the normal command list.
struct Debug: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Diagnostics for Emuu developers.",
        shouldDisplay: false,
        subcommands: [DisplayProbe.self])
}

/// Streams the display exactly as the window does (same session, transport, converter) and analyses every
/// frame for artefacts. See "Diagnosing display artefacts" in docs/ARCHITECTURE.md.
struct DisplayProbe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "display-probe",
        abstract: "Count display artefacts (torn, blank, out-of-order, flashing frames) on a running instance.",
        discussion: """
        Play the content that flickers on the device (any app — e.g. TikTok — or the test pattern from \
        scripts/flicker-test), then run:

          emuu debug display-probe phone --duration 60 --save ~/Desktop/emuu-flicker

        Generic checks work on any content: blank (black) frames, green frames, A-B-A flashes (a frame unlike \
        both neighbours while they match each other). With the scripts/flicker-test pattern on screen it also \
        reads the frame counter in five places and counts torn and out-of-order frames.
        """)

    @Argument(help: "Instance name.") var name: String?
    @OptionGroup var option: InstanceOption
    @Option(help: "Seconds to sample.") var duration: Double = 30
    @Option(help: "Analyse a video file (e.g. an `emuu record` MP4) instead of a running instance.") var file: String?
    @Option(help: "Frame transport: mmap (default, what the window uses) or inline (pixels in the gRPC messages).")
    var transport: String = "mmap"
    @Flag(help: "MMAP: read the shared memory without the copy-and-compare check (the behaviour before the fix).")
    var noValidate = false
    @Flag(help: "Also open an inline-transport stream at the same time as ground truth (more CPU).")
    var compareInline = false
    @Option(help: "Directory for PNGs of offending frames.") var save: String?
    @Option(help: "At most this many PNGs per stream.") var maxSaved: Int = 12
    @Option(help: "Write one CSV line per frame here.") var csv: String?
    @Option(help: "Afterwards, measure input-to-frame latency with this many taps at the screen centre (use on a screen that reacts to touches, e.g. with pointer location on).")
    var tapLatency: Int = 0
    @Flag(help: "JSON output.") var json = false

    struct StreamReport: Codable {
        var transport: String
        var validated: Bool
        var summary: FrameAnalyzer.Summary
        var deliveredFrames: UInt64
        var racedFrames: UInt64
        var unstableFrames: UInt64
        var droppedFrames: UInt64
        var notAnalyzed: Int
        /// Validated MMAP + test pattern: races whose first copy was torn (what the unvalidated read would have shown).
        var racedCopiesTorn: Int
    }

    struct Report: Codable {
        var instance: String
        var seconds: Double
        var streams: [StreamReport]
        var probeCPUPercent: Double
        var probeFootprintMB: Double
        var tapLatencyMs: [Double]?
    }

    func run() async throws {
        if let file {
            try await analyzeFile(URL(fileURLWithPath: (file as NSString).expandingTildeInPath))
            return
        }
        let ctx = try CLIContext.live()
        let config = try ctx.resolveInstance(name ?? option.instance)
        guard let mode = EmulatorDisplaySession.FrameOptions.Transport(rawValue: transport) else {
            throw CLIError("--transport must be mmap or inline")
        }
        _ = try await ctx.ensureRunning(config)
        let id = config.id
        var specs: [(EmulatorDisplaySession.FrameOptions, String)] = [
            (.init(transport: mode, validateSharedMemory: !noValidate), mode.rawValue + (mode == .mmap ? (noValidate ? "-raw" : "-validated") : "")),
        ]
        if compareInline && mode != .inline { specs.append((.init(transport: .inline), "inline")) }

        var running: [(EmulatorDisplaySession, DiagnosticFrameSink, EmulatorDisplaySession.FrameOptions)] = []
        var raceCounters: [Locked<Int>] = []
        let saveDir = save.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        for (opts, label) in specs {
            let session = EmulatorDisplaySession(endpoint: { await ctx.grpcEndpoint(id) }, frameOptions: opts)
            let csvURL = csv.map { path -> URL in
                let u = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                return specs.count > 1 ? u.deletingPathExtension().appendingPathExtension("\(label).csv") : u
            }
            let sink = DiagnosticFrameSink(options: .init(saveDirectory: saveDir, maxSaved: maxSaved, csv: csvURL, label: "flicker-\(label)"))
            session.setFrameSink(sink)
            let races = Locked(0)
            let limit = maxSaved
            let tornCopies = Locked(0)
            raceCounters.append(tornCopies)
            session.setRaceObserver { race in
                let n = races.withLock { c -> Int in c += 1; return c }
                let torn = race.copy.flatMap { TestPattern.isTorn($0) }
                if torn == true { tornCopies.withLock { $0 += 1 } }
                Out.err("  shared-memory race (attempt \(race.attempt)): rows \(race.firstRow)…\(race.lastRow) of \(race.height) changed while being read [\(race.context)]\(torn == true ? "; the copy read is TORN (an unvalidated read would show it)" : torn == false ? "; the copy read is whole" : "")")
                if let saveDir, n <= limit, let png = race.copy?.pngData() {
                    try? png.write(to: saveDir.appendingPathComponent("race-\(label)-\(n)-rows\(race.firstRow)-\(race.lastRow).png"))
                }
            }
            running.append((session, sink, opts))
        }
        let cpu0 = Self.cpuSeconds(), t0 = ContinuousClock.now
        for (s, _, _) in running {
            do { try await s.start() } catch { throw CLIError("display stream: \(describe(error))") }
        }
        Out.err("Sampling \(id) for \(Int(duration)) s (\(specs.map(\.1).joined(separator: " + ")))…")
        try? await Task.sleep(for: .milliseconds(Int64(duration * 1000)))
        let wall = FrameAnalyzer.ms(ContinuousClock.now - t0) / 1000
        let cpu = (Self.cpuSeconds() - cpu0) / max(wall, 0.001) * 100

        var latencies: [Double]?
        if tapLatency > 0, let first = running.first?.0 {
            latencies = await Self.measureTapLatency(session: first, taps: tapLatency)
        }
        var streams: [StreamReport] = []
        for (i, (s, sink, opts)) in running.enumerated() {
            await s.stop()
            let st = s.stats()
            streams.append(StreamReport(transport: opts.transport.rawValue, validated: opts.transport == .mmap && opts.validateSharedMemory,
                                        summary: sink.finish(), deliveredFrames: st.totalFrames, racedFrames: st.racedFrames,
                                        unstableFrames: st.unstableFrames, droppedFrames: st.droppedFrames, notAnalyzed: sink.notAnalyzed,
                                        racedCopiesTorn: raceCounters[i].withLock { $0 }))
        }
        let footprint = HostSampler.rusage(pid: getpid()).map { Double($0.ri_phys_footprint) / 1_048_576 } ?? 0
        let report = Report(instance: id.rawValue, seconds: wall, streams: streams, probeCPUPercent: cpu,
                            probeFootprintMB: footprint, tapLatencyMs: latencies)
        if json { try Out.json(report); return }
        Self.print(report)
    }

    /// Every frame of a video file through the same analyser (frame times from the file's timestamps).
    func analyzeFile(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CLIError("no video track in \(url.path)") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading() else { throw CLIError("cannot read \(url.path): \(reader.error?.localizedDescription ?? "?")") }
        let sink = DiagnosticFrameSink(options: .init(saveDirectory: save.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
                                                      maxSaved: maxSaved, csv: csv.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
                                                      label: "file"))
        let origin = ContinuousClock.now
        var seq: UInt32 = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            seq += 1
            let at = origin + .milliseconds(Int64(t * 1000))
            sink.consume(DisplayFrame(pixelBuffer: pb, size: VideoSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb)),
                                      rotation: .portrait, deviceTimestampUs: 0, receivedAt: at, seq: seq))
            while sink.backlogCount >= 3 { usleep(500) }
        }
        let report = Report(instance: url.lastPathComponent, seconds: 0,
                            streams: [StreamReport(transport: "file", validated: false, summary: sink.finish(), deliveredFrames: UInt64(seq),
                                                   racedFrames: 0, unstableFrames: 0, droppedFrames: 0, notAnalyzed: sink.notAnalyzed, racedCopiesTorn: 0)],
                            probeCPUPercent: 0, probeFootprintMB: 0, tapLatencyMs: nil)
        if json { try Out.json(report) } else { Self.print(report) }
    }

    static func print(_ r: Report) {
        Out.line("Display probe: \(r.instance), \(String(format: "%.1f", r.seconds)) s, probe CPU \(String(format: "%.1f", r.probeCPUPercent))% of one core, footprint \(String(format: "%.0f", r.probeFootprintMB)) MB")
        for s in r.streams {
            let m = s.summary
            Out.line("")
            Out.line("[\(s.transport)\(s.transport == "mmap" ? (s.validated ? ", validated" : ", NOT validated") : "")]")
            Out.line(String(format: "  frames %d (%.1f/s), gaps p50 %.1f / p95 %.1f / p99 %.1f / max %.0f ms, late (>50 ms) %d",
                            m.frames, m.framesPerSecond, m.gapP50Ms, m.gapP95Ms, m.gapP99Ms, m.gapMaxMs, m.lateGaps))
            Out.line(String(format: "  engine→Emuu p50 %.1f / p95 %.1f ms, read+convert p50 %.0f / p95 %.0f µs",
                            m.transportP50Ms, m.transportP95Ms, m.convertP50Us, m.convertP95Us))
            Out.line("  ARTEFACTS: torn \(m.torn), out-of-order \(m.outOfOrder), pattern-lost \(m.patternLost), blank \(m.blank), green \(m.green), flash \(m.flash)  (total \(m.artefacts))")
            if m.patternFrames > 0 {
                Out.line(String(format: "  test pattern in %d frames: %.1f distinct frames/s, duplicates %d, skipped counters %d",
                                m.patternFrames, m.distinctPerSecond, m.duplicates, m.skippedCounters))
            } else {
                Out.line("  test pattern not on screen (generic checks only)")
            }
            if s.transport == "mmap" {
                Out.line("  shared memory changed while being read: \(s.racedFrames) frame(s)\(s.validated ? " (re-read; \(s.unstableFrames) dropped; \(s.racedCopiesTorn) of the first reads were torn)" : " (not measured without validation)")")
            }
            if s.notAnalyzed > 0 { Out.line("  (\(s.notAnalyzed) frames not analysed: analysis queue behind)") }
        }
        if let l = r.tapLatencyMs, !l.isEmpty {
            let s = l.sorted()
            Out.line("")
            Out.line(String(format: "Tap → first changed frame: %d taps, p50 %.1f ms, p95 %.1f ms, max %.1f ms",
                            s.count, s[s.count / 2], s[min(s.count - 1, Int(Double(s.count - 1) * 0.95))], s.last!))
        }
    }

    /// Taps the screen centre `taps` times (waiting for a quiet screen first) and measures the time until
    /// the next frame arrives at Emuu.
    static func measureTapLatency(session: EmulatorDisplaySession, taps: Int) async -> [Double] {
        final class Probe: DisplayFrameSink, @unchecked Sendable {
            let last = Locked<ContinuousClock.Instant?>(nil)
            func consume(_ frame: DisplayFrame) { last.set(frame.convertedAt) }
        }
        let probe = Probe()
        session.setFrameSink(probe)
        guard let size = session.physicalSize else { return [] }
        var out: [Double] = []
        for i in 0..<taps {
            // Quiet for 400 ms (no frames), at most 5 s.
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                if let l = probe.last.withLock({ $0 }), ContinuousClock.now - l < .milliseconds(400) {
                    try? await Task.sleep(for: .milliseconds(50))
                } else { break }
            }
            let x = size.width / 2 + (i % 5) * 20, y = size.height / 2 + (i % 7) * 20
            probe.last.set(nil)
            let sent = ContinuousClock.now
            session.send([.touch([EmulatorTouch(x: x, y: y, identifier: 0, pressure: 1024)])])
            var got: ContinuousClock.Instant?
            while ContinuousClock.now - sent < .seconds(1) {
                if let l = probe.last.withLock({ $0 }) { got = l; break }
                try? await Task.sleep(for: .milliseconds(1))
            }
            session.send([.touch([EmulatorTouch(x: x, y: y, identifier: 0, pressure: 0)])])
            if let got { out.append(FrameAnalyzer.ms(got - sent)) }
        }
        return out
    }

    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
    }
}
