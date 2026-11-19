import Foundation

/// What one emulated camera (back or front) shows the guest. See docs/engine-findings.md ("Camera").
///
/// Engine 36.4.9 also accepts `imagefile:<path>` and `videofile:<path>`, but with the android-36.1 image the guest
/// camera HAL hangs as soon as an app configures such a camera (no frame ever arrives and cameraserver stays
/// wedged until the guest reboots; measured 4 of 4), and `-camera-front virtualscene` is rejected. Emuu therefore
/// offers only the sources below; a chosen picture is shown through the virtual scene (`emuu camera show`).
public enum CameraSource: Hashable, Sendable, CustomStringConvertible {
    /// No camera: Android does not list it.
    case none
    /// The guest's software ("fake") camera: a moving test scene. No host cost while closed, no permission.
    case emulated
    /// Back camera only: a rendered 3D room whose "wall" poster can show any picture (`emuu camera show`).
    case virtualScene
    /// A Mac camera. `id` is the engine's `webcamN`, or a host device's unique ID or name, resolved to `webcamN`
    /// at each launch (`HostCameraList`). Needs camera permission for the process that starts the engine.
    case webcam(String)

    /// The value stored in instance records and accepted on the command line.
    public var argument: String {
        switch self {
        case .none: return "none"
        case .emulated: return "emulated"
        case .virtualScene: return "virtualscene"
        case .webcam(let id): return Self.isEngineWebcamName(id) ? id : "webcam:\(id)"
        }
    }

    public var description: String { argument }

    /// Short user-facing label.
    public var title: String {
        switch self {
        case .none: return "None"
        case .emulated: return "Emulated"
        case .virtualScene: return "Virtual scene"
        case .webcam(let id): return Self.isEngineWebcamName(id) ? "Mac camera \(id.dropFirst("webcam".count))" : "Mac camera"
        }
    }

    public var isWebcam: Bool { if case .webcam = self { return true } else { return false } }

    /// `webcam0`, `webcam1`, … (the engine's names for host cameras, in `-webcam-list` order).
    public static func isEngineWebcamName(_ s: String) -> Bool {
        s.hasPrefix("webcam") && s.count > 6 && s.dropFirst(6).allSatisfy(\.isNumber)
    }

    /// Parses `none|off`, `emulated|fake`, `virtualscene|scene|virtual-scene`, `webcam<N>`, `webcam:<id or name>`,
    /// `host:<id or name>`. Returns nil for anything else (including `imagefile:`/`videofile:`, see the type comment).
    public init?(argument raw: String) {
        let s = raw.trimmingCharacters(in: .whitespaces)
        switch s.lowercased() {
        case "none", "off", "no", "": self = .none
        case "emulated", "fake", "software": self = .emulated
        case "virtualscene", "virtual-scene", "virtual_scene", "scene", "virtual": self = .virtualScene
        default:
            if Self.isEngineWebcamName(s.lowercased()) { self = .webcam(s.lowercased()); return }
            for prefix in ["webcam:", "host:", "mac:"] where s.lowercased().hasPrefix(prefix) {
                let id = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                guard !id.isEmpty else { return nil }
                self = .webcam(Self.isEngineWebcamName(id.lowercased()) ? id.lowercased() : id)
                return
            }
            return nil
        }
    }
}

extension CameraSource: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let v = CameraSource(argument: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid camera source '\(raw)'"))
        }
        self = v
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(argument)
    }
}

/// Which camera an option applies to.
public enum CameraFacing: String, Codable, Sendable, Hashable, CaseIterable {
    case back, front
}

/// Per-instance camera hardware. The guest lists its cameras when it boots, and a quick-boot snapshot records them,
/// so a change applies at the next start (one cold boot; see `CameraLaunchPlan`).
public struct CameraConfig: Codable, Sendable, Hashable {
    public var back: CameraSource
    public var front: CameraSource

    public init(back: CameraSource, front: CameraSource) {
        self.back = back
        self.front = front
    }

    /// Instances created before camera support (record without `camera`): no cameras, as before.
    public static let off = CameraConfig(back: .none, front: .none)

    /// New instances: the back camera is the virtual scene (so a test can show it a picture with `emuu camera show`)
    /// and the front camera the guest's emulated camera. Neither needs macOS camera permission, and neither costs
    /// anything measurable while no app has the camera open (docs/engine-findings.md, "Camera").
    public static let newInstanceDefault = CameraConfig(back: .virtualScene, front: .emulated)

    public func source(_ facing: CameraFacing) -> CameraSource { facing == .back ? back : front }

    public mutating func set(_ facing: CameraFacing, _ source: CameraSource) {
        if facing == .back { back = source } else { front = source }
    }

    /// Problems with this combination (empty when valid). The engine rejects `-camera-front virtualscene`, and one
    /// host camera cannot back both cameras ("Camera 'webcam0' is already used").
    public var problems: [String] {
        var out: [String] = []
        if front == .virtualScene { out.append("the front camera cannot be the virtual scene (the engine supports it for the back camera only)") }
        if case .webcam(let a) = back, case .webcam(let b) = front, a == b {
            out.append("the same Mac camera (\(a)) cannot be both the back and the front camera")
        }
        return out
    }

    public func validate() throws {
        let p = problems
        if !p.isEmpty { throw EmuuError.invalidConfiguration(p.joined(separator: "; ")) }
    }

    /// `EMUU_CAMERA_BACK` / `EMUU_CAMERA_FRONT` (same values as `emuu camera set`) override every instance's
    /// setting for quick tests.
    public static let backEnvironmentKey = "EMUU_CAMERA_BACK"
    public static let frontEnvironmentKey = "EMUU_CAMERA_FRONT"
}

extension InstanceConfig {
    /// `camera` with its default applied (nil = `.off`).
    public var cameraConfig: CameraConfig { camera ?? .off }

    /// The cameras this instance runs with: the stored setting, overridden per camera by `EMUU_CAMERA_BACK` /
    /// `EMUU_CAMERA_FRONT` when set to a valid value.
    public func effectiveCamera(environment: [String: String] = ProcessInfo.processInfo.environment) -> CameraConfig {
        var c = cameraConfig
        if let raw = environment[CameraConfig.backEnvironmentKey], !raw.isEmpty, let s = CameraSource(argument: raw) { c.back = s }
        if let raw = environment[CameraConfig.frontEnvironmentKey], !raw.isEmpty, let s = CameraSource(argument: raw) { c.front = s }
        return c
    }
}
