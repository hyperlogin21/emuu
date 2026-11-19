import AVFoundation
import AppKit
import EmuuBase

/// macOS camera permission for Mac cameras used as Android cameras.
///
/// The engine opens the Mac camera itself (AVFoundation in `qemu-system-aarch64-headless`), but it is a child process
/// of the app, and macOS attributes a child's camera use to the app that launched it ("responsible process"): the
/// prompt names Emuu and needs `NSCameraUsageDescription` in Emuu's Info.plist (scripts/make-app.sh). The app asks
/// before it starts an engine with a Mac camera, so the prompt comes from the app, while the user is looking at it.
/// (From a terminal, `emuu start` is attributed to the terminal app, which macOS asks about instead.)
enum CameraAccess {
    struct Decision: Equatable {
        /// Cameras to launch with instead of the stored ones (nil = as stored).
        var override: CameraConfig?
        var message: String?
    }

    /// What to do for `cameras` given the app's permission (pure; `decide(for:)` adds the system calls).
    static func decide(for cameras: CameraConfig, status: AVAuthorizationStatus) -> Decision {
        guard cameras.back.isWebcam || cameras.front.isWebcam else { return Decision() }
        switch status {
        case .authorized:
            return Decision()
        case .notDetermined:
            return Decision()   // `decide(for:)` asks first
        default:
            var fallback = cameras
            if fallback.back.isWebcam { fallback.back = .emulated }
            if fallback.front.isWebcam { fallback.front = .emulated }
            return Decision(override: fallback,
                            message: "Camera access for Emuu is off, so the Mac camera is replaced by the emulated camera. Allow Emuu in System Settings › Privacy & Security › Camera, then restart the device.")
        }
    }

    /// Asks for access when it was never asked (shows the macOS prompt), then decides.
    @MainActor
    static func decide(for cameras: CameraConfig) async -> Decision {
        guard cameras.back.isWebcam || cameras.front.isWebcam else { return Decision() }
        var status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            NSApp.activate()
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            status = granted ? .authorized : .denied
        }
        return decide(for: cameras, status: status)
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }
}
