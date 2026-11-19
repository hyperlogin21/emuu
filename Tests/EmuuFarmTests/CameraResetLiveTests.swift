import Foundation
import Testing
import EmuuBase
import EmuuEngine
@testable import EmuuFarm

/// Live check of the farm reset's camera part against a running instance whose back camera is the virtual scene:
/// show a picture, reset like a pool release (snapshot load + scene reset), then expect the default poster state
/// and the start pose. Opt-in: `EMUU_CAMERA_LIVE_INSTANCE=<name> swift test --filter CameraResetLive` (uses
/// `$EMUU_HOME`; the instance must have a quick-boot snapshot).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["EMUU_CAMERA_LIVE_INSTANCE"] != nil))
struct CameraResetLiveTests {
    @Test func resetRestoresTheSceneAndPose() async throws {
        let name = ProcessInfo.processInfo.environment["EMUU_CAMERA_LIVE_INSTANCE"]!
        let id = try InstanceID(validating: name)
        let engines = try EngineEnvironment.live()
        let driver = LiveFarmDriver(engines: engines)
        let engine = try await engines.engine(for: id)
        _ = await engine.refresh()
        let config = try engines.store.load(id)
        let (scene, pid) = try await VirtualSceneAccess.open(paths: engines.paths, engine: engine, config: config)
        let image = engines.paths.runDirectory.appendingPathComponent("camera-live-test.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!.write(to: image)
        defer { try? FileManager.default.removeItem(at: image) }
        let shown = try await scene.show(image: image)
        CameraShownState(enginePID: pid, image: image.path, poster: shown.poster, shownAt: Date()).save(engines.paths, id)
        let aimed = try await scene.currentPose()
        #expect(abs(aimed.position[2] - VirtualSceneCamera.aimPose().position[2]) < 0.05)
        let t0 = ContinuousClock.now
        try await driver.reset(instance: name)
        print("reset with camera clear: \(ContinuousClock.now - t0)")
        let after = try await scene.currentPose()
        #expect(after.position.allSatisfy { abs($0) < 0.05 })
        #expect(CameraShownState.load(engines.paths, id, pid: pid) == nil)
        let dir = VirtualSceneCamera.workDirectory(preferred: engines.paths.runDirectory.appendingPathComponent("camera"), instance: id)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("poster-") }.isEmpty)
    }
}
