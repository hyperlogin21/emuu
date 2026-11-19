import Foundation
import EmuuBase

/// Entry point for the app and CLI: the SDK, the instance store and one `EngineInstance` per instance.
///
/// ```swift
/// let env = try EngineEnvironment.live()
/// let config = InstancePreset.standard.makeConfig(id: try InstanceID(validating: "pixel"))
/// try env.store.create(config)
/// let engine = try await env.engine(for: config.id)
/// try await engine.start()
/// ```
public final class EngineEnvironment: Sendable {
    public let paths: EmuuPaths
    public let sdk: AndroidSDK
    public let store: InstanceStore
    public let dependencies: EngineDependencies
    public let timings: EngineTimings
    public let freezeMechanism: FreezeMechanism
    private let engines = Locked<[InstanceID: EngineInstance]>([:])

    public init(paths: EmuuPaths, sdk: AndroidSDK, dependencies: EngineDependencies = .live(),
                timings: EngineTimings = .default, freezeMechanism: FreezeMechanism = .signal) throws {
        self.paths = paths
        self.sdk = sdk
        self.store = try InstanceStore(paths: paths, sdk: sdk)
        self.dependencies = dependencies
        self.timings = timings
        self.freezeMechanism = freezeMechanism
    }

    /// Default paths (`~/.emuu` or `$EMUU_HOME`) and the located SDK. Creates the directory layout.
    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> EngineEnvironment {
        let paths = EmuuPaths.default(environment: environment)
        try paths.ensureDirectories()
        let sdk = try SDKLocator(environment: environment).locate()
        return try EngineEnvironment(paths: paths, sdk: sdk)
    }

    /// The engine controller for `id`, with its state refreshed from the OS (adopting a running engine).
    /// The same actor is returned for the same id until `forget(_:)`.
    public func engine(for id: InstanceID) async throws -> EngineInstance {
        if let existing = engines.withLock({ $0[id] }) { return existing }
        let config = try store.load(id)
        let fresh = EngineInstance(config: config, sdk: sdk, paths: paths, dependencies: dependencies,
                                   timings: timings, freezeMechanism: freezeMechanism)
        let chosen = engines.withLock { map -> EngineInstance in
            if let raced = map[id] { return raced }
            map[id] = fresh
            return fresh
        }
        await chosen.refresh()
        return chosen
    }

    /// Drops the cached controller (call after `store.update` so the next `engine(for:)` sees the new config).
    public func forget(_ id: InstanceID) {
        engines.withLock { $0[id] = nil }
    }

    /// Installed images, best first, and the preferred one (Play Store arm64 if present).
    public var installedImages: [InstalledSystemImage] { SDKLocator.installedImages(in: sdk) }
    /// The image new instances get when no Android version is chosen: `SystemImageCatalog.defaultImage`
    /// (Android 16 QPR2 / API 36.1 when installed), else the best other installed image.
    public var preferredImage: InstalledSystemImage? {
        let all = installedImages
        return SystemImageCatalog.defaultImage(installed: all) ?? all.first { $0.ref.abi == "arm64-v8a" }
    }
    /// Installed Google Play arm64 images (the ones Emuu creates instances from), newest first.
    public var playStoreImages: [InstalledSystemImage] { SystemImageCatalog.installed(from: installedImages) }

    /// Text telling the user how to install a Play Store image, or nil when one is installed.
    public var missingPlayStoreImageAdvice: String? {
        installedImages.contains { $0.hasPlayStore && $0.ref.abi == "arm64-v8a" } ? nil : SDKLocator.missingImageAdvice(sdk: sdk)
    }

    /// Creates an instance from a preset with `image` (default: `preferredImage`).
    @discardableResult
    public func createInstance(id: InstanceID, preset: InstancePreset = .standard, displayName: String? = nil,
                               ports: InstancePorts? = nil, image: SystemImageRef? = nil) throws -> InstanceConfig {
        guard let ref = image ?? preferredImage?.ref else {
            throw EmuuError.systemImageMissing(path: SDKLocator.missingImageAdvice(sdk: sdk))
        }
        return try store.create(preset.makeConfig(id: id, displayName: displayName, systemImage: ref, ports: ports))
    }

    /// Deletes an instance after stopping its engine (graceful, no save).
    public func deleteInstance(_ id: InstanceID) async throws {
        if store.isRunning(id) {
            try await engine(for: id).stop(.graceful(saveQuickBoot: false))
        }
        forget(id)
        try store.delete(id)
    }
}
