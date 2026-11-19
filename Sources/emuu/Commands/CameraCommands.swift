import Foundation
import ImageIO
import ArgumentParser
import EmuuBase
import EmuuEngine

extension CameraSource: ExpressibleByArgument {}

struct Camera: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Cameras: status, back/front source, Mac cameras, and showing a picture to the back camera.",
        discussion: """
        Sources (per camera, saved for the instance):
          none           Android has no such camera (instances created before camera support).
          virtualscene   Back camera only: a rendered room whose wall poster can show any picture
                         (`emuu camera show`). Default for the back camera of new instances.
          emulated       Android's software test camera (moving scene). Default for the front camera.
          webcam0, webcam:<name or id>
                         A Mac camera (`emuu camera list-host`). The process that starts the engine needs
                         macOS camera permission (Emuu.app asks; from a terminal, macOS asks for the terminal app).

        Android lists its cameras when it boots, so `set` applies at the next start, which cold-boots once (apps and
        data are kept). Farm clones keep their golden's cameras; re-seal the golden to change them.

          emuu camera status phone
          emuu camera set phone --back virtualscene --front emulated
          emuu camera show phone qr.png        # the back camera now sees qr.png (no restart, ~0.1 s)
          emuu camera play phone selfie.mov --fps 10   # a video, frame by frame on the poster
          emuu camera clear phone              # default room again
          emuu camera list-host
        """,
        subcommands: [CameraStatus.self, CameraSet.self, CameraListHost.self, CameraShow.self, CameraPlay.self, CameraClear.self, CameraAim.self])
}

/// What `emuu camera status --json` prints.
struct CameraStatusReport: Codable, Sendable {
    struct Side: Codable, Sendable {
        /// Saved setting (`none`, `emulated`, `virtualscene`, `webcam0`, `webcam:<id>`).
        var setting: String
        /// What this instance launches with (setting + `EMUU_CAMERA_*` override), as an engine value when known.
        var effective: String
        /// What the running engine has (nil when stopped).
        var running: String?
    }
    var instance: String
    var running: Bool
    var back: Side
    var front: Side
    /// The running engine has other cameras than the setting: the next start cold-boots once to switch.
    var restartNeeded: Bool
    /// Picture on the virtual scene's wall poster (`emuu camera show`), nil when the default room is shown.
    var shownImage: String?
    var note: String?
}

enum CameraCLI {
    static func report(_ ctx: CLIContext, _ config: InstanceConfig) async -> CameraStatusReport {
        let running = ctx.store.isRunning(config.id)
        let launched = running ? CameraLaunchPlan.launchedCameras(avdDirectory: ctx.paths.avdDirectory(for: config.id)) : nil
        let effective = config.effectiveCamera(environment: ctx.environment)
        func value(_ s: CameraSource) -> String { HostCameraList.engineValue(s, hostCameras: nil) ?? s.argument }
        let backEff = value(effective.back), frontEff = value(effective.front)
        var restart = false
        if let l = launched {
            restart = (l.back != backEff && !(effective.back.isWebcam && l.back.hasPrefix("webcam")))
                || (l.front != frontEff && !(effective.front.isWebcam && l.front.hasPrefix("webcam")))
        }
        var pid: Int32?
        if running, let engine = try? await ctx.engines.engine(for: config.id) { _ = await engine.refresh(); pid = await engine.enginePID() }
        let shown = CameraShownState.load(ctx.paths, config.id, pid: pid)
        var note: String?
        if restart {
            note = config.goldenSource != nil
                ? "farm clone: keeps its golden's cameras until the golden is re-sealed"
                : "the next start switches cameras (one cold boot; apps and data are kept)"
        }
        return CameraStatusReport(instance: config.id.rawValue, running: running,
                                  back: .init(setting: config.cameraConfig.back.argument, effective: backEff, running: launched?.back),
                                  front: .init(setting: config.cameraConfig.front.argument, effective: frontEff, running: launched?.front),
                                  restartNeeded: restart, shownImage: shown?.image, note: note)
    }

    static func print(_ r: CameraStatusReport) {
        func side(_ name: String, _ s: CameraStatusReport.Side) -> String {
            var line = "  \(name): \(s.setting)"
            if s.effective != s.setting { line += " → \(s.effective)" }
            if let run = s.running, run != s.effective { line += " (running: \(run))" }
            return line
        }
        Out.line("\(r.instance)\(r.running ? " (running)" : ""):")
        Out.line(side("back ", r.back))
        Out.line(side("front", r.front))
        if let img = r.shownImage { Out.line("  showing: \(img)") }
        if let n = r.note { Out.line("  note: \(n)") }
    }

    /// The scene controller for a running instance whose engine has the virtual scene back camera.
    static func scene(_ ctx: CLIContext, _ config: InstanceConfig) async throws -> (VirtualSceneCamera, Int32) {
        _ = try await ctx.ensureRunning(config)
        let engine = try await ctx.engines.engine(for: config.id)
        do {
            return try await VirtualSceneAccess.open(paths: ctx.paths, engine: engine, config: config)
        } catch {
            let now = CameraLaunchPlan.launchedCameras(avdDirectory: ctx.paths.avdDirectory(for: config.id))?.back ?? "unknown"
            guard now != "virtualscene" else { throw CLIError(describe(error)) }
            let fix = config.cameraConfig.back == .virtualScene
                ? "It is set to virtualscene but the engine started with \(now): restart it (`emuu stop \(config.id)` then `emuu start \(config.id)`)."
                : "Run `emuu camera set \(config.id) --back virtualscene`, then restart it."
            throw CLIError("\(config.id): the running back camera is \(now), not the virtual scene. \(fix)")
        }
    }

    /// `[instance] <file>` positional parsing (instance optional).
    static func instanceAndFile(_ args: [String]) -> (instance: String?, file: String)? {
        switch args.count {
        case 1: return (nil, args[0])
        case 2: return (args[0], args[1])
        default: return nil
        }
    }
}

struct CameraStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show an instance's cameras (setting, running, shown picture).")
    @Argument(help: "Instance (default: the only/running one).") var instance: String?
    @OptionGroup var option: InstanceOption
    @Flag(help: "JSON output.") var json = false

    func run() async throws {
        let ctx = try CLIContext.live()
        let config = try ctx.resolveInstance(instance ?? option.instance)
        let r = await CameraCLI.report(ctx, config)
        if json { return try Out.json(r) }
        CameraCLI.print(r)
    }
}

struct CameraSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set the back and/or front camera (saved; applies at the next start, one cold boot).",
        discussion: "Values: none, emulated, virtualscene (back only), webcam<N>, webcam:<name or unique id> (see `emuu camera list-host`).")
    @Argument(help: "Instance (default: the only/running one).") var instance: String?
    @OptionGroup var option: InstanceOption
    @Option(help: "Back camera source.") var back: CameraSource?
    @Option(help: "Front camera source.") var front: CameraSource?
    @Flag(help: "JSON output.") var json = false

    func validate() throws {
        if back == nil && front == nil { throw ValidationError("give --back and/or --front") }
        var c = CameraConfig.off
        if let back { c.back = back }
        if let front { c.front = front }
        if front == .virtualScene { throw ValidationError(c.problems.first ?? "invalid camera") }
    }

    func run() async throws {
        let ctx = try CLIContext.live()
        var config = try ctx.resolveInstance(instance ?? option.instance)
        var cams = config.cameraConfig
        if let back { cams.back = back }
        if let front { cams.front = front }
        do { try cams.validate() } catch { throw CLIError(describe(error)) }
        config = try ctx.store.updatePreferences(config.id) { $0.camera = cams }
        let r = await CameraCLI.report(ctx, config)
        if json { return try Out.json(r) }
        CameraCLI.print(r)
        if !r.running { Out.line("Applies at the next start (one cold boot when the cameras change).") }
        if cams.back.isWebcam || cams.front.isWebcam {
            Out.line("Mac cameras need camera permission for the process that starts the engine (Emuu.app asks when it starts the device; a terminal asks for the terminal app).")
        }
    }
}

struct CameraListHost: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list-host", abstract: "List the Mac's cameras (no camera is opened, no permission needed).")
    @Flag(help: "JSON output.") var json = false

    func run() async throws {
        let ctx = try CLIContext.live()
        let cams = try await HostCameraList.query(sdk: ctx.sdk)
        if json { return try Out.json(cams) }
        if cams.isEmpty { return Out.line("No cameras connected.") }
        Out.line(Fmt.table(["ENGINE", "NAME", "UNIQUE ID", "FORMAT"],
                           cams.map { [$0.engineName, $0.name ?? "–", $0.uniqueID, $0.pixelFormat ?? "–"] }))
        Out.line("Use as `--back webcam:\"<name>\"` or `--front \(cams[0].engineName)`.")
    }
}

struct CameraShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show a picture to the back camera now (virtual scene; no restart).",
        discussion: """
        The picture (PNG, JPEG, HEIC, …) is letterboxed onto the virtual scene's wall poster and the camera is \
        moved in front of it, so apps see it filling the frame (1280×960, 4:3, rotated by the sensor's 90° like a \
        real phone). Needs the back camera set to virtualscene in the running engine. Swapping pictures takes about \
        0.1 s; the next camera frame shows the new one. `emuu camera clear` restores the room.

          emuu camera show phone ~/qr.png && adb -s emulator-5554 shell am start -n com.example/.ScanActivity
        """)
    @Argument(help: "[instance] <image>") var args: [String]
    @OptionGroup var option: InstanceOption
    @Flag(help: "Back camera (the default; the only camera that can show a picture).") var back = false
    @Flag(help: "Front camera: not supported by engine 36.4.9 (no picture source for the front camera).") var front = false
    @Flag(help: "Swap the poster only; do not move the camera.") var noAim = false
    @Option(help: "Distance from the poster in metres (default \(VirtualSceneCamera.aimDistance)).") var distance: Float?
    @Flag(help: "JSON output.") var json = false

    func validate() throws {
        guard CameraCLI.instanceAndFile(args) != nil else { throw ValidationError("usage: emuu camera show [<instance>] <image>") }
        if front {
            throw ValidationError("the engine has no picture source for the front camera (it supports the virtual scene for the back camera only); use the back camera")
        }
    }

    func run() async throws {
        let ctx = try CLIContext.live()
        let p = CameraCLI.instanceAndFile(args)!
        let config = try ctx.resolveInstance(p.instance ?? option.instance)
        let file = URL(fileURLWithPath: (p.file as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: file.path) else { throw CLIError("No such file: \(file.path)") }
        let (scene, pid) = try await CameraCLI.scene(ctx, config)
        let r: VirtualSceneCamera.ShowResult
        do { r = try await scene.show(image: file, aim: !noAim, distance: distance ?? VirtualSceneCamera.aimDistance) } catch {
            throw CLIError("show: \(describe(error))")
        }
        CameraShownState(enginePID: pid, image: file.path, poster: r.poster, shownAt: Date()).save(ctx.paths, config.id)
        if json { return try Out.json(r) }
        Out.line("\(config.id): back camera shows \(file.lastPathComponent) (\(r.imageWidth)×\(r.imageHeight)) — swap \(String(format: "%.0f", r.swapMilliseconds)) ms, total \(String(format: "%.0f", r.totalMilliseconds)) ms.")
    }
}

struct CameraClear: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clear", abstract: "Restore the virtual scene's default posters and camera position.")
    @Argument(help: "Instance (default: the only/running one).") var instance: String?
    @OptionGroup var option: InstanceOption
    @Flag(help: "JSON output.") var json = false

    func run() async throws {
        let ctx = try CLIContext.live()
        let config = try ctx.resolveInstance(instance ?? option.instance)
        let (scene, _) = try await CameraCLI.scene(ctx, config)
        do { try await scene.clear() } catch { throw CLIError("clear: \(describe(error))") }
        CameraShownState.remove(ctx.paths, config.id)
        if json { return try Out.json(["instance": config.id.rawValue, "shownImage": nil as String?]) }
        Out.line("\(config.id): back camera shows the default room.")
    }
}

struct CameraAim: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "aim",
        abstract: "Move/turn the virtual scene camera (device position in metres, rotation in degrees).",
        discussion: """
        Without options prints the current pose. --poster moves in front of the wall poster (what `show` does), \
        --home goes back to the start pose. The pose is the device's physical model, so rotation also turns the \
        device's motion sensors.
        """)
    @Argument(help: "Instance (default: the only/running one).") var instance: String?
    @OptionGroup var option: InstanceOption
    @Option(help: "x,y,z in metres.") var position: String?
    @Option(help: "x,y,z in degrees.") var rotation: String?
    @Flag(help: "Face the wall poster.") var poster = false
    @Flag(help: "Start pose (origin, upright).") var home = false
    @Flag(help: "JSON output.") var json = false

    static func triple(_ s: String) throws -> [Float] {
        let v = s.split(separator: ",").map { Float($0.trimmingCharacters(in: .whitespaces)) }
        guard v.count == 3, v.allSatisfy({ $0 != nil }) else { throw ValidationError("expected x,y,z, got '\(s)'") }
        return v.map { $0! }
    }

    func validate() throws {
        if let position { _ = try Self.triple(position) }
        if let rotation { _ = try Self.triple(rotation) }
    }

    func run() async throws {
        let ctx = try CLIContext.live()
        let config = try ctx.resolveInstance(instance ?? option.instance)
        let (scene, _) = try await CameraCLI.scene(ctx, config)
        var pose = try await scene.currentPose()
        if poster { pose = VirtualSceneCamera.aimPose() }
        if home { pose = .home }
        if let position { pose.position = try Self.triple(position) }
        if let rotation { pose.rotation = try Self.triple(rotation) }
        if poster || home || position != nil || rotation != nil { try await scene.setPose(pose) }
        if json { return try Out.json(pose) }
        Out.line("\(config.id): \(pose)")
    }
}

struct CameraPlay: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "play",
        abstract: "Play a video (or a folder of images) to the back camera, frame by frame on the virtual scene's poster.",
        discussion: """
        The engine's own video camera mode hangs Android's camera on 36.4.9, so Emuu shows the frames one after \
        another on the wall poster (same mechanism as `show`). Frames are extracted at --fps (AVFoundation: MP4, MOV, \
        …), at most 600, 1024 px. The last frame stays shown afterwards; `emuu camera clear` restores the room.

          emuu camera play phone face.mov --fps 10            # once
          emuu camera play phone ./frames --fps 5 --loops 0   # a folder of images, until Ctrl-C
        """)
    @Argument(help: "[instance] <video file or folder of images>") var args: [String]
    @OptionGroup var option: InstanceOption
    @Option(help: "Frames per second.") var fps: Double = 10
    @Option(help: "How many times to play it (0 = until interrupted).") var loops: Int = 1
    @Flag(help: "JSON output.") var json = false

    func validate() throws {
        guard CameraCLI.instanceAndFile(args) != nil else { throw ValidationError("usage: emuu camera play [<instance>] <video|folder>") }
        guard fps > 0, fps <= 30 else { throw ValidationError("--fps must be in 0…30") }
        guard loops >= 0 else { throw ValidationError("--loops must be 0 (forever) or more") }
    }

    func run() async throws {
        let ctx = try CLIContext.live()
        let p = CameraCLI.instanceAndFile(args)!
        let config = try ctx.resolveInstance(p.instance ?? option.instance)
        let src = URL(fileURLWithPath: (p.file as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: src.path, isDirectory: &isDir) else { throw CLIError("No such file: \(src.path)") }
        let (scene, pid) = try await CameraCLI.scene(ctx, config)
        Out.progress("Preparing frames…")
        let posters: [URL]
        do {
            if isDir.boolValue {
                let names = try FileManager.default.contentsOfDirectory(atPath: src.path).sorted()
                let images = names.map { src.appendingPathComponent($0) }.filter { ["png", "jpg", "jpeg", "heic", "tif", "tiff", "bmp", "gif"].contains($0.pathExtension.lowercased()) }
                guard !images.isEmpty else { throw CLIError("no images in \(src.path)") }
                let out = scene.workDirectory.appendingPathComponent("video", isDirectory: true)
                try? FileManager.default.removeItem(at: out)
                posters = try images.enumerated().map { i, url in
                    guard let s = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(s, 0, nil) else {
                        throw CLIError("not an image: \(url.path)")
                    }
                    return try PosterImage.prepare(img, to: out.appendingPathComponent(String(format: "frame-%05d.png", i)), maxSide: 1024).url
                }
            } else {
                posters = try await VideoPosterFrames.extract(src, fps: fps, into: scene.workDirectory)
            }
        } catch let e as CLIError { throw e } catch { throw CLIError("frames: \(describe(error))") }
        Out.endProgress()
        if !json { Out.err("Playing \(posters.count) frames at \(fps) fps\(loops == 0 ? " until Ctrl-C" : loops > 1 ? " × \(loops)" : "")…") }
        let r: VirtualSceneCamera.PlayResult
        do { r = try await scene.play(posters: posters, fps: fps, loops: loops) } catch { throw CLIError("play: \(describe(error))") }
        CameraShownState(enginePID: pid, image: src.path, poster: posters.last!.path, shownAt: Date()).save(ctx.paths, config.id)
        if json { return try Out.json(r) }
        Out.line("\(config.id): played \(r.shown) frames at \(String(format: "%.1f", r.achievedFPS)) fps (swap median \(String(format: "%.0f", r.medianSwapMilliseconds)) ms, max \(String(format: "%.0f", r.maxSwapMilliseconds)) ms).")
    }
}
