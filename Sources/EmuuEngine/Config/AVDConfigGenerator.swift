import Foundation
import EmuuBase

/// Starting points for new instances. Values were chosen for a 16 GB M-series host and checked against
/// the engine (see docs/engine-findings.md).
public enum InstancePreset: String, Sendable, Hashable, CaseIterable, Codable {
    /// 2048 MB guest, 4 vCPUs. The default.
    case standard
    /// 1536 MB guest, 2 vCPUs. Not boot-tested yet on android-36.1 (only `standard` was measured); expect
    /// more background-app kills from the guest's low-memory killer.
    case lite
    /// 3072 MB guest, 4 vCPUs, performance governor profile: for heavier games.
    case gaming

    public var ramMB: Int {
        switch self {
        case .standard: return 2048
        case .lite: return 1536
        case .gaming: return 3072
        }
    }

    public var cores: Int {
        switch self {
        case .standard, .gaming: return 4
        case .lite: return 2
        }
    }

    public var memoryProfile: MemoryProfile {
        switch self {
        case .standard: return .balanced
        case .lite: return .frugal
        case .gaming: return .performance
        }
    }

    /// Requested Dalvik heap. Note: engine 36.4.9 raises `vm.heapSize` to its own minimum for the
    /// image/density (512 MB for android-36.1 at 320 dpi), visible in `hardware-qemu.ini`. The heap is a
    /// per-app ceiling, not reserved memory, so this costs nothing until an app uses it.
    public var vmHeapMB: Int {
        switch self {
        case .standard: return 256
        case .lite: return 192
        case .gaming: return 512
        }
    }

    /// userdata size. The engine keeps userdata as a qcow2 overlay that grows on demand, so this is a ceiling.
    public var dataPartitionMB: Int {
        switch self {
        case .standard: return 6144
        case .lite: return 4096
        case .gaming: return 16384
        }
    }

    /// Builds an `InstanceConfig` for this preset.
    public func makeConfig(id: InstanceID, displayName: String? = nil, systemImage: SystemImageRef = .playStoreDefault,
                           ports: InstancePorts? = nil, gpu: GPUMode = .host, audioOutput: Bool = true,
                           display: DisplaySpec = .lightweightPhone, createdAt: Date = Date()) -> InstanceConfig {
        InstanceConfig(id: id, displayName: displayName, systemImage: systemImage, memoryProfile: memoryProfile,
                       ramMB: ramMB, cores: cores, vmHeapMB: vmHeapMB, display: display,
                       dataPartitionMB: dataPartitionMB, ports: ports, gpu: gpu, audioOutput: audioOutput,
                       createdAt: createdAt)
    }
}

/// Turns an `InstanceConfig` into the files the engine reads. Only keys listed in the engine's
/// `emulator/lib/hardware-properties.ini` (or the AVD metadata keys avdmanager writes) are emitted.
public enum AVDConfigGenerator {
    /// Sensors that no phone game or Play app here needs; each is a host-side emulation the engine keeps
    /// ticking. Accelerometer, gyroscope, magnetometer and orientation stay on (games and compasses use them).
    public static let disabledSensors = [
        "hw.sensors.light", "hw.sensors.pressure", "hw.sensors.humidity", "hw.sensors.proximity",
        "hw.sensors.temperature", "hw.sensors.rgbclight", "hw.sensors.heart_rate", "hw.sensors.wrist_tilt",
        "hw.sensors.heading", "hw.sensors.magnetic_field_uncalibrated", "hw.sensors.gyroscope_uncalibrated",
        "hw.accelerometer_uncalibrated",
    ]

    /// `avd/<id>.ini`. `path.rel` is omitted on purpose: it is relative to `~/.android`, which Emuu never uses;
    /// the engine resolves the AVD from the absolute `path` (verified with `emulator -list-avds`).
    public static func pointerIni(for config: InstanceConfig, avdDirectory: URL) -> IniFile {
        var ini = IniFile()
        ini["avd.ini.encoding"] = "UTF-8"
        ini["path"] = avdDirectory.standardizedFileURL.path
        ini["target"] = config.systemImage.apiDirectory
        return ini
    }

    /// `avd/<id>.avd/config.ini`, memory-tuned.
    public static func configIni(for config: InstanceConfig, tagDisplay: String? = nil) -> IniFile {
        let image = config.systemImage
        var ini = IniFile()
        func flag(_ b: Bool) -> String { b ? "yes" : "no" }

        ini["avd.ini.encoding"] = "UTF-8"
        ini["AvdId"] = config.id.rawValue
        ini["avd.ini.displayname"] = config.displayName
        ini["PlayStore.enabled"] = image.hasPlayStore ? "true" : "false"
        ini["abi.type"] = image.abi
        ini["hw.cpu.arch"] = cpuArch(for: image.abi)
        ini["hw.cpu.ncore"] = String(config.cores)
        ini["hw.ramSize"] = String(config.ramMB)
        ini["vm.heapSize"] = String(config.vmHeapMB)
        ini["disk.dataPartition.size"] = "\(config.dataPartitionMB)M"

        // Display: small panel is cheaper to render, copy to the host display and keep in host GPU memory.
        ini["hw.lcd.width"] = String(config.display.width)
        ini["hw.lcd.height"] = String(config.display.height)
        ini["hw.lcd.density"] = String(config.display.density)
        ini["hw.initialOrientation"] = "portrait"
        ini["showDeviceFrame"] = "no"
        ini["hw.gpu.enabled"] = "yes"
        ini["hw.gpu.mode"] = config.gpu.rawValue

        // Devices Emuu never uses.
        ini["hw.audioInput"] = "no"
        ini["hw.audioOutput"] = flag(config.audioOutput)
        ini["hw.camera.back"] = "none"
        ini["hw.camera.front"] = "none"
        ini["hw.sdCard"] = "no"          // saves the 512 MB sdcard.img and its virtio-blk device
        ini["hw.dPad"] = "no"
        ini["hw.trackBall"] = "no"
        ini["hw.mainKeys"] = "no"
        ini["hw.keyboard"] = "yes"       // host keyboard via the engine (gRPC key events); avoids the soft keyboard covering games
        ini["hw.gps"] = "yes"            // Play apps commonly require location; costs nothing when idle
        ini["hw.battery"] = "yes"
        ini["hw.accelerometer"] = "yes"
        ini["hw.gyroscope"] = "yes"
        ini["hw.sensors.magnetic_field"] = "yes"
        ini["hw.sensors.orientation"] = "yes"
        for key in disabledSensors { ini[key] = "no" }

        // System image.
        ini["image.sysdir.1"] = image.sdkRelativePath
        ini["tag.id"] = image.tag
        ini["tag.ids"] = image.tag
        let display = tagDisplay ?? defaultTagDisplay(image.tag)
        ini["tag.display"] = display
        ini["tag.displaynames"] = display
        ini["target"] = image.apiDirectory

        // Quick boot stays on so hibernate/resume is a snapshot load, not a cold boot.
        ini["fastboot.forceColdBoot"] = "no"
        ini["fastboot.forceFastBoot"] = "yes"
        ini["fastboot.forceChosenSnapshotBoot"] = "no"
        ini["fastboot.chosenSnapshotFile"] = ""

        ini["runtime.network.latency"] = "none"
        ini["runtime.network.speed"] = "full"
        return ini
    }

    static func cpuArch(for abi: String) -> String {
        switch abi {
        case "arm64-v8a": return "arm64"
        case "armeabi-v7a": return "arm"
        case "x86_64": return "x86_64"
        case "x86": return "x86"
        default: return abi
        }
    }

    static func defaultTagDisplay(_ tag: String) -> String {
        switch tag {
        case "google_apis_playstore": return "Google Play"
        case "google_apis": return "Google APIs"
        case "default": return "Default Android System Image"
        default: return tag
        }
    }
}
