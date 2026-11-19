import CoreGraphics
import Foundation
import ImageIO
import Testing
import EmuuBase
@testable import EmuuEngine

@Suite struct CameraModelTests {
    @Test func parsesSources() {
        #expect(CameraSource(argument: "none") == CameraSource.none)
        #expect(CameraSource(argument: "OFF") == CameraSource.none)
        #expect(CameraSource(argument: "emulated") == .emulated)
        #expect(CameraSource(argument: "virtualscene") == .virtualScene)
        #expect(CameraSource(argument: "virtual-scene") == .virtualScene)
        #expect(CameraSource(argument: "webcam0") == .webcam("webcam0"))
        #expect(CameraSource(argument: "WebCam12") == .webcam("webcam12"))
        #expect(CameraSource(argument: "webcam:MacBook Pro Camera") == .webcam("MacBook Pro Camera"))
        #expect(CameraSource(argument: "host:webcam1") == .webcam("webcam1"))
        #expect(CameraSource(argument: "webcam:") == nil)
        #expect(CameraSource(argument: "webcam") == nil)
        #expect(CameraSource(argument: "imagefile:/tmp/a.png") == nil)   // hangs the guest HAL on 36.4.9
        #expect(CameraSource(argument: "videofile:/tmp/a.mp4") == nil)
        #expect(CameraSource(argument: "bogus") == nil)
    }

    @Test func roundTripsThroughJSON() throws {
        let c = CameraConfig(back: .webcam("6C707041-05AC-0011-0002-000000000001"), front: .webcam("webcam1"))
        let data = try JSONEncoder().encode(c)
        #expect(String(decoding: data, as: UTF8.self).contains("webcam:6C707041"))
        #expect(try JSONDecoder().decode(CameraConfig.self, from: data) == c)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(CameraConfig.self, from: Data(#"{"back":"imagefile:x","front":"none"}"#.utf8)) }
    }

    @Test func legacyRecordsHaveNoCamerasNewOnesTheDefault() throws {
        var legacy = InstanceConfig(id: InstanceID(rawValue: "old")!)
        legacy.camera = nil
        let data = try JSONEncoder().encode(legacy)
        #expect(!String(decoding: data, as: UTF8.self).contains("camera"))
        let decoded = try JSONDecoder().decode(InstanceConfig.self, from: data)
        #expect(decoded.camera == nil)
        #expect(decoded.cameraConfig == .off)
        let fresh = InstanceConfig(id: InstanceID(rawValue: "new")!)
        #expect(fresh.cameraConfig == CameraConfig(back: .virtualScene, front: .emulated))
        #expect(InstancePreset.standard.makeConfig(id: InstanceID(rawValue: "p")!).cameraConfig == .newInstanceDefault)
    }

    @Test func validation() {
        #expect(CameraConfig(back: .virtualScene, front: .emulated).problems.isEmpty)
        #expect(!CameraConfig(back: .none, front: .virtualScene).problems.isEmpty)
        #expect(!CameraConfig(back: .webcam("webcam0"), front: .webcam("webcam0")).problems.isEmpty)
        var bad = InstanceConfig(id: InstanceID(rawValue: "x")!)
        bad.camera = CameraConfig(back: .none, front: .virtualScene)
        #expect(throws: (any Error).self) { try bad.validate() }
    }

    @Test func environmentOverride() {
        let c = InstanceConfig(id: InstanceID(rawValue: "x")!)
        #expect(c.effectiveCamera(environment: [:]) == .newInstanceDefault)
        let o = c.effectiveCamera(environment: ["EMUU_CAMERA_BACK": "none", "EMUU_CAMERA_FRONT": "webcam0"])
        #expect(o == CameraConfig(back: .none, front: .webcam("webcam0")))
        #expect(c.effectiveCamera(environment: ["EMUU_CAMERA_BACK": "nonsense"]).back == .virtualScene)
    }
}

@Suite struct HostCameraTests {
    static let sample = """
    List of web cameras connected to the computer:
     Camera 'webcam0' is connected to device '6C707041-05AC-0011-0002-000000000001' on channel 0 using pixel format 'YV12'
     Camera 'webcam1' is connected to device '0x1420000046d0825' on channel 1 using pixel format 'BGR4'

    """

    @Test func parsesWebcamList() {
        let cams = HostCameraList.parse(Self.sample)
        #expect(cams.count == 2)
        #expect(cams[0] == HostCamera(engineName: "webcam0", uniqueID: "6C707041-05AC-0011-0002-000000000001", pixelFormat: "YV12"))
        #expect(cams[1].engineName == "webcam1" && cams[1].pixelFormat == "BGR4")
        #expect(HostCameraList.parse("No web cameras are connected to the host.").isEmpty)
    }

    @Test func resolvesSourcesToEngineValues() {
        var cams = HostCameraList.parse(Self.sample)
        cams[0].name = "MacBook Pro Camera"
        #expect(HostCameraList.engineValue(.none, hostCameras: cams) == "none")
        #expect(HostCameraList.engineValue(.virtualScene, hostCameras: nil) == "virtualscene")
        #expect(HostCameraList.engineValue(.webcam("webcam1"), hostCameras: nil) == "webcam1")
        #expect(HostCameraList.engineValue(.webcam("webcam1"), hostCameras: cams) == "webcam1")
        #expect(HostCameraList.engineValue(.webcam("webcam7"), hostCameras: cams) == nil)
        #expect(HostCameraList.engineValue(.webcam("macbook pro camera"), hostCameras: cams) == "webcam0")
        #expect(HostCameraList.engineValue(.webcam("0x1420000046d0825"), hostCameras: cams) == "webcam1")
        #expect(HostCameraList.engineValue(.webcam("Studio Display Camera"), hostCameras: cams) == nil)
    }
}

@Suite struct CameraLaunchPlanTests {
    let vs = CameraConfig(back: .virtualScene, front: .emulated)

    @Test func noSnapshotOrColdBootUsesTheRequest() {
        let p = CameraLaunchPlan.make(desired: vs, hostCameras: nil, snapshot: nil, coldBoot: false, isClone: false)
        #expect(p.back == "virtualscene" && p.front == "emulated" && !p.coldBoot && p.notes.isEmpty)
        let c = CameraLaunchPlan.make(desired: vs, hostCameras: nil, snapshot: ("none", "none"), coldBoot: true, isClone: false)
        #expect(c.back == "virtualscene" && c.coldBoot)
    }

    @Test func matchingSnapshotLoads() {
        let p = CameraLaunchPlan.make(desired: vs, hostCameras: nil, snapshot: ("virtualscene", "emulated"), coldBoot: false, isClone: false)
        #expect(!p.coldBoot && p.notes.isEmpty)
        let off = CameraLaunchPlan.make(desired: .off, hostCameras: nil, snapshot: ("", " none "), coldBoot: false, isClone: false)
        #expect(!off.coldBoot && off.back == "none")
    }

    @Test func mismatchColdBootsOnceOrKeepsTheGoldensCameras() {
        let p = CameraLaunchPlan.make(desired: vs, hostCameras: nil, snapshot: ("none", "none"), coldBoot: false, isClone: false)
        #expect(p.coldBoot && p.back == "virtualscene" && p.notes.count == 1)
        let clone = CameraLaunchPlan.make(desired: vs, hostCameras: nil, snapshot: ("none", "emulated"), coldBoot: false, isClone: true)
        #expect(!clone.coldBoot && clone.back == "none" && clone.front == "emulated")
        #expect(clone.notes.first?.contains("re-seal") == true)
    }

    @Test func missingMacCameraStartsWithout() {
        let want = CameraConfig(back: .webcam("Studio Display Camera"), front: .emulated)
        let p = CameraLaunchPlan.make(desired: want, hostCameras: [], snapshot: nil, coldBoot: false, isClone: false)
        #expect(p.back == "none" && p.front == "emulated" && p.notes.count == 1)
        let both = CameraLaunchPlan.make(desired: CameraConfig(back: .webcam("webcam0"), front: .webcam("webcam0")),
                                         hostCameras: nil, snapshot: nil, coldBoot: false, isClone: false)
        #expect(both.back == "webcam0" && both.front == "none")
    }

    @Test func readsHardwareIni() {
        let text = """
        hw.camera.back = virtualscene
        hw.camera.back.orientation = 90
        hw.camera.front = webcam0
        hw.camera.front.orientation = 90
        """
        let c = CameraLaunchPlan.parseHardwareCameras(text)
        #expect(c.back == "virtualscene" && c.front == "webcam0")
        let empty = CameraLaunchPlan.parseHardwareCameras("hw.gps = yes\n")
        #expect(empty.back == "none" && empty.front == "none")
    }

    @Test func snapshotCamerasFromAVDDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("emuu-cam-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(CameraLaunchPlan.snapshotCameras(avdDirectory: dir) == nil)
        let snap = dir.appendingPathComponent("snapshots/default_boot")
        try FileManager.default.createDirectory(at: snap, withIntermediateDirectories: true)
        try Data("hw.camera.back = virtualscene\nhw.camera.front = none\n".utf8).write(to: snap.appendingPathComponent("hardware.ini"))
        let c = try #require(CameraLaunchPlan.snapshotCameras(avdDirectory: dir))
        #expect(c.back == "virtualscene" && c.front == "none")
    }
}

@Suite struct CameraCommandLineTests {
    @Test func cameraFlags() throws {
        let ports = try InstancePorts(console: 5578)
        let fresh = InstanceConfig(id: InstanceID(rawValue: "cam")!)
        let args = EngineCommandLine.arguments(for: fresh, ports: ports, options: EngineLaunchOptions(grpc: false))
        let i = try #require(args.firstIndex(of: "-camera-back"))
        #expect(args[i + 1] == "virtualscene")
        let j = try #require(args.firstIndex(of: "-camera-front"))
        #expect(args[j + 1] == "emulated")
        #expect(args.firstIndex(of: "-qemu") == nil || args.firstIndex(of: "-qemu")! > j)

        var legacy = fresh
        legacy.camera = nil
        let plain = EngineCommandLine.arguments(for: legacy, ports: ports, options: EngineLaunchOptions(grpc: false))
        #expect(!plain.contains("-camera-back") && !plain.contains("-camera-front"))

        let planned = EngineCommandLine.arguments(for: fresh, ports: ports, options: EngineLaunchOptions(grpc: false),
                                                  cameras: ("none", "webcam1"))
        #expect(!planned.contains("-camera-back"))
        #expect(planned.contains("webcam1"))

        let overridden = EngineCommandLine.arguments(for: fresh, ports: ports,
                                                     options: EngineLaunchOptions(grpc: false, cameraOverride: CameraConfig(back: .emulated, front: .none)))
        #expect(overridden.contains("emulated") && !overridden.contains("virtualscene") && !overridden.contains("-camera-front"))
    }
}

@Suite struct VirtualSceneTests {
    @Test func aimPoseFacesThePoster() {
        let p = VirtualSceneCamera.aimPose(distance: 2, lateral: 0)
        #expect(p.rotation == [0, -150, 0])
        // Two metres along the poster's inward normal (−0.5, 0, −0.866) from its centre, lifted to the picture region.
        #expect(abs(p.position[0] - (-0.807 - 1.0)) < 0.001)
        #expect(abs(p.position[1] - (0.320 + 0.25)) < 0.001)
        #expect(abs(p.position[2] - (5.316 - 1.732)) < 0.001)
        // Sideways along the device's x axis (cos −150°, 0, −sin −150°) = (−0.866, 0, 0.5).
        let s = VirtualSceneCamera.aimPose(distance: 2, lateral: 1)
        #expect(abs(s.position[0] - p.position[0] + 0.866) < 0.001 && abs(s.position[2] - p.position[2] - 0.5) < 0.001)
        #expect(VirtualSceneCamera.aimPose().position[1] > 0.5)
    }

    @Test func posterLayoutPutsThePictureInTheTopRegion() {
        // 1600×1000 picture → 2133 px canvas capped at 2048; region 1536 px at the top centre.
        let wide = PosterImage.layout(width: 1600, height: 1000)
        #expect(wide.side == 2048)
        #expect(abs(wide.rect.width - 1536) < 0.01 && abs(wide.rect.height - 960) < 0.01)
        #expect(abs(wide.rect.minX - 256) < 0.01)
        #expect(abs(wide.rect.minY - (512 + 288)) < 0.01)   // region starts at y = 512 (CG origin bottom left)
        let small = PosterImage.layout(width: 300, height: 300)
        #expect(small.side == 400 && small.rect == CGRect(x: 50, y: 100, width: 300, height: 300))
        let tall = PosterImage.layout(width: 500, height: 1000, fraction: 1)
        #expect(tall.side == 1000 && tall.rect.minX == 250 && tall.rect.minY == 0)
    }

    @Test func preparesSquarePNGAndPrunes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("emuu-poster-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("in.png")
        let ctx = CGContext(data: nil, width: 300, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 100))
        let dest = CGImageDestinationCreateWithURL(src as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(dest))
        let out = dir.appendingPathComponent("posters")
        let a = try PosterImage.prepare(src, in: out)
        #expect(a.width == 300 && a.height == 100)
        let img = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(a.url as CFURL, nil)!, 0, nil)!
        #expect(img.width == 400 && img.height == 400)
        #expect(!a.url.path.contains(" "))
        Thread.sleep(forTimeInterval: 0.01)
        let b = try PosterImage.prepare(src, in: out)
        Thread.sleep(forTimeInterval: 0.01)
        let c = try PosterImage.prepare(src, in: out)
        PosterImage.prune(out, keeping: c.url)
        let left = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
        #expect(left == [b.url.lastPathComponent, c.url.lastPathComponent].sorted())
        PosterImage.prune(out, keeping: nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
        #expect(throws: (any Error).self) { try PosterImage.prepare(dir.appendingPathComponent("missing.png"), in: out) }
    }

    @Test func workDirectoryAvoidsSpaces() {
        let id = InstanceID(rawValue: "phone")!
        let ok = VirtualSceneCamera.workDirectory(preferred: URL(fileURLWithPath: "/Users/a/.emuu/run/camera"), instance: id)
        #expect(ok.path == "/Users/a/.emuu/run/camera/phone")
        let spaced = VirtualSceneCamera.workDirectory(preferred: URL(fileURLWithPath: "/Users/a b/.emuu/run/camera"), instance: id)
        #expect(!spaced.path.contains(" ") || spaced.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(spaced.lastPathComponent == "phone")
    }
}
