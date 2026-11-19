import Foundation
import EmuuBase

/// The guest RAM the engine really runs with.
///
/// Engine 36.4.9 raises `hw.ramSize` to its own minimum for the image (measured: a 1536 MB config runs with
/// 2048 MB on android-36.1) and records the value it used in `<avd>/hardware-qemu.ini`, which it writes at
/// launch. So the value is only known once the engine has started at least once with the current config;
/// callers that size things from it (the governor's footprint budget) must read it after boot.
public enum EngineEffectiveRAM {
    public static func megabytes(for config: InstanceConfig, paths: EmuuPaths) -> Int {
        let ini = paths.avdDirectory(for: config.id).appendingPathComponent("hardware-qemu.ini")
        guard let file = try? IniFile(contentsOf: ini), let value = file["hw.ramSize"],
              let mb = Int(value.trimmingCharacters(in: .whitespaces)) else {
            return config.ramMB
        }
        return max(config.ramMB, mb)
    }
}
