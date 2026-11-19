import AppKit
import SwiftUI
import EmuuBase
import EmuuFarm

/// Diagnostics driver for the library's "Clone…" path, inactive unless `EMUU_APP_CLONETEST=<source>:<new name>`.
///
/// Opens the source's window (boots or resumes it), renders the clone sheet as the user would see it for a running
/// source, runs the same `AppModel.cloneInstance` the sheet's button runs (hibernate → clone → resume), waits until
/// the source's window is streaming again, then hibernates the source and quits. Lines go to stdout and
/// `logs/app-clonetest.txt`; the sheet render goes to `EMUU_APP_SELFTEST_EVIDENCE` (default: the logs directory).
@MainActor
final class CloneSelfTest {
    private let model: AppModel
    private var task: Task<Void, Never>?

    init(model: AppModel) { self.model = model }

    func start(spec: String) {
        task = Task { [weak self] in await self?.run(spec) }
    }

    private func run(_ spec: String) async {
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let source = InstanceID(rawValue: parts[0]) else { return report("CLONETEST bad spec \(spec)") }
        let newName = parts[1]
        report("CLONETEST start pid=\(getpid()) source=\(source) name=\"\(newName)\"")
        await model.reload()
        model.openWindow(source)
        let t0 = ContinuousClock.now
        guard await waitFor(seconds: 180, { self.model.session(for: source)?.display?.state == .streaming }) else {
            report("CLONETEST FAILED: \(source) did not come up (phase \(String(describing: self.model.session(for: source)?.phase)))")
            return quit()
        }
        report("CLONETEST source streaming after \(fmt(ContinuousClock.now - t0))")
        await model.reload()
        guard let row = model.rows.first(where: { $0.id == source }) else { report("CLONETEST FAILED: no row"); return quit() }
        report("CLONETEST plan=\(model.clonePlan(for: source, consent: true)) suggested=\"\(model.suggestedCloneName(for: source))\" state=\(row.state)")
        renderSheet(row)

        let t1 = ContinuousClock.now
        do {
            let id = try await model.cloneInstance(source, displayName: newName) { self.report("CLONETEST progress: \($0)") }
            report("CLONETEST cloned → \(id) in \(fmt(ContinuousClock.now - t1)) (incl. hibernate and copy)")
            let back = await waitFor(seconds: 120) { self.model.session(for: source)?.display?.state == .streaming }
            report("CLONETEST source streaming again=\(back) after \(fmt(ContinuousClock.now - t1)) state=\(model.session(for: source)?.engineState.description ?? "?")")
            if let client = model.session(for: source)?.client {
                let out = (try? await client.shell("settings get secure android_id; cat /proc/sys/kernel/random/boot_id; cut -d' ' -f1 /proc/uptime", timeout: .seconds(10)).trimmedStdout) ?? "?"
                report("CLONETEST source after resume: \(out.replacingOccurrences(of: "\n", with: " | "))")
            }
            await model.reload()
            report("CLONETEST library rows: \(model.rows.map { "\($0.id)[\($0.config.displayName)]=\($0.state)" }.joined(separator: ", "))")
        } catch {
            report("CLONETEST FAILED: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }
        await model.finish(source, .hibernate)
        report("CLONETEST DONE (source hibernated)")
        quit()
    }

    private func renderSheet(_ row: InstanceRow) {
        guard let dir = evidenceDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sheet = CloneInstanceSheet(source: row).environment(model).frame(width: 440)
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            let renderer = ImageRenderer(content: sheet.environment(\.colorScheme, scheme)
                .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.96)))
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            let url = dir.appendingPathComponent("clone-sheet-\(name).png")
            try? png.write(to: url)
            report("CLONETEST rendered \(url.path)")
        }
    }

    private var evidenceDir: URL? {
        if let d = ProcessInfo.processInfo.environment["EMUU_APP_SELFTEST_EVIDENCE"] { return URL(fileURLWithPath: d) }
        return model.env?.paths.logsDirectory
    }

    private func quit() {
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }

    private func waitFor(seconds: Int, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return condition()
    }

    private func fmt(_ d: Duration) -> String {
        String(format: "%.2fs", Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
    }

    private func report(_ line: String) {
        print(line)
        fflush(stdout)
        EmuuLogger(category: "app.clonetest").notice(line)
        guard let paths = model.env?.paths else { return }
        let url = paths.logsDirectory.appendingPathComponent("app-clonetest.txt")
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(text.utf8))
            try? h.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }
}
