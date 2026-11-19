import Foundation
import EmuuBase

/// In-window diagnostics, off unless `EMUU_DISPLAY_DIAG` is set (Emuu app or `emuu start --window`):
/// analyses every frame the window actually **presents** (after main-thread coalescing) and logs one summary
/// line every 10 s to the main log (`display.diag`), with session counters (shared-memory races, drops) and the
/// renderer's presentation counters. Offending frames are saved as PNGs.
///
/// `EMUU_DISPLAY_DIAG=1` saves under `<EMUU_HOME>/logs/display-diag/`; any other value is used as the directory.
@MainActor
public final class DisplayDiagnosticsMonitor {
    public static let environmentKey = "EMUU_DISPLAY_DIAG"

    private let sink: DiagnosticFrameSink
    private let label: String
    private let directory: URL
    private let logger = EmuuLogger(category: "display.diag")
    private var task: Task<Void, Never>?

    public static func fromEnvironment(label: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> DisplayDiagnosticsMonitor? {
        guard let value = environment[environmentKey], !value.isEmpty, value != "0" else { return nil }
        let dir = value == "1"
            ? EmuuPaths.default(environment: environment).logsDirectory.appendingPathComponent("display-diag", isDirectory: true)
            : URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
        return DisplayDiagnosticsMonitor(label: label, directory: dir)
    }

    public init(label: String, directory: URL) {
        self.label = label
        self.directory = directory
        self.sink = DiagnosticFrameSink(options: .init(saveDirectory: directory, maxSaved: 24, csv: nil, label: "presented-\(label)"))
        logger.notice("display diagnostics on for \(label): presented frames are analysed; PNGs of offending frames → \(directory.path)")
    }

    /// Hooks the renderer's present callback and starts the periodic log.
    public func attach(renderer: LayerFrameSink, session: EmulatorDisplaySession) {
        let logger = self.logger
        let dir = directory
        let saved = Locked(0)
        session.setRaceObserver { race in
            let torn = race.copy.flatMap { TestPattern.isTorn($0) }
            logger.notice("shared-memory race (attempt \(race.attempt)): rows \(race.firstRow)…\(race.lastRow) of \(race.height) changed while being read [\(race.context)] (\(race.rowsChanged) rows)\(torn == true ? "; first read TORN (re-read, not shown)" : torn == false ? "; first read whole" : "")")
            let n = saved.withLock { c -> Int in c += 1; return c }
            if n <= 12, let png = race.copy?.pngData() {
                try? png.write(to: dir.appendingPathComponent("race-\(n)-rows\(race.firstRow)-\(race.lastRow).png"))
            }
        }
        let previous = renderer.onPresent
        let sink = self.sink
        renderer.onPresent = { frame in
            previous?(frame)
            sink.consume(frame)
        }
        task?.cancel()
        task = Task { [weak self, weak renderer] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, let renderer else { return }
                self.log(renderer: renderer, session: session)
            }
        }
    }

    public func log(renderer: LayerFrameSink, session: EmulatorDisplaySession) {
        let m = sink.snapshot()
        let st = session.stats()
        let p = renderer.presentationStats
        guard m.frames > 0 else { return }
        logger.notice(String(format: "%@: presented %d (coalesced %d, presented out of order %d) · artefacts torn %d, out-of-order %d, pattern-lost %d, blank %d, green %d, flash %d · pattern frames %d · gaps p95 %.1f ms max %.0f ms late %d · shm %@ raced %llu unstable %llu dropped %llu",
                              label, p.presented, p.coalesced, p.outOfOrder, m.torn, m.outOfOrder, m.patternLost, m.blank, m.green, m.flash,
                              m.patternFrames, m.gapP95Ms, m.gapMaxMs, m.lateGaps,
                              session.frameOptions.transport == .inline ? "inline" : (session.frameOptions.validateSharedMemory ? "validated" : "NOT validated"), st.racedFrames, st.unstableFrames, st.droppedFrames))
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}
