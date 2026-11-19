import AVFoundation
import Testing
import EmuuBase
@testable import EmuuApp

@Suite struct CameraAccessTests {
    @Test func onlyMacCamerasNeedPermission() {
        let plain = CameraConfig.newInstanceDefault
        #expect(CameraAccess.decide(for: plain, status: .denied) == CameraAccess.Decision())
        let mac = CameraConfig(back: .virtualScene, front: .webcam("webcam0"))
        #expect(CameraAccess.decide(for: mac, status: .authorized) == CameraAccess.Decision())
        let denied = CameraAccess.decide(for: mac, status: .denied)
        #expect(denied.override == CameraConfig(back: .virtualScene, front: .emulated))
        #expect(denied.message?.contains("System Settings") == true)
        let restricted = CameraAccess.decide(for: CameraConfig(back: .webcam("x"), front: .none), status: .restricted)
        #expect(restricted.override == CameraConfig(back: .emulated, front: .none))
    }
}
