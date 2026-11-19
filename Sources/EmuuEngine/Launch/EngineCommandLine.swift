import Darwin
import Foundation
import EmuuBase

/// How guest execution is paused for governor tier T4. See docs/engine-findings.md for measurements.
public enum FreezeMechanism: String, Sendable, Hashable, Codable, CaseIterable {
    /// SIGSTOP/SIGCONT on the QEMU process. 0% CPU while frozen, guest clock stays right, console and adb
    /// do not answer until thawed.
    case signal
    /// Console `avd stop` / `avd start`. ~0.7% CPU while frozen, console keeps answering, but the guest
    /// clock falls behind by the frozen time.
    case console
}

/// Options for one engine launch.
public struct EngineLaunchOptions: Sendable, Hashable {
    /// Ignore the quick-boot snapshot and cold boot (`-no-snapshot-load`).
    public var coldBoot: Bool
    /// Give up waiting for `sys.boot_completed` after this long (the engine is then stopped).
    public var bootTimeout: Duration
    /// Disable network shaping (`-netfast`). Always on by default: shaping only costs CPU.
    public var netfast: Bool
    /// Extra engine flags appended verbatim (before any `-qemu` section).
    public var extraArguments: [String]
    /// Raw QEMU arguments, passed after `-qemu`.
    public var qemuArguments: [String]
    /// Start the gRPC display/input service (`-grpc`). An idle listener costs nothing measurable; farm devices keep
    /// it so `emuu screenshot` and the app can still show them.
    public var grpc: Bool
    /// Cameras for this launch instead of the stored setting (the app uses it when macOS camera access was denied
    /// for a Mac camera). nil = the instance's setting.
    public var cameraOverride: CameraConfig?

    public init(coldBoot: Bool = false, bootTimeout: Duration = .seconds(600), netfast: Bool = true,
                extraArguments: [String] = [], qemuArguments: [String] = [], grpc: Bool = true,
                cameraOverride: CameraConfig? = nil) {
        self.grpc = grpc
        self.cameraOverride = cameraOverride
        self.coldBoot = coldBoot
        self.bootTimeout = bootTimeout
        self.netfast = netfast
        self.extraArguments = extraArguments
        self.qemuArguments = qemuArguments
    }
}

/// Builds the headless engine command line. Every flag here exists in `emulator -help` for 36.4.9.
public enum EngineCommandLine {
    /// - Parameter grpcPort: the engine's gRPC service port (display, input, clipboard, rotation). The
    ///   engine binds it on 127.0.0.1 only and, with `-grpc-use-token`, requires the random bearer token it
    ///   writes to its discovery file (`~/Library/Caches/TemporaryItems/avd/running/pid_<pid>.ini`, user-only).
    public static func arguments(for config: InstanceConfig, ports: InstancePorts, grpcPort: Int? = nil,
                                 options: EngineLaunchOptions,
                                 videoDecoder: VideoDecoderMode? = nil,
                                 cameras: (back: String, front: String)? = nil) -> [String] {
        var args = [
            "-avd", config.id.rawValue,
            "-no-window",                       // runs qemu-system-aarch64-headless: no Qt, no window
            "-no-boot-anim",
            "-ports", ports.portsArgument,
            "-gpu", config.gpu.rawValue,
            "-memory", String(config.ramMB),
            "-cores", String(config.cores),
            "-no-metrics",                      // no usage-metrics uploads
        ]
        if let grpcPort { args += ["-grpc", String(grpcPort), "-grpc-use-token"] }
        if options.netfast { args.append("-netfast") }
        if !config.audioOutput { args.append("-no-audio") }
        if options.coldBoot { args.append("-no-snapshot-load") }
        if config.discardStateOnExit == true { args.append("-no-snapshot-save") }
        args += cameraArguments(cameras ?? defaultCameraValues(options.cameraOverride ?? config.effectiveCamera()))
        args += videoDecoderArguments(videoDecoder ?? config.effectiveVideoDecoder())
        args += options.extraArguments
        var qemu = options.qemuArguments
        // The engine raises -memory below its floor (2048 MB on android-36.1); QEMU's own -m wins.
        if config.isGuestRAMEnforced && !qemu.contains("-m") { qemu = ["-m", String(config.ramMB)] + qemu }
        if !qemu.isEmpty { args += ["-qemu"] + qemu }
        return args
    }

    /// Engine flags for a (resolved) video decoder mode. `software` turns off the engine feature that registers the
    /// guest's goldfish codecs (`androidboot.qemu.hwcodec.{avc,hevc,vpx}dec=2` on the kernel command line), so
    /// Android falls back to its own `c2.android.*` decoders.
    public static func videoDecoderArguments(_ mode: VideoDecoderMode) -> [String] {
        mode.resolved == .software ? ["-feature", "-HardwareDecoder"] : []
    }

    /// `-camera-back` / `-camera-front` for engine values (`none`, `emulated`, `virtualscene`, `webcamN`). Values
    /// equal to config.ini's (`none`, which Emuu always writes there) are left out.
    public static func cameraArguments(_ cameras: (back: String, front: String)) -> [String] {
        var args: [String] = []
        if cameras.back != "none" { args += ["-camera-back", cameras.back] }
        if cameras.front != "none" { args += ["-camera-front", cameras.front] }
        return args
    }

    /// Engine values without host lookups (a Mac camera named by ID or name is kept as given; `EngineInstance`
    /// resolves those through `HostCameraList` before launching).
    static func defaultCameraValues(_ c: CameraConfig) -> (back: String, front: String) {
        (HostCameraList.engineValue(c.back, hostCameras: nil) ?? "none", HostCameraList.engineValue(c.front, hostCameras: nil) ?? "none")
    }

    /// Environment variable the engine reads when a host decoder is created (36.4.9: only the exact value "0"
    /// turns VideoToolbox off, anything else or unset keeps it).
    public static let vtbEnvironmentKey = "ANDROID_EMU_MEDIA_DECODER_VTB"

    /// Environment for the engine: Emuu's AVD home only. `ANDROID_SDK_ROOT` points at the SDK in use so the
    /// engine never falls back to another SDK. `videoDecoder` (resolved) sets the host decoder choice explicitly so
    /// an inherited `ANDROID_EMU_MEDIA_DECODER_VTB` cannot change it.
    public static func environment(paths: EmuuPaths, sdk: AndroidSDK, videoDecoder: VideoDecoderMode? = nil) -> [String: String] {
        var env = [
            "ANDROID_AVD_HOME": paths.avdHome.path,
            "ANDROID_SDK_ROOT": sdk.root.path,
            "ANDROID_HOME": sdk.root.path,
        ]
        if let mode = videoDecoder?.resolved {
            env[vtbEnvironmentKey] = mode == .hostSoftware ? "0" : "1"
        }
        return env
    }

    /// Console port from an engine's argv (`-ports C,A` or `-port C`), for adopting running engines.
    public static func consolePort(fromArguments argv: [String]) -> Int? {
        if let i = argv.firstIndex(of: "-ports"), i + 1 < argv.count {
            return Int(argv[i + 1].split(separator: ",").first ?? "")
        }
        if let i = argv.firstIndex(of: "-port"), i + 1 < argv.count { return Int(argv[i + 1]) }
        return nil
    }
}

/// Picks a free console/adb port pair.
public enum PortAllocator {
    /// True when nothing listens on 127.0.0.1:`port` (we can bind it).
    public static func isPortFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        // Like any server: ignore TIME_WAIT leftovers from the previous engine's connections. A port with an
        // active listener still fails to bind.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return rc == 0
    }

    /// gRPC port for an instance: `console + 3000` (5554 → 8554, Android Studio's default range) when free,
    /// else the first free port in 8554…8999 not in `excluding`.
    public static func grpcPort(for ports: InstancePorts, isFree: (Int) -> Bool = isPortFree, excluding: Set<Int> = []) -> Int? {
        let preferred = ports.console + 3000
        if !excluding.contains(preferred), isFree(preferred) { return preferred }
        return (8554...8999).first { !excluding.contains($0) && isFree($0) }
    }

    /// First console port in range whose console and adb ports are both free.
    public static func firstFreePair(isFree: (Int) -> Bool = isPortFree, excluding: Set<Int> = []) -> InstancePorts? {
        for console in stride(from: InstancePorts.consoleRange.lowerBound, through: InstancePorts.consoleRange.upperBound, by: 2)
        where !excluding.contains(console) && isFree(console) && isFree(console + 1) {
            return try? InstancePorts(console: console)
        }
        return nil
    }
}
