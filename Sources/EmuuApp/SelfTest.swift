import AppKit
import AVFoundation
import Darwin
import SwiftUI
import EmuuBase
import EmuuADB
import EmuuMemory
import EmuuDisplay

/// Diagnostics driver, inactive unless `EMUU_APP_SELFTEST=cycle:<instance-id>:<count>` is set.
///
/// Opens the instance window, waits for decoded frames and a governor sample, closes the window (the
/// session detaches; the engine keeps running) and repeats, logging the app's own `phys_footprint` and the
/// number of live sessions/window controllers after each cycle, so leaks across open/close cycles are
/// visible. Cycle 1 also exercises the control strip's actions on the device: Home, volume (checked with
/// `dumpsys audio`), screenshot, the on-screen keyboard toggle (device screenshots before/after), a screen
/// recording (checked with AVFoundation), an APK drop (`EMUU_APP_SELFTEST_APK`, through the display view's
/// drop handler), minimise/restore timing, and renders the window (light and dark) to PNG.
///
/// * `EMUU_APP_SELFTEST_EVIDENCE=<dir>`: where PNG/MP4 evidence goes (default `~/.emuu/logs`).
/// * `EMUU_APP_SELFTEST_QUIT=1`: quit when done (instance windows closed, engine left running).
/// * `EMUU_APP_SELFTEST_ONLY=keyboard`: only the keyboard/text-input scenarios (KeyboardSelfTest.swift).
/// Results go to stdout and `~/.emuu/logs/app-selftest.txt`.
@MainActor
final class SelfTestRunner {
    private let model: AppModel
    private var task: Task<Void, Never>?

    init(model: AppModel) { self.model = model }

    func start() {
        task = Task { [weak self] in await self?.run() }
    }

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    private var evidenceDir: URL? {
        if let d = env["EMUU_APP_SELFTEST_EVIDENCE"] { return URL(fileURLWithPath: d) }
        return model.env?.paths.logsDirectory
    }

    private func run() async {
        guard let spec = env["EMUU_APP_SELFTEST"] else { return }
        let parts = spec.split(separator: ":").map(String.init)
        guard parts.count == 3, parts[0] == "cycle", let id = InstanceID(rawValue: parts[1]), let count = Int(parts[2]) else {
            return report("SELFTEST bad spec \(spec)")
        }
        let apk = env["EMUU_APP_SELFTEST_APK"].map { URL(fileURLWithPath: $0) }
        report("SELFTEST start pid=\(getpid()) instance=\(id) cycles=\(count) footprint=\(footprintMB()) icons=\(IconLibrary.iconsDirectory?.path ?? "MISSING")")
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .seconds(2))
        // Windows opened automatically for already-running instances count as cycle 0; close them first.
        if model.session(for: id) != nil {
            closeWindow(id)
            await waitFor(seconds: 30) { self.model.session(for: id) == nil }
            try? await Task.sleep(for: .seconds(2))
            report("SELFTEST closed auto-attached window footprint=\(footprintMB()) \(liveCounts())")
        }
        for cycle in 1...max(1, count) {
            let t0 = ContinuousClock.now
            model.openWindow(id)
            let streaming = await waitFor(seconds: 60) {
                guard let s = self.model.session(for: id), let d = s.display else { return false }
                return d.state == .streaming && d.session.stats().totalFrames > 0
            }
            guard streaming, let session = model.session(for: id), let display = session.display else {
                report("SELFTEST cycle \(cycle) FAILED: no frames (phase \(String(describing: model.session(for: id)?.phase)))")
                return finish()
            }
            let toFrames = ContinuousClock.now - t0
            try? await Task.sleep(for: .seconds(2))
            let stats = display.session.stats()
            for _ in 0..<40 {
                await session.refreshStatus()
                if (session.governorStatus?.samplesTaken ?? 0) > 0 || !session.governsMemory { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            report("SELFTEST cycle \(cycle) streaming after \(fmt(toFrames)); frames=\(stats.totalFrames) dropped=\(stats.droppedFrames) streams=\(stats.streamsOpened) transportLatency=\(stats.lastTransportLatencyMs.map { String(format: "%.1fms", $0) } ?? "?") video=\(stats.videoSize.map { "\($0.width)x\($0.height)" } ?? "?") governs=\(session.governsMemory) automation=\(session.automationMode)")

            if cycle == 1, env["EMUU_APP_SELFTEST_ONLY"] == "keyboard" {
                await KeyboardSelfTest(model: model, report: report).run(session)
            } else if cycle == 1, env["EMUU_APP_SELFTEST_ONLY"] == "native" {
                await exerciseNativeDisplay(session)
            } else if cycle == 1 {
                await renderWindow(session)
                await exerciseDeviceActions(session)
                await exerciseVolume(session)
                await exerciseKeyboard(session)
                await exerciseRecording(session)
                if let apk { await exerciseDropInstall(session, apk: apk) }
                await exerciseVisibility(session)
                await exerciseNativeDisplay(session)
            }

            closeWindow(id)
            let detached = await waitFor(seconds: 30) { self.model.session(for: id) == nil }
            try? await Task.sleep(for: .seconds(2))
            report("SELFTEST cycle \(cycle) closed detached=\(detached) footprint=\(footprintMB()) \(liveCounts())")
        }
        // Nothing may be left behind: no instance window, no session.
        for (wid, _) in model.windowControllers { closeWindow(wid) }
        try? await Task.sleep(for: .seconds(1))
        listWindows()
        report("SELFTEST DONE footprint=\(footprintMB()) \(liveCounts())")
        finish()
    }

    private func finish() {
        // Through the run loop, not from inside this main-actor task: `terminate` spins a nested run loop
        // until the quit handler replies, and that reply is itself a main-actor job (it would deadlock).
        if env["EMUU_APP_SELFTEST_QUIT"] == "1" {
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
        }
    }

    private func liveCounts() -> String {
        "liveSessions=\(InstanceSession.liveCount) liveWindowControllers=\(InstanceWindowController.liveCount) windowsOpen=\(model.windowControllers.count)"
    }

    // MARK: Exercises

    private func exerciseDeviceActions(_ session: InstanceSession) async {
        guard let client = session.client else { return }
        session.home()
        var focus = "?"
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(300))
            focus = (try? await client.shell("dumpsys activity activities | grep -m1 topResumedActivity", timeout: .seconds(10)).trimmedStdout) ?? "?"
            if focus.lowercased().contains("launcher") { break }
        }
        report("SELFTEST home key → \(focus)")
        guard let paths = model.env?.paths else { return }
        let dir = InstanceSession.screenshotsDirectory(paths)
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        await session.takeScreenshot()
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        if let new = after.subtracting(before).first(where: { $0.hasPrefix("Emuu ") }) {
            let url = dir.appendingPathComponent(new)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            report("SELFTEST screenshot \(new) bytes=\(size)")
            try? FileManager.default.removeItem(at: url)
        } else {
            report("SELFTEST screenshot FAILED toast=\(session.toast ?? "-")")
        }
        if let status = try? await PlayStore(shell: client).status() {
            report("SELFTEST play store installed=\(status.storeInstalled) version=\(status.storeVersionName ?? "-")")
        }
    }

    /// Volume up/down through the strip's actions (engine key injection over gRPC), checked with `dumpsys audio`.
    private func exerciseVolume(_ session: InstanceSession) async {
        guard let client = session.client else { return }
        func volumes() async -> String {
            let out = (try? await client.shell("dumpsys audio | grep -A6 -E '^- STREAM_(MUSIC|RING):' | grep -E 'STREAM_|streamVolume'", timeout: .seconds(10)).stdoutString) ?? ""
            return out.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        }
        // android-36.1: the first volume key while the panel is closed only opens the panel (same with
        // `adb shell input keyevent VOLUME_UP`), so each direction is pressed twice.
        let v0 = await volumes()
        session.volumeUp()
        try? await Task.sleep(for: .milliseconds(900))
        session.volumeUp()
        try? await Task.sleep(for: .milliseconds(1500))
        let v1 = await volumes()
        session.volumeDown()
        try? await Task.sleep(for: .milliseconds(900))
        session.volumeDown()
        try? await Task.sleep(for: .milliseconds(1500))
        let v2 = await volumes()
        session.back() // close the volume panel
        report("SELFTEST volume before [\(v0)] after up [\(v1)] after down [\(v2)] changed=\(v0 != v1 && v1 != v2)")
    }

    /// Keyboard button off/on with a focused text field; device screenshots as evidence.
    private func exerciseKeyboard(_ session: InstanceSession) async {
        guard let client = session.client else { return }
        let start = session.softKeyboardEnabled
        _ = try? await client.shell("cmd statusbar collapse; am force-stop com.google.android.contacts; am start -a android.intent.action.INSERT -t vnd.android.cursor.dir/contact", timeout: .seconds(15))
        try? await Task.sleep(for: .seconds(3))
        // Find "First name" (the editor's layout varies) and tap it like a user clicking it in the window.
        let ui = (try? await client.shell(SoftKeyboardCommands.dumpUI, timeout: .seconds(20)).stdoutString) ?? ""
        var field = (x: 360, y: 975)
        if let r = ui.range(of: "hint=\"First name\""), let b = ui[..<r.lowerBound].range(of: "bounds=\"", options: .backwards) {
            let nums = ui[b.upperBound...].prefix { $0 != "\"" }.split(whereSeparator: { "[],".contains($0) }).compactMap { Int($0) }
            if nums.count == 4 { field = ((nums[0] + nums[2]) / 2, (nums[1] + nums[3]) / 2) }
        }
        _ = try? await client.shell("input tap \(field.x) \(field.y)", timeout: .seconds(10))
        session.pointerUp(x: field.x, y: field.y)
        try? await Task.sleep(for: .seconds(2))
        let kb = SoftKeyboard(shell: client)
        let s0 = try? await kb.state()
        await save(deviceShot: client, name: "keyboard-0-field-focused.png")
        await session.setSoftKeyboard(false)
        try? await Task.sleep(for: .seconds(1.5))
        let s1 = try? await kb.state()
        await save(deviceShot: client, name: "keyboard-1-button-off.png")
        // With the keyboard off, a tap on the field must not leave it on screen (pointer-up enforcement).
        _ = try? await client.shell("input tap \(field.x) \(field.y)", timeout: .seconds(10))
        session.display?.view.onPointerUp?(field.x, field.y)
        try? await Task.sleep(for: .seconds(2.5))
        let s2 = try? await kb.state()
        await save(deviceShot: client, name: "keyboard-2-tap-while-off.png")
        await session.setSoftKeyboard(true)
        try? await Task.sleep(for: .seconds(2))
        let s3 = try? await kb.state()
        await save(deviceShot: client, name: "keyboard-3-button-on.png")
        let typed = (try? await client.shell("input text emuu", timeout: .seconds(10))) != nil
        try? await Task.sleep(for: .seconds(1))
        await save(deviceShot: client, name: "keyboard-4-typed.png")
        let setting = (try? await client.shell(SoftKeyboardCommands.readSetting, timeout: .seconds(10)).trimmedStdout) ?? "?"
        func d(_ s: SoftKeyboardState?) -> String { s.map { "shown=\($0.imeShown),editor=\($0.editorFocused)" } ?? "?" }
        report("SELFTEST keyboard focused[\(d(s0))] off[\(d(s1))] tapWhileOff[\(d(s2))] on[\(d(s3))] typed=\(typed) show_ime_with_hard_keyboard=\(setting) evidence=keyboard-*.png")
        if !start { await session.setSoftKeyboard(false) }
        _ = try? await client.shell("input keyevent 4; input keyevent 4; input keyevent 3", timeout: .seconds(10))
    }

    private func save(deviceShot client: ADBClient, name: String) async {
        guard let dir = evidenceDir, let png = try? await DeviceHelpers(client: client).screenshotPNG() else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? png.write(to: dir.appendingPathComponent(name))
    }

    /// Record ~6 s while swiping, then check the MP4 with AVFoundation and save its middle frame.
    private func exerciseRecording(_ session: InstanceSession) async {
        guard let client = session.client else { return }
        await session.startRecording()
        guard session.isRecording else { return report("SELFTEST recording FAILED to start: \(session.toast ?? "-")") }
        // While recording, a hidden window keeps streaming and the governor sees the instance as in use.
        let visibleToGovernor = await model.services?.activity.isDisplayVisible(session.id) ?? false
        try? await Task.sleep(for: .seconds(2))
        await renderWindow(session, suffix: "recording", appearances: [("light", .aqua)])
        for _ in 0..<3 {
            _ = try? await client.shell("input swipe 360 1300 360 300 300", timeout: .seconds(10))
            try? await Task.sleep(for: .milliseconds(900))
            _ = try? await client.shell("input keyevent 4", timeout: .seconds(10))
            try? await Task.sleep(for: .milliseconds(900))
        }
        await session.stopRecording()
        guard let result = session.lastRecording, let url = result.files.first else {
            return report("SELFTEST recording FAILED: no file (\(session.toast ?? "-"))")
        }
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let track = try? await asset.loadTracks(withMediaType: .video).first
        let size = try? await track?.load(.naturalSize)
        let codec = (try? await track?.load(.formatDescriptions))?.first.map { CMFormatDescriptionGetMediaSubType($0) }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        var frameNote = "no frame"
        if let image = try? await generator.image(at: CMTime(seconds: duration / 2, preferredTimescale: 600)).image, let dir = evidenceDir {
            let rep = NSBitmapImageRep(cgImage: image)
            let png = dir.appendingPathComponent("record-app-mid-frame.png")
            try? rep.representation(using: .png, properties: [:])?.write(to: png)
            frameNote = "\(image.width)x\(image.height) → \(png.lastPathComponent)"
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        report(String(format: "SELFTEST recording %@ files=%d frames=%d duration=%.2fs bytes=%d size=%@ codec=%@ midFrame=%@ governorSawVisible=%@",
                      url.lastPathComponent, result.files.count, result.frameCount, duration, bytes,
                      size.map { "\(Int($0.width))x\(Int($0.height))" } ?? "?", codec == kCMVideoCodecType_H264 ? "h264" : "?",
                      frameNote, visibleToGovernor ? "true" : "false"))
        if let dir = evidenceDir {
            let dest = dir.appendingPathComponent("record-app.mp4")
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: url, to: dest)
        }
        for f in result.files { try? FileManager.default.removeItem(at: f) }
    }

    /// Drops an APK through the display view's drop handler (the drag & drop code path), launches and
    /// uninstalls it.
    private func exerciseDropInstall(_ session: InstanceSession, apk: URL) async {
        guard let client = session.client, let drop = session.display?.view.onFileDrop else {
            return report("SELFTEST drop install: display view has no drop handler")
        }
        drop([apk])
        let done = await waitFor(seconds: 180) { !session.installJobs.isEmpty && session.installJobs.allSatisfy { !$0.isRunning } }
        let job = session.installJobs.last
        report("SELFTEST drop install \(apk.lastPathComponent) finished=\(done) status=\(String(describing: job?.status))")
        let pm = PackageManager(shell: client)
        if let pkg = try? await APKManifestProbe.packageName(apk) {
            let listed = (try? await client.shell("pm list packages \(pkg)", timeout: .seconds(10)).trimmedStdout) ?? ""
            report("SELFTEST pm list packages \(pkg) → \(listed.isEmpty ? "(none)" : listed)")
            do {
                try await pm.launch(pkg)
                try? await Task.sleep(for: .seconds(2))
                let focus = (try? await client.shell("dumpsys activity activities | grep -m1 topResumedActivity", timeout: .seconds(10)).trimmedStdout) ?? "?"
                report("SELFTEST launched \(pkg) → \(focus)")
                let removed = try await pm.uninstall(pkg)
                report("SELFTEST uninstalled \(pkg) ok=\(removed)")
            } catch {
                report("SELFTEST launch/uninstall failed: \(error.localizedDescription)")
            }
        }
        session.home()
    }

    /// Minimise → the stream pauses; restore (as the Dock does: deminiaturize + activate) → video is back
    /// immediately.
    private func exerciseVisibility(_ session: InstanceSession) async {
        guard let window = model.windowControllers[session.id]?.window else { return report("SELFTEST visibility: no window") }
        window.level = .normal
        window.miniaturize(nil)
        let paused = await waitFor(seconds: 15) { session.display?.state == .paused }
        report("SELFTEST minimized → paused=\(paused) visibleToGovernor=\(await model.services?.activity.isDisplayVisible(session.id) ?? true) streamsOpened=\(session.display?.session.stats().streamsOpened ?? 0)")
        for round in 1...2 {
            let t1 = ContinuousClock.now
            window.deminiaturize(nil)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            // A shell-launched app cannot activate itself (macOS refuses), so the restored window would sit
            // behind the frontmost app — genuinely hidden. Float it above everything so it is really on screen,
            // as it is when the user clicks it in the Dock.
            window.level = .floating
            window.orderFrontRegardless()
            let back = await waitFor(seconds: 30) {
                guard let d = session.display else { return false }
                // A static screen sends one frame on reopen and then nothing: check streaming + that frame.
                return d.state == .streaming && d.session.stats().totalFrames > 0
            }
            report("SELFTEST restore #\(round) → streaming=\(back) after \(fmt(ContinuousClock.now - t1)) [miniaturized=\(window.isMiniaturized) key=\(window.isKeyWindow) appActive=\(NSApp.isActive) occlusionVisible=\(window.occlusionState.contains(.visible)) viewVisible=\(session.display?.view.isEffectivelyVisible ?? false) state=\(session.display?.state.description ?? "-")]")
            window.level = .normal
            if round == 1 {
                window.miniaturize(nil)
                _ = await waitFor(seconds: 15) { session.display?.state == .paused }
            }
        }
    }

    // MARK: Native display (engine framebuffer over gRPC)

    private func shell(_ client: ADBClient, _ cmd: String) async -> String {
        (try? await client.shell(cmd, timeout: .seconds(20)).stdoutString) ?? ""
    }

    private func saveFrame(_ session: InstanceSession, _ name: String) -> String {
        guard let dir = evidenceDir, let png = session.display?.currentFramePNG() else { return "no frame" }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? png.write(to: dir.appendingPathComponent(name))
        let size = session.display?.videoSize.map(\.description) ?? "?"
        return "\(name) \(size)"
    }

    /// Synthesizes a left click on the display view at a frame pixel (the path a real click takes).
    private func click(_ session: InstanceSession, frameX: Int, frameY: Int) {
        guard let view = session.display?.view, let window = view.window else { return }
        let p = view.mapper.viewPoint(fromVideoX: frameX, y: frameY)
        let inWindow = view.convert(p, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                if type == .leftMouseDown { view.mouseDown(with: e) } else { view.mouseUp(with: e) }
            }
        }
    }

    private func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
    }

    private func exerciseNativeDisplay(_ session: InstanceSession) async {
        guard let client = session.client, let display = session.display else { return }
        guard let window = model.windowControllers[session.id]?.window else { return }
        window.level = .floating
        window.orderFrontRegardless()
        // A shell-launched app cannot take focus, and on a busy desktop its window may be occluded; drive the
        // display's visibility input directly (the same callback AppKit's occlusion/miniaturize events use).
        let visibility = display.view.onVisibilityChange
        visibility?(false, false)
        let pausedOK = await waitFor(seconds: 5) { display.state == .paused }
        let framesWhilePaused = display.session.stats().totalFrames
        _ = await shell(client, "input swipe 600 900 100 900 250; input keyevent 3")
        try? await Task.sleep(for: .seconds(1))
        let leaked = display.session.stats().totalFrames - framesWhilePaused
        let tShow = ContinuousClock.now
        visibility?(true, true)
        let shown = await waitFine(seconds: 5) { display.session.stats().totalFrames > framesWhilePaused + leaked }
        let showLatency = ContinuousClock.now - tShow
        report("SELFTEST hidden → paused=\(pausedOK) framesWhilePaused=\(leaked); shown → first frame \(shown ? fmt(showLatency) : "none") (no fps switching: streamsOpened=\(display.session.stats().streamsOpened))")
        display.policy.pauseWhenHidden = false
        model.services?.activity.setVisible(true, for: session.id)
        _ = await waitFor(seconds: 10) { display.state == .streaming }

        // 1. FLAG_SECURE window: what the display pipeline received vs guest-side screencap.
        if await shell(client, "pm path dev.emuu.securetest").contains("package:") {
            _ = await shell(client, "am start -W -n dev.emuu.securetest/.SecureActivity")
            try? await Task.sleep(for: .seconds(2))
            let native = saveFrame(session, "secure-window-native.png")
            await save(deviceShot: client, name: "secure-window-adb-screencap.png")
            report("SELFTEST secure window → \(native) (adb screencap: secure-window-adb-screencap.png) flags=\(await shell(client, "dumpsys window dev.emuu.securetest | grep -m1 -o 'fl=[^ ]*'").trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // 2. Idle cost: static screen → no frames, ~0 CPU.
        _ = await shell(client, "input keyevent 3")
        try? await Task.sleep(for: .seconds(3))
        let f0 = display.session.stats().totalFrames
        let c0 = cpuSeconds()
        try? await Task.sleep(for: .seconds(20))
        let idleCPU = (cpuSeconds() - c0) / 20 * 100
        let idleFrames = display.session.stats().totalFrames - f0
        report(String(format: "SELFTEST idle (home, static, 20 s): frames=%llu appCPU=%.2f%% footprint=%@", idleFrames, idleCPU, footprintMB()))

        // 3. Animation cost: continuous swipes for 10 s.
        let f1 = display.session.stats().totalFrames
        let c1 = cpuSeconds()
        let t1 = ContinuousClock.now
        while ContinuousClock.now - t1 < .seconds(10) {
            _ = await shell(client, "input swipe 600 900 100 900 250; input swipe 100 900 600 900 250")
        }
        let span = ContinuousClock.now - t1
        let secs = Double(span.components.seconds) + Double(span.components.attoseconds) / 1e18
        let animCPU = (cpuSeconds() - c1) / secs * 100
        let animFrames = display.session.stats().totalFrames - f1
        report(String(format: "SELFTEST animation (swipes, %.1f s): frames=%llu (%.1f fps) appCPU=%.1f%% dropped=%llu footprint=%@ transportLatency=%@",
                      secs, animFrames, Double(animFrames) / secs, animCPU, display.session.stats().droppedFrames, footprintMB(),
                      display.session.stats().lastTransportLatencyMs.map { String(format: "%.1fms", $0) } ?? "?"))

        // 4. Input → next frame latency: open the app drawer's search? Use a key that changes the screen: tap
        //    on a blank home area does nothing, so toggle the notification shade with ⌘N-like swipes.
        var latencies: [Double] = []
        for _ in 0..<8 {
            _ = await shell(client, "input keyevent 3")
            try? await Task.sleep(for: .milliseconds(1200))
            let before = display.session.stats().totalFrames
            let t = ContinuousClock.now
            display.press(.appSwitch)
            let got = await waitFine(seconds: 3) { display.session.stats().totalFrames > before }
            let d = ContinuousClock.now - t
            if got { latencies.append(Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000) }
            try? await Task.sleep(for: .milliseconds(800))
        }
        _ = await shell(client, "input keyevent 3")
        let sorted = latencies.sorted()
        report("SELFTEST input→first-frame latency (Recents key, n=\(sorted.count)): min=\(sorted.first.map { String(format: "%.0fms", $0) } ?? "?") median=\(sorted.isEmpty ? "?" : String(format: "%.0fms", sorted[sorted.count / 2])) max=\(sorted.last.map { String(format: "%.0fms", $0) } ?? "?") (polled every 2 ms; excludes ≤1 vsync to glass)")

        // 5. Rotation: Settings (supports landscape); portrait → landscape → portrait, frames saved, tap mapping checked.
        display.rotate(to: .portrait)
        _ = await waitFor(seconds: 10) { display.rotation == .portrait && (display.videoSize?.height ?? 0) > (display.videoSize?.width ?? 0) }
        _ = await shell(client, "settings put system accelerometer_rotation 1; am start -S -W -a android.settings.SETTINGS")
        try? await Task.sleep(for: .seconds(2))
        func rot() async -> String {
            await shell(client, "dumpsys window displays | grep -m1 -o 'mDisplayRotation=ROTATION_[0-9]*'").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        report("SELFTEST rotate step 1: \(saveFrame(session, "rotate-1-portrait.png")) android=\(await rot()) window=\(Int(window.frame.width))x\(Int(window.frame.height))")
        session.rotate()
        _ = await waitFor(seconds: 10) { display.rotation.isLandscape && (display.videoSize?.width ?? 0) > (display.videoSize?.height ?? 0) }
        try? await Task.sleep(for: .seconds(2))
        report("SELFTEST rotate step 2: \(saveFrame(session, "rotate-2-landscape.png")) android=\(await rot()) window=\(Int(window.frame.width))x\(Int(window.frame.height))")
        // Tap "Network & internet" (bounds from uiautomator, in landscape display pixels = frame pixels).
        let ui = await shell(client, "uiautomator dump /sdcard/emuu-ui.xml >/dev/null && cat /sdcard/emuu-ui.xml")
        if let r = ui.range(of: "text=\"Network &amp; internet\""), let b = ui[r.upperBound...].range(of: "bounds=\"") {
            let nums = ui[b.upperBound...].prefix { $0 != "\"" }.split(whereSeparator: { "[],".contains($0) }).compactMap { Int($0) }
            if nums.count == 4 {
                let cx = (nums[0] + nums[2]) / 2, cy = (nums[1] + nums[3]) / 2
                click(session, frameX: cx, frameY: cy)
                try? await Task.sleep(for: .seconds(2))
                let top = await shell(client, "dumpsys activity activities | grep -m1 topResumedActivity").trimmingCharacters(in: .whitespacesAndNewlines)
                let after = await shell(client, "uiautomator dump /sdcard/emuu-ui.xml >/dev/null && cat /sdcard/emuu-ui.xml")
                let title = after.contains("text=\"Internet\"") ? "page shows the 'Internet' entry → Network & internet opened" : "Network page not detected"
                report("SELFTEST landscape tap on 'Network & internet' at frame (\(cx),\(cy)) → \(top) [\(title)]")
                _ = saveFrame(session, "rotate-2b-landscape-after-tap.png")
                display.press(.back)
                try? await Task.sleep(for: .seconds(1))
            }
        } else {
            report("SELFTEST landscape tap: 'Network & internet' not found in the UI dump")
        }
        session.rotate()
        _ = await waitFor(seconds: 10) { display.rotation == .portrait && (display.videoSize?.height ?? 0) > (display.videoSize?.width ?? 0) }
        try? await Task.sleep(for: .seconds(2))
        report("SELFTEST rotate step 3: \(saveFrame(session, "rotate-3-portrait.png")) android=\(await rot()) window=\(Int(window.frame.width))x\(Int(window.frame.height))")
        // Home screen (portrait-locked launcher) rotated: what the user sees.
        _ = await shell(client, "input keyevent 3")
        session.rotate()
        _ = await waitFor(seconds: 10) { display.rotation.isLandscape }
        try? await Task.sleep(for: .seconds(2))
        report("SELFTEST rotate home: \(saveFrame(session, "rotate-4-home-landscape.png")) android=\(await rot())")
        session.rotate()
        _ = await waitFor(seconds: 10) { display.rotation == .portrait }
        try? await Task.sleep(for: .seconds(1))
        window.level = .normal
    }

    /// Renders the window (display area is black: the video layer is not captured) in light and dark mode.
    private func renderWindow(_ session: InstanceSession, suffix: String = "",
                              appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]) async {
        guard let window = model.windowControllers[session.id]?.window, let content = window.contentView, let dir = evidenceDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Wait for a governor sample so the memory indicator shows data.
        try? await Task.sleep(for: .seconds(1))
        // The content view (screen + strip) and, for the plain renders, the frame view (title bar + serial badge).
        let kinds: [(String, NSView)] = suffix.isEmpty ? [("ui-strip", content), ("ui-window", content.superview ?? content)] : [("ui-strip", content)]
        for (name, appearance) in appearances {
            for (kind, view) in kinds {
                window.appearance = NSAppearance(named: appearance)
                view.needsLayout = true
                view.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(600))
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let url = dir.appendingPathComponent("\(kind)-\(suffix.isEmpty ? name : suffix).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                report("SELFTEST rendered \(url.lastPathComponent) \(rep.pixelsWide)x\(rep.pixelsHigh) window=\(Int(window.frame.width))x\(Int(window.frame.height))")
            }
        }
        window.appearance = nil
    }

    // MARK: Helpers

    private func closeWindow(_ id: InstanceID) {
        if let w = model.windowControllers[id]?.window {
            w.performClose(nil)
        } else if model.session(for: id) != nil {
            model.windowClosed(id)
        }
    }

    private func listWindows() {
        for (i, w) in NSApp.windows.enumerated() where w.isVisible || w.isMiniaturized {
            report("SELFTEST window[\(i)] title=\"\(w.title)\" size=\(Int(w.frame.width))x\(Int(w.frame.height)) class=\(type(of: w))")
        }
    }

    @discardableResult
    private func waitFine(seconds: Int, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return condition()
    }

    @discardableResult
    private func waitFor(seconds: Int, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    private func fmt(_ d: Duration) -> String {
        String(format: "%.2fs", Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
    }

    private func footprintMB() -> String {
        guard let r = HostSampler.rusage(pid: getpid()) else { return "?" }
        return String(format: "%.1fMB", Double(r.ri_phys_footprint) / 1_048_576)
    }

    private func report(_ line: String) {
        print(line)
        fflush(stdout)
        EmuuLogger(category: "app.selftest").notice(line)
        guard let paths = model.env?.paths else { return }
        let url = paths.logsDirectory.appendingPathComponent("app-selftest.txt")
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

/// Reads the package name of an APK with EmuuADB's binary-manifest parser (via `unzip`).
enum APKManifestProbe {
    static func packageName(_ apk: URL) async throws -> String? {
        let zip = ZipTool(runner: SystemProcessRunner())
        guard let data = try await zip.read("AndroidManifest.xml", from: apk) else { return nil }
        return try APKManifest.parse(binaryXML: data).packageName
    }
}
