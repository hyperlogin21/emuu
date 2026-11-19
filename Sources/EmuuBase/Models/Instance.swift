import Foundation

/// Name of an Emuu instance; also used verbatim as the AVD name passed to `emulator -avd`.
/// Allowed: `[A-Za-z0-9._-]`, 1…64 chars, must start with a letter or digit.
public struct InstanceID: RawRepresentable, Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    /// Throwing initializer for user input.
    public init(validating raw: String) throws {
        guard let id = InstanceID(rawValue: raw) else { throw EmuuError.invalidInstanceID(raw) }
        self = id
    }

    public static func isValid(_ raw: String) -> Bool {
        guard (1...64).contains(raw.count), let first = raw.unicodeScalars.first else { return false }
        func ok(_ s: Unicode.Scalar) -> Bool {
            s.isASCII && (CharacterSet.alphanumerics.contains(s) || s == "." || s == "_" || s == "-")
        }
        guard first.isASCII, CharacterSet.alphanumerics.contains(first) else { return false }
        return raw.unicodeScalars.allSatisfy(ok)
    }

    /// Derives a valid ID from arbitrary text ("My Phone!" -> "My_Phone"). Returns nil if nothing usable remains.
    public static func sanitized(from text: String) -> InstanceID? {
        var out = ""
        for s in text.unicodeScalars {
            if s.isASCII, CharacterSet.alphanumerics.contains(s) || s == "." || s == "-" || s == "_" {
                out.unicodeScalars.append(s)
            } else if !out.hasSuffix("_") {
                out.append("_")
            }
        }
        while let f = out.first, !(f.isASCII && (f.isLetter || f.isNumber)) { out.removeFirst() }
        while out.hasSuffix("_") { out.removeLast() }
        return InstanceID(rawValue: String(out.prefix(64)))
    }

    public var description: String { rawValue }

    public static func < (lhs: InstanceID, rhs: InstanceID) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let id = InstanceID(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid InstanceID '\(raw)'"))
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// Identifies a system image inside the SDK: `system-images/<apiDirectory>/<tag>/<abi>/`.
public struct SystemImageRef: Codable, Sendable, Hashable, CustomStringConvertible {
    /// e.g. "android-36.1"
    public var apiDirectory: String
    /// e.g. "google_apis_playstore"
    public var tag: String
    /// e.g. "arm64-v8a"
    public var abi: String

    public init(apiDirectory: String, tag: String, abi: String) {
        self.apiDirectory = apiDirectory
        self.tag = tag
        self.abi = abi
    }

    /// The Google-certified Play Store image installed on the target machine.
    public static let playStoreDefault = SystemImageRef(apiDirectory: "android-36.1", tag: "google_apis_playstore", abi: "arm64-v8a")

    /// `system-images/android-36.1/google_apis_playstore/arm64-v8a/` (relative to the SDK root,
    /// trailing slash included, the form `image.sysdir.1` in config.ini uses).
    public var sdkRelativePath: String { "system-images/\(apiDirectory)/\(tag)/\(abi)/" }

    /// Package path as used by sdkmanager: `system-images;android-36.1;google_apis_playstore;arm64-v8a`.
    public var sdkManagerPackage: String { "system-images;\(apiDirectory);\(tag);\(abi)" }

    /// True for images that ship the Play Store (and are therefore non-root / Google-certified).
    public var hasPlayStore: Bool { tag.contains("playstore") }

    public var description: String { sdkManagerPackage }
}

/// Graphics backend passed to `emulator -gpu <mode>`. Raw values are the engine's flag values.
public enum GPUMode: String, Codable, Sendable, Hashable, CaseIterable {
    /// Let the engine decide.
    case auto
    /// Host GPU via gfxstream (Metal/ANGLE on macOS). Best for games.
    case host
    /// Software rendering on the host (SwiftShader); slower, CPU heavy, most compatible.
    case swiftshaderIndirect = "swiftshader_indirect"
    /// ANGLE-based indirect rendering.
    case angleIndirect = "angle_indirect"
    /// Guest-side software rendering.
    case guest
}

/// How aggressively the governor and AVD tuning favour memory savings over responsiveness.
/// The thresholds per profile are defined by `EmuuMemory`; this enum is only the user-facing choice.
public enum MemoryProfile: String, Codable, Sendable, Hashable, CaseIterable {
    /// Smallest footprint: small guest RAM, early trimming, freeze quickly when hidden.
    case frugal
    /// Default trade-off.
    case balanced
    /// Games: more guest RAM, trims late, never freezes while visible.
    case performance

    /// Suggested guest RAM for a fresh instance with this profile.
    public var suggestedRAMMB: Int {
        switch self {
        case .frugal: return 2048
        case .balanced: return 3072
        case .performance: return 4096
        }
    }

    /// Suggested Dalvik VM heap (`vm.heapSize`).
    public var suggestedVMHeapMB: Int {
        switch self {
        case .frugal: return 228
        case .balanced: return 256
        case .performance: return 512
        }
    }
}

/// Guest display geometry.
public struct DisplaySpec: Codable, Sendable, Hashable {
    public var width: Int
    public var height: Int
    /// `hw.lcd.density` (dpi).
    public var density: Int

    public init(width: Int, height: Int, density: Int) {
        self.width = width
        self.height = height
        self.density = density
    }

    /// 720x1600 @ 320dpi: phone-shaped and far cheaper to render/encode than 1080p.
    public static let lightweightPhone = DisplaySpec(width: 720, height: 1600, density: 320)
    public static let phone1080 = DisplaySpec(width: 1080, height: 2400, density: 420)
}

/// Console/adb port pair. The engine's convention: console port is even, adb port = console + 1,
/// serial is `emulator-<console>`. Valid console range is 5554…5682.
public struct InstancePorts: Codable, Sendable, Hashable {
    public static let consoleRange = 5554...5682

    public var console: Int
    public var adb: Int { console + 1 }

    public init(console: Int) throws {
        guard Self.consoleRange.contains(console), console % 2 == 0 else {
            throw EmuuError.invalidConfiguration("console port \(console) must be even and within \(Self.consoleRange)")
        }
        self.console = console
    }

    public var serial: DeviceSerial { .emulator(consolePort: console) }

    /// Argument value for `emulator -ports <console>,<adb>`.
    public var portsArgument: String { "\(console),\(adb)" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(console: c.decode(Int.self, forKey: .console))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(console, forKey: .console)
    }

    private enum CodingKeys: String, CodingKey { case console }
}

/// Persisted definition of an Emuu instance. `EmuuEngine` turns this into the AVD's config.ini and
/// launch arguments; nothing else should write AVD files.
public struct InstanceConfig: Codable, Sendable, Hashable {
    public var id: InstanceID
    public var displayName: String
    public var systemImage: SystemImageRef
    /// Guest RAM (`hw.ramSize`).
    public var ramMB: Int
    /// Virtual CPUs (`hw.cpu.ncore`).
    public var cores: Int
    /// Dalvik heap (`vm.heapSize`).
    public var vmHeapMB: Int
    public var display: DisplaySpec
    /// userdata partition size (`disk.dataPartition.size`).
    public var dataPartitionMB: Int
    /// Fixed ports, or nil to let the engine launcher pick a free pair at start.
    public var ports: InstancePorts?
    public var gpu: GPUMode
    public var memoryProfile: MemoryProfile
    /// Guest audio output (games want it). Microphone input is always disabled.
    public var audioOutput: Bool
    public var createdAt: Date
    /// Automation mode (tests/scripts over adb): the governor never freezes or hibernates the instance and only
    /// trims/kills background apps. nil (older configs) = off. Set by `emuu automation on|off`,
    /// `emuu start --automation` and the app's per-instance setting.
    public var automationMode: Bool?
    /// Show Android's on-screen keyboard for focused text fields. nil (older configs) = on.
    public var showSoftKeyboard: Bool?
    /// Run the guest with exactly `ramMB` (engine 36.4.9 raises `-memory` below 2048 MB to 2048 for android-36.1;
    /// Emuu then also passes `-qemu -m <ramMB>`, which the engine's QEMU honours: measured MemTotal 990852 kB for
    /// 1024). nil (older configs) = off, so existing instances and their quick-boot snapshots keep 2048 MB.
    public var guestRAMEnforced: Bool?
    /// Self-healing: the supervisor runs periodic health checks and recovers a hung engine/guest automatically
    /// (see docs/ARCHITECTURE.md, "Self-healing"). nil = off for interactive instances.
    public var selfHeal: Bool?
    /// Golden image this instance was cloned from (farm devices, `emuu clone`), nil otherwise.
    public var goldenSource: String?
    /// Quick-boot snapshot is never saved on exit (`-no-snapshot-save`): farm clones always resume from the golden
    /// state. nil = off.
    public var discardStateOnExit: Bool?

    /// `automationMode` with its default applied.
    public var isAutomationMode: Bool { automationMode ?? false }
    /// `showSoftKeyboard` with its default applied.
    public var softKeyboardEnabled: Bool { showSoftKeyboard ?? true }
    /// `guestRAMEnforced` with its default applied.
    public var isGuestRAMEnforced: Bool { guestRAMEnforced ?? false }
    /// `selfHeal` with its default applied.
    public var isSelfHealing: Bool { selfHeal ?? false }

    public init(
        id: InstanceID,
        displayName: String? = nil,
        systemImage: SystemImageRef = .playStoreDefault,
        memoryProfile: MemoryProfile = .balanced,
        ramMB: Int? = nil,
        cores: Int = 2,
        vmHeapMB: Int? = nil,
        display: DisplaySpec = .lightweightPhone,
        dataPartitionMB: Int = 6144,
        ports: InstancePorts? = nil,
        gpu: GPUMode = .host,
        audioOutput: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName ?? id.rawValue
        self.systemImage = systemImage
        self.memoryProfile = memoryProfile
        self.ramMB = ramMB ?? memoryProfile.suggestedRAMMB
        self.cores = cores
        self.vmHeapMB = vmHeapMB ?? memoryProfile.suggestedVMHeapMB
        self.display = display
        self.dataPartitionMB = dataPartitionMB
        self.ports = ports
        self.gpu = gpu
        self.audioOutput = audioOutput
        self.createdAt = createdAt
    }

    public static let ramRangeMB = 1024...8192
    public static let coreRange = 1...8
    public static let vmHeapRangeMB = 64...1024
    public static let dataPartitionRangeMB = 2048...65536
    public static let dimensionRange = 320...4096
    public static let densityRange = 120...640

    /// Throws `EmuuError.invalidConfiguration` describing every violated bound.
    public func validate() throws {
        var problems: [String] = []
        if !Self.ramRangeMB.contains(ramMB) { problems.append("ramMB \(ramMB) not in \(Self.ramRangeMB)") }
        if !Self.coreRange.contains(cores) { problems.append("cores \(cores) not in \(Self.coreRange)") }
        if !Self.vmHeapRangeMB.contains(vmHeapMB) { problems.append("vmHeapMB \(vmHeapMB) not in \(Self.vmHeapRangeMB)") }
        if vmHeapMB >= ramMB { problems.append("vmHeapMB must be smaller than ramMB") }
        if !Self.dataPartitionRangeMB.contains(dataPartitionMB) {
            problems.append("dataPartitionMB \(dataPartitionMB) not in \(Self.dataPartitionRangeMB)")
        }
        if !Self.dimensionRange.contains(display.width) || !Self.dimensionRange.contains(display.height) {
            problems.append("display \(display.width)x\(display.height) out of range \(Self.dimensionRange)")
        }
        if !Self.densityRange.contains(display.density) { problems.append("density \(display.density) not in \(Self.densityRange)") }
        if displayName.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("displayName is empty") }
        if !problems.isEmpty { throw EmuuError.invalidConfiguration(problems.joined(separator: "; ")) }
    }
}

/// Lifecycle state of an instance, as tracked by `EmuuEngine` and reported via `EngineControl`.
public enum InstanceState: Codable, Sendable, Hashable, CustomStringConvertible {
    /// Not running; no snapshot to resume from (next start cold-boots or uses quick-boot if present).
    case stopped
    /// Engine process launched, Android not yet `sys.boot_completed`.
    case booting
    /// Booted and usable.
    case running
    /// Engine paused (T4). Uses no CPU; memory stays resident until host pressure swaps/compresses it.
    case frozen
    /// Snapshot being written before quitting (T5 in progress).
    case hibernating
    /// Not running, with a hibernation snapshot ready for instant resume.
    case hibernated
    /// Shutdown in progress.
    case stopping
    /// Engine exited unexpectedly.
    case crashed(reason: String)

    public var isRunningEngine: Bool {
        switch self {
        case .booting, .running, .frozen, .hibernating, .stopping: return true
        case .stopped, .hibernated, .crashed: return false
        }
    }

    public var description: String {
        switch self {
        case .stopped: return "stopped"
        case .booting: return "booting"
        case .running: return "running"
        case .frozen: return "frozen"
        case .hibernating: return "hibernating"
        case .hibernated: return "hibernated"
        case .stopping: return "stopping"
        case .crashed(let reason): return "crashed (\(reason))"
        }
    }
}

/// An adb device serial, e.g. `emulator-5554`.
public struct DeviceSerial: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static func emulator(consolePort: Int) -> DeviceSerial {
        DeviceSerial(rawValue: "emulator-\(consolePort)")
    }

    /// Console port for `emulator-NNNN` serials; nil for other devices.
    public var consolePort: Int? {
        guard rawValue.hasPrefix("emulator-") else { return nil }
        return Int(rawValue.dropFirst("emulator-".count))
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}
