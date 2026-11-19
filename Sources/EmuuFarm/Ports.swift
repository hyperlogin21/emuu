import Foundation
import EmuuBase

/// Console-port planning for farm devices.
///
/// adb discovers emulators by scanning adb ports 5555…5585, i.e. console ports 5554…5584 (even): 16 devices.
/// Engines on higher ports boot but never appear in `adb devices` (measured on emulator-5600 earlier), so a farm
/// is capped at 16 devices per host. Every port is checked for a live listener (other emulators, including
/// ones Emuu did not start) and against ports already planned for other farm devices.
public enum FarmPorts {
    public static let consolePorts: [Int] = Array(stride(from: 5554, through: 5584, by: 2))

    /// The first `count` free console ports, skipping `reserved` and any port whose console or adb port is bound.
    /// Returns fewer than `count` when the range is exhausted.
    public static func allocate(count: Int, reserved: Set<Int>, isFree: (Int) -> Bool) -> [Int] {
        var out: [Int] = []
        for p in consolePorts where out.count < count {
            if reserved.contains(p) { continue }
            if isFree(p) && isFree(p + 1) { out.append(p) }
        }
        return out
    }
}
