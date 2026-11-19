import Darwin
import Foundation
import ArgumentParser
import EmuuBase
import EmuuEngine
import EmuuADB
import EmuuDisplay
import EmuuGRPC

/// `on` / `off` / `status` for per-instance switches.
enum Switch: String, ExpressibleByArgument, CaseIterable, Sendable {
    case on, off, status
}

/// Splits `[instance] <value>` positionals: one value means the instance comes from -i / defaults.
enum Positionals {
    static func split(_ args: [String]) -> (instance: String?, value: String)? {
        switch args.count {
        case 1: return (nil, args[0])
        case 2: return (args[0], args[1])
        default: return nil
        }
    }
}

extension Switch {
    /// `on phone`, `phone on` or `on` (instance from -i / defaults).
    static func parse(_ args: [String]) -> (instance: String?, mode: Switch)? {
        switch args.count {
        case 1: return Switch(rawValue: args[0]).map { (nil, $0) }
        case 2:
            if let m = Switch(rawValue: args[0]) { return (args[1], m) }
            if let m = Switch(rawValue: args[1]) { return (args[0], m) }
            return nil
        default: return nil
        }
    }
}

// MARK: automation

struct Automation: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Automation mode for tests and scripts driving an instance over adb.",
        discussion: """
        With automation on, the memory governor keeps trimming and killing *background* apps (T1/T2) but never \
        freezes or hibernates the engine, never touches the foreground app or packages with running \
        instrumentation (Espresso, Appium UiAutomator2, Maestro). The setting is saved with the instance and \
        applied at once to a running supervisor (`emuu start`) or Emuu app window.

          emuu automation on phone
          emuu automation off phone
          emuu automation status
        """)

    @Argument(help: "on|off|status [instance]") var args: [String]
    @OptionGroup var option: InstanceOption

    func validate() throws {
        guard Switch.parse(args) != nil else { throw ValidationError("usage: emuu automation on|off|status [<instance>]") }
    }

    func run() async throws {
        let ctx = try CLIContext.live()
        let p = Switch.parse(args)!
        let mode = p.mode
        var config = try ctx.resolveInstance(p.instance ?? option.instance)
        let registry = SupervisorRegistry(paths: ctx.paths)
        if mode != .status {
            let on = mode == .on
            config = try ctx.store.updatePreferences(config.id) { $0.automationMode = on }
            if let sup = registry.liveSupervisor(for: config.id) {
                let reply = try await ControlClient(socketPath: sup.socketPath).send(ControlRequest(command: .automation, enabled: on))
                guard reply.ok else { throw CLIError("supervisor refused: \(reply.message ?? "?")") }
                Out.line("\(config.id): automation mode \(on ? "on" : "off") (applied by supervisor pid \(sup.pid)).")
            } else if let holder = registry.otherHolder(for: config.id) {
                Out.line("\(config.id): automation mode \(on ? "on" : "off"); \(holder) applies it within a few seconds.")
            } else {
                Out.line("\(config.id): automation mode \(on ? "on" : "off") (saved; applies when the instance is governed).")
            }
            return
        }
        var line = "\(config.id): automation mode \(config.isAutomationMode ? "on" : "off")"
        if let sup = registry.liveSupervisor(for: config.id),
           let st = try? await ControlClient(socketPath: sup.socketPath).send(ControlRequest(command: .status)).status {
            line += " · supervisor reports \(st.governor.automationMode == true ? "on" : "off")"
            if let ago = st.governor.adbActivitySecondsAgo { line += " · adb activity from other tools \(Fmt.uptime(ago)) ago" }
        }
        Out.line(line)
    }
}

// MARK: keyboard

struct Keyboard: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show or hide Android's on-screen keyboard (saved per instance; the app's Keyboard button does the same).",
        discussion: """
        on: text fields bring up the soft keyboard (and a focused field gets it now). off: the soft keyboard \
        is hidden now; the Emuu app also closes it again after taps while it is off. Typing on the Mac \
        keyboard works either way.
        """)

    @Argument(help: "on|off|status [instance]") var args: [String]
    @OptionGroup var option: InstanceOption
    @Option(help: "x of the text field to tap if no focused field is found (device pixels).") var tapX: Int?
    @Option(help: "y of the text field to tap if no focused field is found (device pixels).") var tapY: Int?

    func validate() throws {
        guard Switch.parse(args) != nil else { throw ValidationError("usage: emuu keyboard on|off|status [<instance>]") }
    }

    func run() async throws {
        let ctx = try CLIContext.live()
        let p = Switch.parse(args)!
        let mode = p.mode
        var config = try ctx.resolveInstance(p.instance ?? option.instance)
        let client = try await ctx.readyDevice(config)
        let kb = SoftKeyboard(shell: client)
        if mode == .status {
            let st = try await kb.state()
            Out.line("\(config.id): on-screen keyboard \(config.softKeyboardEnabled ? "on" : "off") · now \(st.imeShown ? "shown" : "hidden")\(st.editorFocused ? " (text field focused)" : "")")
            return
        }
        let on = mode == .on
        config = try ctx.store.updatePreferences(config.id) { $0.showSoftKeyboard = on }
        let outcome = try await kb.apply(show: on, lastTap: tapX.flatMap { x in tapY.map { (x, $0) } })
        let detail: String
        switch outcome {
        case .shown: detail = "shown for the focused text field"
        case .hidden: detail = "hidden"
        case .noTextField: detail = on ? "appears when a text field is focused" : "no keyboard on screen"
        case .unchanged: detail = on ? "already shown" : "already hidden"
        }
        Out.line("\(config.id): on-screen keyboard \(on ? "on" : "off") (\(detail)).")
    }
}

// MARK: record

struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record the screen to an MP4 (hardware H.264 from the engine's framebuffer).",
        discussion: """
        Records until Ctrl-C or --duration. A rotation finishes the file and continues in <name>-2.mp4. While \
        recording, the instance is kept awake (the governor does not freeze or hibernate it). Frames come from \
        the engine's own framebuffer, so secure screens are recorded too.

          emuu record phone demo.mp4 --duration 10
        """)

    @Argument(help: "[instance] <out.mp4>") var args: [String]
    @OptionGroup var option: InstanceOption
    @Option(help: "Stop after this many seconds.") var duration: Double?

    func validate() throws {
        guard Positionals.split(args) != nil else { throw ValidationError("usage: emuu record [<instance>] <out.mp4> [--duration s]") }
        if let duration, duration <= 0 { throw ValidationError("--duration must be positive") }
    }

    func run() async throws {
        let ctx = try CLIContext.live()
        let p = Positionals.split(args)!
        let config = try ctx.resolveInstance(p.instance ?? option.instance)
        var url = URL(fileURLWithPath: (p.value as NSString).expandingTildeInPath)
        if url.pathExtension.lowercased() != "mp4" { url.appendPathExtension("mp4") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try await ctx.ensureRunning(config)
        let registry = SupervisorRegistry(paths: ctx.paths)

        let session = ctx.displaySession(config.id)
        let recorder = FrameRecorder(url: url)
        session.setFrameSink(recorder)

        let stop = AsyncStream<String>.makeStream()
        let signals = SignalWatcher(signals: [SIGINT, SIGTERM, SIGHUP]) { _ in stop.continuation.yield("interrupted") }
        defer { signals.cancel() }
        // Reconnect if the stream drops (engine hiccup); the recorder bridges the gap.
        let observer = session.addObserver { event in
            if case .stateChanged(.failed(let reason)) = event {
                Out.err("stream failed (\(reason)); reconnecting…")
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    try? await session.resume()
                }
            }
        }
        defer { session.removeObserver(observer) }
        // Keep the governor (supervisor) from freezing/hibernating the instance while recording.
        let keepAwake = Task {
            while !Task.isCancelled {
                if let sup = registry.liveSupervisor(for: config.id) {
                    let c = ControlClient(socketPath: sup.socketPath)
                    _ = try? await c.send(ControlRequest(command: .visibility, visible: true))
                    _ = try? await c.send(ControlRequest(command: .touch))
                }
                try? await Task.sleep(for: .seconds(20))
            }
        }
        recorder.start()
        do { try await session.start() } catch {
            keepAwake.cancel()
            _ = await recorder.finish()
            throw CLIError("display stream: \(describe(error))")
        }
        let t0 = ContinuousClock.now
        Out.err("Recording \(config.id) → \(url.path)\(duration.map { " for \(Fmt.seconds(.milliseconds(Int64($0 * 1000))))" } ?? "; Ctrl-C to stop")…")
        let timer = Task {
            if let duration {
                try? await Task.sleep(for: .milliseconds(Int64(duration * 1000)))
                stop.continuation.yield("duration reached")
            }
        }
        for await _ in stop.stream { break }
        timer.cancel()
        keepAwake.cancel()
        let result = await recorder.finish()
        await session.stop()
        if let sup = registry.liveSupervisor(for: config.id) {
            _ = try? await ControlClient(socketPath: sup.socketPath).send(ControlRequest(command: .visibility, visible: false))
        }
        guard !result.files.isEmpty else { throw CLIError("no frames arrived; nothing was recorded") }
        Out.line("Recorded \(result.frameCount) frames, \(Fmt.seconds(result.duration)) of video in \(Fmt.seconds(ContinuousClock.now - t0)):")
        for f in result.files {
            let size = (try? FileManager.default.attributesOfItem(atPath: f.path)[.size] as? NSNumber)?.uint64Value
            Out.line("  \(f.path) (\(Fmt.bytes(size)))")
        }
    }
}

struct Rotate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Rotate the device (portrait, landscape, left, right, or toggle).",
        discussion: """
        Turns the virtual device itself (the engine's orientation sensors, like Android Studio's rotate \
        buttons) and makes sure Android's auto-rotate is on, so apps that support landscape follow. Apps locked \
        to portrait (the phone home screen) stay portrait and are shown sideways, as on a real phone.

          emuu rotate phone landscape      # = left: turned counter-clockwise
          emuu rotate phone right          # turned clockwise
          emuu rotate phone                # toggle portrait ↔ landscape
        """)

    @Argument(help: "[instance] [portrait|landscape|left|right|toggle]") var args: [String] = []
    @OptionGroup var option: InstanceOption

    static let orientations = ["portrait", "landscape", "left", "right", "toggle", "upside-down"]

    func parsed() -> (instance: String?, orientation: String) {
        var a = args
        var orientation = "toggle"
        if let last = a.last, Self.orientations.contains(last.lowercased()) { orientation = last.lowercased(); a.removeLast() }
        return (a.first, orientation)
    }

    func validate() throws {
        if args.count > 2 { throw ValidationError("usage: emuu rotate [<instance>] [portrait|landscape|left|right|toggle]") }
        let p = parsed()
        if args.count == 2, !Self.orientations.contains(args[1].lowercased()) {
            throw ValidationError("orientation must be one of \(Self.orientations.joined(separator: ", "))")
        }
        _ = p
    }

    static func target(_ word: String, current: SkinRotation) -> SkinRotation {
        switch word {
        case "portrait": return .portrait
        case "landscape", "left": return .landscape
        case "right": return .reverseLandscape
        case "upside-down": return .reversePortrait
        default: return current.isLandscape ? .portrait : .landscape
        }
    }

    func run() async throws {
        let ctx = try CLIContext.live()
        let p = parsed()
        let config = try ctx.resolveInstance(p.instance ?? option.instance)
        let client = try await ctx.readyDevice(config)
        _ = try? await client.shell("settings put system accelerometer_rotation 1", timeout: .seconds(10))
        let session = ctx.displaySession(config.id)
        defer { Task { await session.stop() } }
        let current: SkinRotation
        do { current = try await session.currentRotation() } catch {
            throw CLIError("rotation needs the engine's gRPC endpoint: \(describe(error))")
        }
        let target = Self.target(p.orientation, current: current)
        try await session.setRotation(target)
        try? await Task.sleep(for: .milliseconds(800))
        let rotation = (try? await client.shell("dumpsys window displays | grep -m1 -o 'mDisplayRotation=ROTATION_[0-9]*'", timeout: .seconds(10)).trimmedStdout) ?? ""
        Out.line("\(config.id): device \(current) → \(target)\(rotation.isEmpty ? "" : " (Android: \(rotation.replacingOccurrences(of: "mDisplayRotation=", with: "")))").")
        await session.stop()
    }
}
