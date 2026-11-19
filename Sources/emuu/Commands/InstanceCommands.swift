import Foundation
import ArgumentParser
import EmuuBase
import EmuuEngine

enum PresetArgument: String, ExpressibleByArgument, CaseIterable, Sendable {
    case standard, lite, gaming
    var preset: InstancePreset {
        switch self {
        case .standard: return .standard
        case .lite: return .lite
        case .gaming: return .gaming
        }
    }
}

extension GPUMode: ExpressibleByArgument {}
extension VideoDecoderMode: ExpressibleByArgument {}

struct Create: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create an instance (Play Store image, memory-tuned AVD) in ~/.emuu.",
        discussion: """
        Presets: standard = 2048 MB / 4 cores / balanced governor; lite = 1536 MB / 2 cores / lite governor; \
        gaming = 3072 MB / 4 cores / performance governor. Overrides below apply on top of the preset.
        The Android version (--android) is fixed for the instance's lifetime; `emuu images list` shows what is installed.
        """)

    @Argument(help: "Instance name (letters, digits, '.', '_', '-').")
    var name: String

    @Option(help: "Preset: standard, lite or gaming.")
    var preset: PresetArgument = .standard

    @Option(help: "Display name.")
    var displayName: String?

    @Option(help: "Android version (API level), e.g. 35, 34, 36.1. Default: \(SystemImageCatalog.defaultVersion.number) when installed. Must be installed (`emuu images install <version>`); cannot be changed later.")
    var android: String?

    @Option(help: "Guest RAM in MB (1024-8192).")
    var ram: Int?

    @Option(help: "Virtual CPU cores (1-8).")
    var cores: Int?

    @Option(help: "Governor profile stored with the instance: lite, balanced or performance.")
    var profile: ProfileArgument?

    @Option(help: "Screen as WIDTHxHEIGHT@DPI, e.g. 1080x2400@420.")
    var screen: String?

    @Option(help: "GPU mode: auto, host, swiftshader_indirect, angle_indirect, guest.")
    var gpu: GPUMode?

    @Flag(help: "Disable guest audio output (the microphone is always off).")
    var noAudio = false

    @Option(help: "Video decoder: auto (default: \(VideoDecoderMode.resolvedDefault.rawValue)), hardware (host VideoToolbox), software (Android's own decoders in the guest), host-software (host ffmpeg). See `emuu video-decoder --help`.")
    var videoDecoder: VideoDecoderMode?

    @Option(help: "Back camera: virtualscene (default; can show a picture, `emuu camera show`), emulated, none, webcam<N> or webcam:<name>. See `emuu camera --help`.")
    var cameraBack: CameraSource?

    @Option(help: "Front camera: emulated (default), none, webcam<N> or webcam:<name>.")
    var cameraFront: CameraSource?

    @Option(help: "Fixed console port (even, 5554-5584); adb uses port+1. Default: first free pair at launch.")
    var port: Int?

    @Flag(help: "JSON output.")
    var json = false

    static func parseScreen(_ text: String) throws -> DisplaySpec {
        let parts = text.split(whereSeparator: { $0 == "x" || $0 == "@" }).map(String.init)
        guard parts.count == 3, let w = Int(parts[0]), let h = Int(parts[1]), let d = Int(parts[2]) else {
            throw ValidationError("--screen must look like 720x1600@320")
        }
        return DisplaySpec(width: w, height: h, density: d)
    }

    func makeConfig(id: InstanceID, image: SystemImageRef) throws -> InstanceConfig {
        var config = preset.preset.makeConfig(id: id, displayName: displayName, systemImage: image,
                                              ports: try port.map { p in
                                                  // adb only discovers emulators whose adb port is 5555…5585 (the engine warns
                                                  // "outside the recommended range"); higher ports boot but never show up.
                                                  guard p <= 5584 else { throw CLIError("--port \(p): adb only finds emulators on console ports 5554-5584") }
                                                  return try InstancePorts(console: p)
                                              })
        if let ram { config.ramMB = ram }
        if let cores { config.cores = cores }
        if let profile { config.memoryProfile = profile.memoryProfile }
        if let screen { config.display = try Self.parseScreen(screen) }
        if let gpu { config.gpu = gpu }
        if noAudio { config.audioOutput = false }
        if let videoDecoder { config.videoDecoder = videoDecoder }
        if cameraBack != nil || cameraFront != nil {
            var cams = config.cameraConfig
            if let cameraBack { cams.back = cameraBack }
            if let cameraFront { cams.front = cameraFront }
            config.camera = cams
        }
        do { try config.validate() } catch { throw ValidationError(describe(error)) }
        return config
    }

    func run() async throws {
        let ctx = try CLIContext.live()
        guard let id = InstanceID(rawValue: name) else { throw CLIError(describe(EmuuError.invalidInstanceID(name))) }
        let image: InstalledSystemImage
        if android == nil, ctx.engines.playStoreImages.isEmpty, let other = ctx.engines.preferredImage {
            Out.err("Warning: no Play Store image; using \(other). \(ctx.engines.missingPlayStoreImageAdvice ?? "")")
            image = other
        } else {
            do { image = try SystemImageCatalog.resolve(android, installed: ctx.engines.installedImages) } catch {
                throw CLIError(describe(error))
            }
        }
        if let existing = try? ctx.store.load(id), android != nil, existing.systemImage != image.ref {
            throw CLIError("\(id) already exists and runs \(existing.systemImage.androidLabel); an instance's Android version cannot be changed. Pick another name.")
        }
        let config = try ctx.store.create(try makeConfig(id: id, image: image.ref))
        if json { return try Out.json(config) }
        Out.line("Created \(config.id): \(config.ramMB) MB RAM, \(config.cores) cores, \(config.display.width)x\(config.display.height)@\(config.display.density), gpu \(config.gpu.rawValue), governor \(ProfileArgument(config.memoryProfile).rawValue), \(config.systemImage.androidLabel), image \(config.systemImage).")
        if config.ramMB < 2048 {
            Out.line("Note: the engine may raise guest RAM below 2048 MB to 2048 (measured on 36.4.9 with API 36.1), whatever is configured; `emuu list` shows the effective value after the first start.")
        }
        Out.line("Start it with `emuu start \(config.id)` (first boot is a cold boot, ~25 s).")
    }
}

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List instances.", aliases: ["ls"])

    @Flag(help: "JSON output.")
    var json = false

    struct Row: Codable, Sendable {
        var name: String
        var state: String
        var serial: String?
        /// RAM the engine really runs with (`hardware-qemu.ini`), else the configured value.
        var ramMB: Int
        var configuredRAMMB: Int
        var cores: Int
        var profile: String
        var image: String
        /// Android version (API level) of the image, e.g. "35", "36.1".
        var android: String?
        var supervised: Bool
    }

    func run() async throws {
        let ctx = try CLIContext.live()
        let registry = SupervisorRegistry(paths: ctx.paths)
        var rows: [Row] = []
        for config in ctx.store.list() {
            let engine = try await ctx.engines.engine(for: config.id)
            let state = await engine.refresh()
            let serial = await engine.serial()
            // The engine may raise the configured RAM (android-36.1: 1536 → 2048 MB); show what it really uses.
            rows.append(Row(name: config.id.rawValue, state: state.description, serial: serial?.rawValue,
                            ramMB: EffectiveRAM.megabytes(for: config, paths: ctx.paths), configuredRAMMB: config.ramMB,
                            cores: config.cores, profile: ProfileArgument(config.memoryProfile).rawValue,
                            image: config.systemImage.description, android: config.systemImage.androidVersion?.number, supervised: registry.liveSupervisor(for: config.id) != nil))
        }
        if json { return try Out.json(rows) }
        if rows.isEmpty { return Out.line("No instances. Create one with `emuu create <name>`.") }
        Out.line(Fmt.table(["NAME", "STATE", "SERIAL", "ANDROID", "RAM", "CORES", "PROFILE", "SUPERVISED"],
                           rows.map { [$0.name, $0.state, $0.serial ?? "-", $0.android ?? $0.image, Self.ramText(effective: $0.ramMB, configured: $0.configuredRAMMB), "\($0.cores)", $0.profile, $0.supervised ? "yes" : "no"] }))
    }
}

extension List {
    /// "2048 MB", or "2048 MB (set 1536)" when the engine raised the configured value (pure; unit-tested).
    static func ramText(effective: Int, configured: Int) -> String {
        effective == configured ? "\(effective) MB" : "\(effective) MB (set \(configured))"
    }
}

struct Delete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Delete an instance and all its data (apps, snapshots).", aliases: ["rm"])

    @Argument(help: "Instance name.")
    var name: String

    @Flag(name: [.short, .long], help: "Do not ask for confirmation.")
    var yes = false

    func run() async throws {
        let ctx = try CLIContext.live()
        let config = try ctx.resolveInstance(name)
        if !yes {
            guard isatty(STDIN_FILENO) != 0 else { throw CLIError("Refusing to delete \(config.id) without --yes (stdin is not a terminal).") }
            FileHandle.standardError.write(Data("Delete \(config.id) and all of its data? Type the name to confirm: ".utf8))
            guard readLine()?.trimmingCharacters(in: .whitespaces) == config.id.rawValue else { throw CLIError("Not deleted.") }
        }
        let registry = SupervisorRegistry(paths: ctx.paths)
        if let sup = registry.liveSupervisor(for: config.id) {
            let reply = try await ControlClient(socketPath: sup.socketPath).send(ControlRequest(command: .stop, save: false), timeout: .seconds(240))
            guard reply.ok else { throw CLIError("could not stop the supervisor: \(reply.message ?? "?")") }
            // Wait for the supervisor to release its lock before removing files.
            for _ in 0..<50 where registry.isLocked(config.id) { try await Task.sleep(for: .milliseconds(100)) }
        }
        try await ctx.engines.deleteInstance(config.id)
        try? FileManager.default.removeItem(at: registry.lockFile(for: config.id))
        Out.line("Deleted \(config.id).")
    }
}
