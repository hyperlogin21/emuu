import Foundation
import Testing
import EmuuBase
import EmuuEngine

@Suite struct EffectiveRAMTests {
    @Test func followsTheEngineRecordedRAMOnceItExists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("emuu-effram-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = EmuuPaths(root: root)
        let config = InstancePreset.lite.makeConfig(id: InstanceID(rawValue: "lite")!)
        // Before the first launch there is no hardware-qemu.ini: the configured size is all we know.
        #expect(EngineEffectiveRAM.megabytes(for: config, paths: paths) == 1536)
        let dir = paths.avdDirectory(for: config.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Engine 36.4.9 raised 1536 to 2048 on android-36.1 (format as written by the engine).
        try "hw.cpu.ncore = 2\nhw.ramSize = 2048\n".write(to: dir.appendingPathComponent("hardware-qemu.ini"), atomically: true, encoding: .utf8)
        #expect(EngineEffectiveRAM.megabytes(for: config, paths: paths) == 2048)
        // A stale, smaller value never lowers the configured size.
        try "hw.ramSize = 1024\n".write(to: dir.appendingPathComponent("hardware-qemu.ini"), atomically: true, encoding: .utf8)
        #expect(EngineEffectiveRAM.megabytes(for: config, paths: paths) == 1536)
    }
}
