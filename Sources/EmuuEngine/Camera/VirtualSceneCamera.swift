import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import EmuuBase
import EmuuGRPC

/// Puts a chosen picture in front of the back camera without restarting anything: the engine's virtual scene
/// (`-camera-back virtualscene`, a rendered room) has a 2 m × 2 m "wall" poster whose image the console command
/// `virtualscene-image wall <file>` replaces at runtime, and the scene camera follows the device's physical-model
/// position and rotation, which gRPC `setPhysicalModel` sets. `show` letterboxes the picture onto a square
/// poster, swaps it in and moves the device in front of the poster so it fills the camera frame. Measured numbers
/// (frame size, swap time) are in docs/engine-findings.md ("Camera").
public struct VirtualSceneCamera: Sendable {
    /// The wall poster (from `emulator/resources/Toren1BD.posters`): centre, yaw, edge length.
    public static let posterCentre: (x: Float, y: Float, z: Float) = (-0.807, 0.320, 5.316)
    public static let posterYawDegrees: Float = -150
    public static let posterSize: Float = 2

    /// Device pose that frames the wall poster (position in metres, rotation in degrees), see `aimPose`.
    public struct Pose: Codable, Sendable, Hashable, CustomStringConvertible {
        public var position: [Float]
        public var rotation: [Float]
        public init(position: [Float], rotation: [Float]) {
            self.position = position
            self.rotation = rotation
        }
        /// The engine's start pose: at the origin, upright, facing the default view.
        public static let home = Pose(position: [0, 0, 0], rotation: [0, 0, 0])
        public var description: String {
            "position \(position.map { String(format: "%.3f", $0) }.joined(separator: ",")) rotation \(rotation.map { String(format: "%.1f", $0) }.joined(separator: ","))"
        }
    }

    /// The picture goes into the top-centre square of the poster covering this fraction of its edge (1.5 m of 2 m):
    /// a shelf in the room stands in front of the poster's lower right part (measured: it hides the bottom ~18 % of
    /// the poster's right half from the front), so the lower quarter stays empty.
    public static let pictureFraction: Float = 0.75
    /// The picture region's centre is this far above the poster's centre: (1 − fraction) / 2 × 2 m.
    public static var pictureLift: Float { (1 - pictureFraction) / 2 * posterSize }

    /// Distance (metres) at which the 1.5 m picture region spans about 87 % of the short side of the 4:3 frame
    /// (measured: at 2.2 m the 2 m poster spans 870 of 960 px).
    public static let aimDistance: Float = 1.65
    /// Sideways correction (metres, + = towards the screen's right): the rendered poster sits slightly off its listed
    /// centre (measured 2026-11-19: the picture centre was ~65 px of 960 left of the frame centre without it).
    public static let aimLateral: Float = -0.11

    /// The pose that looks straight at the picture region of the wall poster from `distance` metres (pure,
    /// unit-tested). The back camera looks along the device's −z; turning the device by the poster's yaw makes it
    /// look along the poster's inward normal.
    public static func aimPose(distance: Float = aimDistance, lateral: Float = aimLateral) -> Pose {
        let yaw = posterYawDegrees * .pi / 180
        // Poster normal (pointing into the room) = rotation of +z by the yaw.
        let nx = sin(yaw), nz = cos(yaw)
        // Device x axis (screen right) = rotation of +x by the yaw; `lateral` moves along it.
        let rx = cos(yaw), rz = -sin(yaw)
        return Pose(position: [posterCentre.x + nx * distance + rx * lateral, posterCentre.y + pictureLift,
                               posterCentre.z + nz * distance + rz * lateral],
                    rotation: [0, posterYawDegrees, 0])
    }

    public let console: ConsoleClient
    public let grpc: EmulatorGRPCEndpoint?
    /// Where prepared poster files go (no whitespace allowed: the console splits arguments on spaces).
    public let workDirectory: URL

    public init(console: ConsoleClient, grpc: EmulatorGRPCEndpoint?, workDirectory: URL) {
        self.console = console
        self.grpc = grpc
        self.workDirectory = workDirectory
    }

    public struct ShowResult: Codable, Sendable, Hashable {
        public var source: String
        public var poster: String
        public var imageWidth: Int
        public var imageHeight: Int
        public var pose: Pose?
        /// Wall time of the console swap (the next rendered camera frame shows the picture).
        public var swapMilliseconds: Double
        public var totalMilliseconds: Double
    }

    /// Shows `image` (PNG, JPEG, HEIC, … anything ImageIO reads) on the wall poster and, unless `aim` is false,
    /// moves the camera in front of it.
    public func show(image: URL, aim: Bool = true, distance: Float = aimDistance) async throws -> ShowResult {
        let t0 = ContinuousClock.now
        let prepared = try PosterImage.prepare(image, in: workDirectory)
        let t1 = ContinuousClock.now
        try await setWall(prepared.url.path)
        let t2 = ContinuousClock.now
        var pose: Pose?
        if aim {
            let p = Self.aimPose(distance: distance)
            try await setPose(p)
            pose = p
        }
        PosterImage.prune(workDirectory, keeping: prepared.url)
        let ms: (Duration) -> Double = { Double($0.components.seconds) * 1000 + Double($0.components.attoseconds) / 1e15 }
        return ShowResult(source: image.path, poster: prepared.url.path, imageWidth: prepared.width, imageHeight: prepared.height,
                          pose: pose, swapMilliseconds: ms(t2 - t1), totalMilliseconds: ms(ContinuousClock.now - t0))
    }

    public struct PlayResult: Codable, Sendable, Hashable {
        public var frames: Int
        public var shown: Int
        public var requestedFPS: Double
        public var achievedFPS: Double
        /// Median / slowest console swap.
        public var medianSwapMilliseconds: Double
        public var maxSwapMilliseconds: Double
    }

    /// Plays `posters` (prepared PNGs) on the wall poster at `fps`, `loops` times (0 = until cancelled). A video
    /// stand-in: the engine's own `videofile:` camera hangs the guest HAL on 36.4.9 (see `CameraSource`).
    public func play(posters: [URL], fps: Double, loops: Int, aim: Bool = true, distance: Float = aimDistance) async throws -> PlayResult {
        guard !posters.isEmpty, fps > 0 else { throw EmuuError.invalidConfiguration("nothing to play") }
        if aim { try await setPose(Self.aimPose(distance: distance)) }
        let interval = Duration.nanoseconds(Int64(1e9 / fps))
        let clock = ContinuousClock()
        let start = clock.now
        var next = start
        var swaps: [Double] = []
        var shown = 0
        var pass = 0
        while loops == 0 || pass < loops {
            for p in posters {
                try Task.checkCancellation()
                let t = clock.now
                try await setWall(p.path)
                let d = clock.now - t
                swaps.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
                shown += 1
                next += interval
                if next > clock.now { try await Task.sleep(until: next, clock: clock) } else { next = clock.now }
            }
            pass += 1
        }
        let elapsed = clock.now - start
        let secs = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let sorted = swaps.sorted()
        return PlayResult(frames: posters.count, shown: shown, requestedFPS: fps, achievedFPS: secs > 0 ? Double(shown) / secs : 0,
                          medianSwapMilliseconds: sorted[sorted.count / 2], maxSwapMilliseconds: sorted.last ?? 0)
    }

    /// Default posters and the start pose: the camera sees the stock room again.
    public func clear(resetPose: Bool = true) async throws {
        _ = try await console.send("virtualscene-image wall")
        _ = try await console.send("virtualscene-image table")
        if resetPose { try await setPose(.home) }
        PosterImage.prune(workDirectory, keeping: nil)
    }

    /// `virtualscene-image wall <path>` (an empty path restores the default poster).
    public func setWall(_ path: String) async throws {
        guard !path.contains(where: \.isWhitespace) else {
            throw EmuuError.invalidConfiguration("poster path must not contain spaces (the console splits on them): \(path)")
        }
        let reply = try await console.send("virtualscene-image wall \(path)")
        if reply.contains("KO") { throw EmuuError.console("virtualscene-image: \(reply)") }
    }

    /// Moves/turns the device (and so the scene camera) through gRPC.
    public func setPose(_ pose: Pose) async throws {
        guard let grpc else { throw EmuuError.engine("aiming the camera needs the engine's gRPC endpoint (start the instance with this Emuu)") }
        let controller = try EmulatorController(endpoint: grpc)
        defer { controller.close() }
        try await controller.setPhysicalModel(EmulatorPhysicalValue(target: EmulatorPhysicalValue.position, values: pose.position))
        try await controller.setPhysicalModel(EmulatorPhysicalValue(target: EmulatorPhysicalValue.rotation, values: pose.rotation))
    }

    public func currentPose() async throws -> Pose {
        guard let grpc else { throw EmuuError.engine("reading the pose needs the engine's gRPC endpoint") }
        let controller = try EmulatorController(endpoint: grpc)
        defer { controller.close() }
        let p = try await controller.physicalModel(EmulatorPhysicalValue.position)
        let r = try await controller.physicalModel(EmulatorPhysicalValue.rotation)
        return Pose(position: p.values, rotation: r.values)
    }

    /// A directory for poster files under `preferred` when its path has no whitespace, else under the system
    /// temporary directory.
    public static func workDirectory(preferred: URL, instance: InstanceID) -> URL {
        let base = preferred.path.contains(where: \.isWhitespace) ? FileManager.default.temporaryDirectory.appendingPathComponent("emuu-camera") : preferred
        return base.appendingPathComponent(instance.rawValue, isDirectory: true)
    }
}

/// Square poster files for the virtual scene: the picture letterboxed (aspect kept) on white, at most 2048 px.
public enum PosterImage {
    public static let maxSide = 2048

    public struct Prepared: Sendable {
        public var url: URL
        public var width: Int
        public var height: Int
    }

    /// Side of the square poster canvas for a `w`×`h` picture and where the picture goes in it (pure, unit-tested;
    /// CoreGraphics coordinates, origin bottom left). The picture is fitted (aspect kept) into the top-centre square
    /// covering `fraction` of the edge; the rest is white.
    public static func layout(width w: Int, height h: Int, maxSide: Int = maxSide,
                              fraction: Double = Double(VirtualSceneCamera.pictureFraction)) -> (side: Int, rect: CGRect) {
        let longest = max(w, h, 1)
        let side = min(Int((Double(longest) / fraction).rounded()), maxSide)
        let region = Double(side) * fraction
        let scale = region / Double(longest)
        let dw = Double(w) * scale, dh = Double(h) * scale
        let regionX = (Double(side) - region) / 2, regionY = Double(side) - region   // top of the canvas
        return (side, CGRect(x: regionX + (region - dw) / 2, y: regionY + (region - dh) / 2, width: dw, height: dh))
    }

    public static func prepare(_ source: URL, in directory: URL) throws -> Prepared {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw EmuuError.io(path: source.path, message: "not an image ImageIO can read")
        }
        // A new name per call: the engine loads the file when the command arrives, and an older file may still be
        // read by a command in flight.
        let url = directory.appendingPathComponent("poster-\(UInt64(Date().timeIntervalSince1970 * 1000)).png")
        return try prepare(image, to: url, maxSide: maxSide)
    }

    /// Letterboxes `image` onto a square canvas (at most `maxSide` px) and writes it as PNG to `url`.
    public static func prepare(_ image: CGImage, to url: URL, maxSide: Int = maxSide) throws -> Prepared {
        let source = url
        let directory = url.deletingLastPathComponent()
        let (side, rect) = layout(width: image.width, height: image.height, maxSide: maxSide)
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw EmuuError.io(path: source.path, message: "could not create a \(side)×\(side) canvas")
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: rect)
        guard let out = ctx.makeImage() else { throw EmuuError.io(path: source.path, message: "drawing the poster failed") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw EmuuError.io(path: url.path, message: "cannot write PNG")
        }
        CGImageDestinationAddImage(dest, out, nil)
        guard CGImageDestinationFinalize(dest) else { throw EmuuError.io(path: url.path, message: "cannot write PNG") }
        return Prepared(url: url, width: image.width, height: image.height)
    }

    /// Deletes older poster files (keeps `keeping` and the newest previous one).
    public static func prune(_ directory: URL, keeping: URL?) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        let posters = names.filter { $0.hasPrefix("poster-") && $0.hasSuffix(".png") }.sorted()
        if keeping == nil, let frames = try? fm.contentsOfDirectory(atPath: directory.appendingPathComponent("video").path), !frames.isEmpty {
            try? fm.removeItem(at: directory.appendingPathComponent("video"))
        }
        let keep = Set([keeping?.lastPathComponent].compactMap { $0} + (keeping == nil ? [] : posters.filter { $0 != keeping?.lastPathComponent }.suffix(1)))
        for n in posters where !keep.contains(n) { try? fm.removeItem(at: directory.appendingPathComponent(n)) }
    }
}

/// Runtime record of the picture on an instance's wall poster (`<run>/<id>.camera.json`), shared by the CLI and the
/// app. Valid only for the engine process that showed it (a restart shows the default room again).
public struct CameraShownState: Codable, Sendable, Hashable {
    public var enginePID: Int32
    public var image: String
    public var poster: String
    public var shownAt: Date

    public init(enginePID: Int32, image: String, poster: String, shownAt: Date) {
        self.enginePID = enginePID
        self.image = image
        self.poster = poster
        self.shownAt = shownAt
    }

    public static func url(_ paths: EmuuPaths, _ id: InstanceID) -> URL {
        paths.runDirectory.appendingPathComponent("\(id.rawValue).camera.json")
    }

    public static func load(_ paths: EmuuPaths, _ id: InstanceID, pid: Int32?) -> CameraShownState? {
        guard let pid, let data = try? Data(contentsOf: url(paths, id)) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let s = try? d.decode(CameraShownState.self, from: data), s.enginePID == pid else { return nil }
        return s
    }

    public func save(_ paths: EmuuPaths, _ id: InstanceID) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        try? e.encode(self).write(to: Self.url(paths, id), options: .atomic)
    }

    public static func remove(_ paths: EmuuPaths, _ id: InstanceID) { try? FileManager.default.removeItem(at: url(paths, id)) }
}

/// Opens the virtual scene of a running instance (console + gRPC endpoint from the engine's discovery file).
public enum VirtualSceneAccess {
    /// Checks that the running engine's back camera is the virtual scene; returns a controller and the engine pid.
    public static func open(paths: EmuuPaths, engine: EngineInstance, config: InstanceConfig) async throws -> (VirtualSceneCamera, Int32) {
        _ = await engine.refresh()
        guard let ports = await engine.consolePorts(), let pid = await engine.enginePID() else {
            throw EmuuError.engine("\(config.id) is not running")
        }
        let launched = CameraLaunchPlan.launchedCameras(avdDirectory: paths.avdDirectory(for: config.id))
        guard launched?.back == "virtualscene" else {
            throw EmuuError.engine("the running back camera is \(launched?.back ?? "unknown"), not the virtual scene")
        }
        let dir = VirtualSceneCamera.workDirectory(preferred: paths.runDirectory.appendingPathComponent("camera"), instance: config.id)
        return (VirtualSceneCamera(console: ConsoleClient(port: ports.console), grpc: EmulatorDiscovery.endpoint(forPID: pid), workDirectory: dir), pid)
    }
}

/// Frames of a video file as square poster PNGs (AVFoundation; any format macOS plays).
public enum VideoPosterFrames {
    /// Extracts frames at `fps` (at most `maxFrames`) into `directory/video/`, each letterboxed to `side` px.
    public static func extract(_ video: URL, fps: Double, maxFrames: Int = 600, side: Int = 1024, into directory: URL) async throws -> [URL] {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw EmuuError.io(path: video.path, message: "not a playable video") }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: CMTimeScale(max(1, Int32(fps * 2))))
        let out = directory.appendingPathComponent("video", isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let count = min(maxFrames, max(1, Int(duration * fps)))
        var urls: [URL] = []
        for i in 0..<count {
            let t = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            let image = try await generator.image(at: t).image
            let url = out.appendingPathComponent(String(format: "frame-%05d.png", i))
            _ = try PosterImage.prepare(image, to: url, maxSide: side)
            urls.append(url)
        }
        return urls
    }
}
