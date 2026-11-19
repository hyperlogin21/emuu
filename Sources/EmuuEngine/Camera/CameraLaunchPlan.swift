import AVFoundation
import Foundation
import EmuuBase

/// A camera on the Mac, as the engine numbers it (`webcamN`) plus, when AVFoundation lists it, its name.
public struct HostCamera: Codable, Sendable, Hashable {
    /// The engine's name: `webcam0`, `webcam1`, … (`emulator -webcam-list` order).
    public var engineName: String
    /// AVFoundation unique ID (the engine's "device"), stable across launches and reboots.
    public var uniqueID: String
    /// Display name ("MacBook Pro Camera"), nil when AVFoundation did not report this device.
    public var name: String?
    /// Pixel format the engine reads from it.
    public var pixelFormat: String?

    public init(engineName: String, uniqueID: String, name: String? = nil, pixelFormat: String? = nil) {
        self.engineName = engineName
        self.uniqueID = uniqueID
        self.name = name
        self.pixelFormat = pixelFormat
    }

    /// True when `id` (an engine name, unique ID or name, case-insensitive) names this camera.
    public func matches(_ id: String) -> Bool {
        let s = id.lowercased()
        return engineName.lowercased() == s || uniqueID.lowercased() == s || name?.lowercased() == s
    }
}

/// Host cameras: `emulator -webcam-list` (what the engine can open) joined with AVFoundation's device names.
/// Listing opens no camera and needs no camera permission.
public enum HostCameraList {
    /// Parses `emulator -webcam-list` (36.4.9):
    /// ` Camera 'webcam0' is connected to device '6C70…0001' on channel 0 using pixel format 'YV12'`.
    public static func parse(_ text: String) -> [HostCamera] {
        var out: [HostCamera] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let quoted = line.split(separator: "'", omittingEmptySubsequences: false)
            guard line.contains("is connected to device"), quoted.count >= 5 else { continue }
            let name = String(quoted[1]), device = String(quoted[3])
            guard CameraSource.isEngineWebcamName(name), !device.isEmpty else { continue }
            let format = quoted.count >= 7 ? String(quoted[5]) : nil
            out.append(HostCamera(engineName: name, uniqueID: device, pixelFormat: format))
        }
        return out
    }

    /// AVFoundation's video devices (unique ID → localized name). No permission is needed to list them.
    public static func avFoundationNames() -> [String: String] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external]
        if #available(macOS 14.0, *) { types.append(.continuityCamera) }
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
        var names: [String: String] = [:]
        for d in session.devices { names[d.uniqueID] = d.localizedName }
        return names
    }

    /// Runs `emulator -webcam-list` (about 0.1 s) and adds AVFoundation names.
    public static func query(sdk: AndroidSDK, runner: any ProcessRunner = SystemProcessRunner()) async throws -> [HostCamera] {
        let r = try await runner.run(ProcessRequest(executable: sdk.emulator, arguments: ["-webcam-list"], timeout: .seconds(20)))
        let text = String(decoding: r.stdout + r.stderr, as: UTF8.self)
        let names = avFoundationNames()
        return parse(text).map { var c = $0; c.name = names[c.uniqueID]; return c }
    }

    /// The engine value for `source` (`none`, `emulated`, `virtualscene`, `webcamN`), or nil when a Mac camera is
    /// asked for that is not connected now. `hostCameras` is only consulted for a webcam named by ID or name.
    public static func engineValue(_ source: CameraSource, hostCameras: [HostCamera]?) -> String? {
        switch source {
        case .none: return "none"
        case .emulated: return "emulated"
        case .virtualScene: return "virtualscene"
        case .webcam(let id):
            if CameraSource.isEngineWebcamName(id) {
                guard let cams = hostCameras else { return id }
                return cams.contains { $0.engineName == id } ? id : nil
            }
            return hostCameras?.first { $0.matches(id) }?.engineName
        }
    }
}

/// Decides the camera flags of one launch. The guest lists its cameras when it boots, and the engine refuses a
/// quick-boot snapshot whose `hardware.ini` has other `hw.camera.*` values ("The emulator hardware cannot load
/// snapshot", then a cold boot; measured on 36.4.9). So:
/// * no snapshot, or a cold boot anyway, or the snapshot has the same cameras → the requested cameras;
/// * the snapshot has other cameras, ordinary instance → the requested cameras and an explicit cold boot (data is
///   kept; the next snapshot then matches);
/// * the snapshot has other cameras, farm clone → keep the snapshot's (golden's) cameras: a clone never saves, so a
///   cold boot would repeat on every start and the pool would not get its ready-in-2-s resume. Re-seal the golden.
public struct CameraLaunchPlan: Sendable, Hashable {
    public var back: String
    public var front: String
    public var coldBoot: Bool
    public var notes: [String]

    public static func make(desired: CameraConfig, hostCameras: [HostCamera]?, snapshot: (back: String, front: String)?,
                            coldBoot: Bool, isClone: Bool) -> CameraLaunchPlan {
        var notes: [String] = []
        func resolve(_ s: CameraSource, _ facing: CameraFacing) -> String {
            if let v = HostCameraList.engineValue(s, hostCameras: hostCameras) { return v }
            notes.append("\(facing.rawValue) camera: Mac camera '\(s.argument)' is not connected; starting without it")
            return "none"
        }
        var back = resolve(desired.back, .back)
        var front = resolve(desired.front, .front)
        if back != "none", back == front {
            notes.append("front camera: \(front) is already the back camera; starting without a front camera")
            front = "none"
        }
        guard let snap = snapshot, !coldBoot else { return CameraLaunchPlan(back: back, front: front, coldBoot: coldBoot, notes: notes) }
        let snapBack = normalized(snap.back), snapFront = normalized(snap.front)
        guard snapBack != back || snapFront != front else {
            return CameraLaunchPlan(back: back, front: front, coldBoot: false, notes: notes)
        }
        let what = "cameras back=\(back) front=\(front) requested, the quick-boot snapshot has back=\(snapBack) front=\(snapFront)"
        if isClone {
            notes.append("\(what); keeping the golden's cameras (re-seal the golden to change them)")
            back = snapBack
            front = snapFront
            return CameraLaunchPlan(back: back, front: front, coldBoot: false, notes: notes)
        }
        notes.append("\(what): cold boot")
        return CameraLaunchPlan(back: back, front: front, coldBoot: true, notes: notes)
    }

    /// Missing or empty values mean `none` (the engine's default).
    static func normalized(_ v: String) -> String {
        let t = v.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "none" : t
    }

    /// `hw.camera.back` / `hw.camera.front` of the quick-boot snapshot (`snapshots/default_boot/hardware.ini`),
    /// nil when there is no snapshot.
    public static func snapshotCameras(avdDirectory: URL) -> (back: String, front: String)? {
        hardwareCameras(avdDirectory.appendingPathComponent("snapshots/default_boot/hardware.ini"))
    }

    /// `hw.camera.*` of the running (or last) launch (`hardware-qemu.ini`, written by the engine at each launch).
    public static func launchedCameras(avdDirectory: URL) -> (back: String, front: String)? {
        hardwareCameras(avdDirectory.appendingPathComponent("hardware-qemu.ini"))
    }

    static func hardwareCameras(_ url: URL) -> (back: String, front: String)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parseHardwareCameras(text)
    }

    /// Pure: `hw.camera.back` / `hw.camera.front` from an engine hardware ini (missing = `none`).
    public static func parseHardwareCameras(_ text: String) -> (back: String, front: String) {
        var back = "none", front = "none"
        for line in text.split(whereSeparator: \.isNewline) {
            let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            if kv[0] == "hw.camera.back" { back = normalized(kv[1]) }
            if kv[0] == "hw.camera.front" { front = normalized(kv[1]) }
        }
        return (back, front)
    }
}
