import Darwin
import Foundation
import ArgumentParser
import EmuuBase
import EmuuEngine
import EmuuADB
import EmuuDisplay
import EmuuFarm

/// One doctor finding.
struct DoctorCheck: Codable, Sendable, Hashable {
    enum Level: String, Codable, Sendable, Hashable { case ok, warn, fail, info }
    var name: String
    var level: Level
    var detail: String
    /// Command(s) that fix the problem.
    var fix: String?
}

/// Everything the doctor probes, gathered first so the verdicts are a pure function (unit-tested).
struct DoctorFacts: Sendable {
    var isARM64: Bool
    var macOSVersion: OperatingSystemVersion
    var hypervisorSupported: Bool
    var physicalMemoryBytes: UInt64
    var sdkRoot: String?
    var sdkError: String?
    var sdkManagerPath: String
    var emulatorVersion: String?
    var accelCheckOutput: String?
    var playStoreImages: [String]
    var otherARMImages: [String]
    var imageAdvice: String?
    var adbPath: String?
    var adbServerVersion: Int?
    var adbError: String?
    var emuuHome: String
    var emuuHomeWritable: Bool
    /// The engine ships the gRPC EmulatorController service the display uses (`emulator/lib/emulator_controller.proto`).
    var engineGRPCAvailable: Bool
    var instanceCount: Int
    var runningInstances: [String]
    /// Farm: APFS clone support on the EMUU_HOME volume, its free space, and the capacity estimate.
    var supportsClones: Bool? = nil
    var freeDiskBytes: UInt64? = nil
    var farmCapacity: CapacityReport? = nil
    var farmCost: DeviceCost? = nil
    /// One entry per installed Google Play arm64 image (Android version).
    var images: [ImageFact] = []

    struct ImageFact: Sendable, Hashable {
        var version: AndroidVersion
        var package: String
        var supported: Bool
        var isDefault: Bool
        /// Files the engine needs that are missing from the image directory.
        var missingFiles: [String]
        var instances: [String]
    }

    /// Files every Google Play arm64 image has that the engine loads at boot.
    static let requiredImageFiles = ["system.img", "vendor.img", "ramdisk.img", "kernel-ranchu", "source.properties"]

    static let minimumEmulator = [35, 0, 0]

    static func versionTriple(_ text: String?) -> [Int]? {
        guard let text else { return nil }
        let parts = text.split(separator: ".").prefix(3).compactMap { Int($0) }
        return parts.count >= 2 ? parts + Array(repeating: 0, count: 3 - parts.count) : nil
    }

    func evaluate() -> [DoctorCheck] {
        var out: [DoctorCheck] = []
        out.append(isARM64
            ? DoctorCheck(name: "Apple Silicon", level: .ok, detail: "arm64 host")
            : DoctorCheck(name: "Apple Silicon", level: .fail, detail: "Emuu supports Apple Silicon (arm64) Macs only."))
        let v = macOSVersion
        out.append(v.majorVersion >= 14
            ? DoctorCheck(name: "macOS", level: .ok, detail: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
            : DoctorCheck(name: "macOS", level: .fail, detail: "macOS 14 or later is required (found \(v.majorVersion).\(v.minorVersion))."))
        out.append(hypervisorSupported
            ? DoctorCheck(name: "Hypervisor.framework", level: .ok, detail: "kern.hv_support = 1")
            : DoctorCheck(name: "Hypervisor.framework", level: .fail, detail: "Hardware virtualisation is unavailable (kern.hv_support = 0); the engine cannot run (inside a VM?)."))
        let gib = Double(physicalMemoryBytes) / Double(ByteCount.gib)
        out.append(DoctorCheck(name: "Host memory", level: gib < 8 ? .warn : .ok,
                               detail: String(format: "%.0f GiB", gib) + (gib < 8 ? "; use `emuu create --preset lite` and one instance at a time" : "; a 2 GB guest costs about 2.8 GiB of real host memory (Activity Monitor shows ~4.5 GiB: it counts guest RAM twice)")))

        guard let sdkRoot else {
            out.append(DoctorCheck(name: "Android SDK", level: .fail, detail: sdkError ?? "not found",
                                   fix: """
                                   Install Android Studio (or: brew install --cask android-commandlinetools), then
                                     sdkmanager "emulator" "platform-tools" "\(SystemImageRef.playStoreDefault.sdkManagerPackage)"
                                   and set ANDROID_HOME if the SDK is not in ~/Library/Android/sdk.
                                   """))
            return out + tail()
        }
        out.append(DoctorCheck(name: "Android SDK", level: .ok, detail: sdkRoot))

        if let ev = emulatorVersion, let triple = Self.versionTriple(ev) {
            let tooOld = triple.lexicographicallyPrecedes(Self.minimumEmulator)
            out.append(DoctorCheck(name: "Emulator engine", level: tooOld ? .warn : .ok,
                                   detail: "version \(ev)" + (tooOld ? " (Emuu was built against 36.4.9)" : ""),
                                   fix: tooOld ? "\(sdkManagerPath) \"emulator\"" : nil))
        } else {
            out.append(DoctorCheck(name: "Emulator engine", level: .warn, detail: "version unknown (no emulator/source.properties)",
                                   fix: "\(sdkManagerPath) \"emulator\""))
        }
        if let accel = accelCheckOutput {
            let ok = accel.contains("Hypervisor.Framework") && !accel.lowercased().contains("error")
            out.append(DoctorCheck(name: "Engine acceleration", level: ok ? .ok : .fail,
                                   detail: accel.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                                    .filter { !$0.isEmpty && $0 != "accel:" && $0 != "accel" && $0 != "0" }.joined(separator: "; ").ifEmpty("no output")))
        }

        if !playStoreImages.isEmpty {
            let def = images.first(where: \.isDefault)
            var detail = playStoreImages.joined(separator: ", ")
            if let def, def.version != SystemImageCatalog.defaultVersion {
                detail += "; new instances get \(def.version.label) (the usual default, API \(SystemImageCatalog.defaultVersion.number), is not installed)"
            }
            out.append(DoctorCheck(name: "Play Store image", level: .ok, detail: detail))
        } else {
            out.append(DoctorCheck(name: "Play Store image", level: otherARMImages.isEmpty ? .fail : .warn,
                                   detail: otherARMImages.isEmpty ? "no arm64 system image installed"
                                       : "only images without Play Store: \(otherARMImages.joined(separator: ", "))",
                                   fix: "emuu images install \(SystemImageCatalog.defaultVersion.number)   (or: \(sdkManagerPath) \"\(SystemImageRef.playStoreDefault.sdkManagerPackage)\")"))
        }
        out += imageChecks()

        if let adbPath {
            if let version = adbServerVersion {
                out.append(DoctorCheck(name: "adb", level: .ok, detail: "\(adbPath) (server protocol \(version))"))
            } else {
                out.append(DoctorCheck(name: "adb", level: .warn, detail: "\(adbPath); server not reachable: \(adbError ?? "?")",
                                       fix: "\(adbPath) start-server"))
            }
        } else {
            out.append(DoctorCheck(name: "adb", level: .fail, detail: "not found", fix: "\(sdkManagerPath) \"platform-tools\""))
        }
        return out + tail()
    }

    /// One check per installed Android version (pure; unit-tested). A damaged image fails only when an instance uses it.
    func imageChecks() -> [DoctorCheck] {
        images.map { img in
            let name = "\(img.version.label)"
            let users = img.instances.isEmpty ? "no instances" : "instances: \(img.instances.joined(separator: ", "))"
            if !img.missingFiles.isEmpty {
                return DoctorCheck(name: name, level: img.instances.isEmpty ? .warn : .fail,
                                   detail: "image incomplete, missing \(img.missingFiles.joined(separator: ", ")) (\(users))",
                                   fix: "\(sdkManagerPath) --uninstall \"\(img.package)\" && emuu images install \(img.version.number)")
            }
            var detail = (img.isDefault ? "default for new instances; " : "") + users
            if !img.supported { detail += "; not a version Emuu supports (\(SystemImageCatalog.supported.map(\.version.number).joined(separator: ", ")))" }
            return DoctorCheck(name: name, level: img.supported ? .ok : .warn, detail: detail)
        }
    }

    private func tail() -> [DoctorCheck] {
        var out: [DoctorCheck] = []
        out.append(emuuHomeWritable
            ? DoctorCheck(name: "Emuu state", level: .ok, detail: "\(emuuHome) (instances never touch ~/.android/avd)")
            : DoctorCheck(name: "Emuu state", level: .fail, detail: "\(emuuHome) is not writable", fix: "mkdir -p \(emuuHome) && chmod u+rwx \(emuuHome)"))
        out.append(DoctorCheck(name: "Display (engine gRPC framebuffer)", level: engineGRPCAvailable ? .ok : .warn,
                               detail: engineGRPCAvailable ? "EmulatorController service present; frames via shared memory, nothing installed in the guest"
                                                           : "this emulator package has no gRPC EmulatorController service; update the emulator package",
                               fix: engineGRPCAvailable ? nil : "sdkmanager \"emulator\""))
        out.append(DoctorCheck(name: "Instances", level: instanceCount == 0 ? .info : .ok,
                               detail: instanceCount == 0 ? "none yet" : "\(instanceCount) (running: \(runningInstances.joined(separator: ", ").ifEmpty("none")))",
                               fix: instanceCount == 0 ? "emuu create phone && emuu start phone" : nil))
        out += farmChecks()
        return out
    }

    func farmChecks() -> [DoctorCheck] {
        var out: [DoctorCheck] = []
        if let clones = supportsClones {
            out.append(clones
                ? DoctorCheck(name: "Farm: APFS clones", level: .ok, detail: "\(emuuHome) supports clonefile(2): a farm device costs only the blocks it changes")
                : DoctorCheck(name: "Farm: APFS clones", level: .warn, detail: "\(emuuHome) is not on APFS: every farm device would be a full ~3 GB copy",
                              fix: "export EMUU_HOME=<a directory on an APFS volume>"))
        }
        if let free = freeDiskBytes {
            let low = free < 20 * ByteCount.gib
            out.append(DoctorCheck(name: "Farm: free disk", level: low ? .warn : .ok,
                                   detail: "\(ByteCount.format(free)) free; a golden image takes ~3.5 GB; a device adds only what it writes (measured ≈ 0.3 GB per device in a 35-minute soak)"))
        }
        if let cap = farmCapacity, let cost = farmCost {
            out.append(DoctorCheck(name: "Farm: capacity", level: cap.ceiling >= 1 ? .info : .warn,
                                   detail: CapacityText.describe(cap, cost: cost).replacingOccurrences(of: "\n", with: "\n       ")))
        }
        return out
    }
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check the host, Android SDK, engine, installed Android versions and adb.")

    @Flag(help: "JSON output.") var json = false

    func run() async throws {
        let facts = await Self.gather()
        let checks = facts.evaluate()
        if json {
            try Out.json(checks)
        } else {
            for c in checks {
                let mark: String
                switch c.level {
                case .ok: mark = "[ ok ]"
                case .warn: mark = "[warn]"
                case .fail: mark = "[FAIL]"
                case .info: mark = "[info]"
                }
                Out.line("\(mark) \(c.name): \(c.detail)")
                if let fix = c.fix {
                    for line in fix.split(separator: "\n") { Out.line("       fix: \(line)") }
                }
            }
        }
        if checks.contains(where: { $0.level == .fail }) { throw ExitCode(1) }
    }

    static func sysctlInt(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return size == 4 ? Int64(Int32(truncatingIfNeeded: value)) : value
    }

    static func gather(environment: [String: String] = ProcessInfo.processInfo.environment) async -> DoctorFacts {
        let paths = EmuuPaths.default(environment: environment)
        try? paths.ensureDirectories()
        var facts = DoctorFacts(
            isARM64: sysctlInt("hw.optional.arm64") == 1,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersion,
            hypervisorSupported: sysctlInt("kern.hv_support") == 1,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            sdkRoot: nil, sdkError: nil, sdkManagerPath: "sdkmanager", emulatorVersion: nil, accelCheckOutput: nil,
            playStoreImages: [], otherARMImages: [], imageAdvice: nil,
            adbPath: ADBLocator.find(environment: environment)?.path, adbServerVersion: nil, adbError: nil,
            emuuHome: paths.root.path, emuuHomeWritable: FileManager.default.isWritableFile(atPath: paths.root.path),
            engineGRPCAvailable: false, instanceCount: 0, runningInstances: [])
        do {
            let sdk = try SDKLocator(environment: environment).locate()
            facts.sdkRoot = sdk.root.path
            facts.sdkManagerPath = sdk.sdkManagerPath
            facts.emulatorVersion = sdk.emulatorVersion
            facts.engineGRPCAvailable = FileManager.default.fileExists(
                atPath: sdk.root.appendingPathComponent("emulator/lib/emulator_controller.proto").path)
            facts.adbPath = sdk.adb.path
            if let r = try? await SystemProcessRunner().run(ProcessRequest(executable: sdk.emulator, arguments: ["-accel-check"], timeout: .seconds(20))) {
                facts.accelCheckOutput = (r.stdoutString + "\n" + String(decoding: r.stderr, as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let images = SDKLocator.installedImages(in: sdk).filter { $0.ref.abi == "arm64-v8a" }
            facts.playStoreImages = images.filter(\.hasPlayStore).map(\.description)
            facts.otherARMImages = images.filter { !$0.hasPlayStore }.map(\.description)
            let configsForImages = (try? EngineEnvironment(paths: paths, sdk: sdk))?.store.list() ?? []
            let defaultRef = SystemImageCatalog.defaultImage(installed: SDKLocator.installedImages(in: sdk))?.ref
            facts.images = SystemImageCatalog.installed(in: sdk).compactMap { img in
                guard let v = img.ref.androidVersion else { return nil }
                let missing = DoctorFacts.requiredImageFiles.filter {
                    !FileManager.default.fileExists(atPath: img.directory.appendingPathComponent($0).path)
                }
                return DoctorFacts.ImageFact(version: v, package: img.ref.sdkManagerPackage, supported: SystemImageCatalog.entry(for: v) != nil,
                                             isDefault: img.ref == defaultRef, missingFiles: missing,
                                             instances: SystemImageCatalog.users(of: img.ref, in: configsForImages).map(\.rawValue))
            }
            if let env = try? EngineEnvironment(paths: paths, sdk: sdk) {
                let configs = env.store.list()
                facts.instanceCount = configs.count
                facts.runningInstances = configs.filter { env.store.isRunning($0.id) }.map(\.id.rawValue)
            }
        } catch {
            facts.sdkError = describe(error)
        }
        let farmRoot = paths.root
        facts.supportsClones = InstanceStore.supportsClones(at: farmRoot)
        facts.freeDiskBytes = (try? farmRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage).map { UInt64(max(0, $0)) }
        let cost = FarmProfile.measuredCost
        facts.farmCost = cost
        facts.farmCapacity = CapacityGuard.evaluate(host: .current(), cost: cost, running: facts.runningInstances.count)
        if let adb = facts.adbPath {
            do {
                facts.adbServerVersion = try await ADBServer(endpoint: .fromEnvironment(environment), adbExecutable: URL(fileURLWithPath: adb)).version()
            } catch {
                facts.adbError = describe(error)
            }
        }
        return facts
    }
}
