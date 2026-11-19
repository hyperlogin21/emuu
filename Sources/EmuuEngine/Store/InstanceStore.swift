import Foundation
import EmuuBase

/// Creates, lists, updates, clones and deletes Emuu instances. Writes the AVD files directly
/// (`avd/<id>.ini` + `avd/<id>.avd/config.ini`) under `EmuuPaths.avdHome`, plus the
/// `instances/<id>.json` record that is the source of truth.
///
/// Thread-safe: all mutations are serialized by an internal lock. Running-state checks use the engine's
/// own `multiinstance.lock` flock, so they also see engines started by other Emuu processes.
public final class InstanceStore: Sendable {
    public let paths: EmuuPaths
    /// SDK used to check that the system image is installed. nil skips the check (tests, offline listing).
    public let sdk: AndroidSDK?
    private let lock = Locked(())
    private let log = EmuuLogger(category: "instances")

    /// Files the engine regenerates on every launch, or that belong to one specific running engine.
    /// They are not copied by `clone`.
    static let perLaunchArtifacts: Set<String> = [
        "multiinstance.lock", "hardware-qemu.ini", "hardware-qemu.ini.lock", "emu-launch-params.txt",
        "read-snapshot.txt", "bootcompleted.ini", "tmpAdbCmds", "netsim.ini", "snapshot.trace",
    ]

    public init(paths: EmuuPaths, sdk: AndroidSDK?) throws {
        try Self.assertNotUserAndroidHome(paths.avdHome)
        self.paths = paths
        self.sdk = sdk
    }

    /// Emuu must never write into `~/.android/avd`.
    static func assertNotUserAndroidHome(_ avdHome: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let forbidden = home.appendingPathComponent(".android", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = avdHome.standardizedFileURL.resolvingSymlinksInPath().path
        if candidate == forbidden || candidate.hasPrefix(forbidden + "/") {
            throw EmuuError.invalidConfiguration("refusing to use \(candidate): Emuu never writes to ~/.android")
        }
    }

    // MARK: Queries

    public func exists(_ id: InstanceID) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: paths.instanceConfigFile(for: id).path)
            || fm.fileExists(atPath: paths.avdIniFile(for: id).path)
            || fm.fileExists(atPath: paths.avdDirectory(for: id).path)
    }

    /// All instances with a readable record, sorted by id. Unreadable records are logged and skipped.
    public func list() -> [InstanceConfig] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: paths.instancesDirectory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            do { return try Self.decode(url) } catch {
                log.warning("skipping unreadable instance record \(url.lastPathComponent): \(error.localizedDescription)")
                return nil
            }
        }.sorted { $0.id < $1.id }
    }

    public func load(_ id: InstanceID) throws -> InstanceConfig {
        let url = paths.instanceConfigFile(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw EmuuError.instanceNotFound(id) }
        return try Self.decode(url)
    }

    /// True while an engine process holds this instance's AVD.
    public func isRunning(_ id: InstanceID) -> Bool {
        AVDLockProbe.isHeld(avdDirectory: paths.avdDirectory(for: id))
    }

    // MARK: Mutations

    /// Creates a new instance. Throws `instanceAlreadyExists`, `invalidConfiguration`, `systemImageMissing`.
    @discardableResult
    public func create(_ input: InstanceConfig) throws -> InstanceConfig {
        try input.validate()
        var config = input
        config.createdAt = Self.wholeSeconds(input.createdAt) // the record stores ISO-8601 seconds
        return try lock.withLock { _ in
            guard !exists(config.id) else { throw EmuuError.instanceAlreadyExists(config.id) }
            let tagDisplay = try checkImage(config.systemImage)
            try paths.ensureDirectories()
            let avdDir = paths.avdDirectory(for: config.id)
            do {
                try FileManager.default.createDirectory(at: avdDir, withIntermediateDirectories: true)
                try writeAVDFiles(config, tagDisplay: tagDisplay)
                try Self.encode(config, to: paths.instanceConfigFile(for: config.id))
            } catch {
                // Leave nothing half-created behind.
                try? FileManager.default.removeItem(at: avdDir)
                try? FileManager.default.removeItem(at: paths.avdIniFile(for: config.id))
                try? FileManager.default.removeItem(at: paths.instanceConfigFile(for: config.id))
                throw error
            }
            log.notice("created instance \(config.id) (\(config.ramMB) MB, \(config.cores) cores, \(config.systemImage))")
            return config
        }
    }

    /// Rewrites the record and `config.ini` of an existing instance, keeping its userdata and snapshots.
    /// Refuses while the engine runs (the engine reads config.ini only at launch). The id cannot change.
    @discardableResult
    public func update(_ input: InstanceConfig) throws -> InstanceConfig {
        try input.validate()
        var config = input
        config.createdAt = Self.wholeSeconds(input.createdAt)
        return try lock.withLock { _ in
            guard FileManager.default.fileExists(atPath: paths.avdDirectory(for: config.id).path) else {
                throw EmuuError.instanceNotFound(config.id)
            }
            guard !isRunning(config.id) else { throw EmuuError.invalidStateTransition(from: .running, action: "reconfigure") }
            let tagDisplay = try checkImage(config.systemImage)
            try writeAVDFiles(config, tagDisplay: tagDisplay)
            try Self.encode(config, to: paths.instanceConfigFile(for: config.id))
            return config
        }
    }

    /// Changes front-end preferences stored in the record (`automationMode`, `showSoftKeyboard`). They do not
    /// affect `config.ini`, so this is allowed while the engine runs; only the JSON record is rewritten.
    @discardableResult
    public func updatePreferences(_ id: InstanceID, _ change: (inout InstanceConfig) -> Void) throws -> InstanceConfig {
        try lock.withLock { _ in
            var config = try load(id)
            change(&config)
            try Self.encode(config, to: paths.instanceConfigFile(for: id))
            return config
        }
    }

    /// Adopts an AVD directory that exists under `avdHome` but has no Emuu record (e.g. created by an older
    /// build) by writing a record for `config` and regenerating its config.ini. Userdata is kept.
    @discardableResult
    public func adoptOrUpdate(_ config: InstanceConfig) throws -> InstanceConfig {
        if FileManager.default.fileExists(atPath: paths.avdDirectory(for: config.id).path) {
            return try update(config)
        }
        return try create(config)
    }

    /// Deletes everything Emuu has for this instance. Refuses while the engine runs.
    public func delete(_ id: InstanceID) throws {
        try lock.withLock { _ in
            guard exists(id) else { throw EmuuError.instanceNotFound(id) }
            guard !isRunning(id) else { throw EmuuError.invalidStateTransition(from: .running, action: "delete") }
            let fm = FileManager.default
            for url in [paths.avdDirectory(for: id), paths.avdIniFile(for: id), paths.instanceConfigFile(for: id),
                        paths.pidFile(for: id), HibernationMarker.url(for: id, paths: paths)] where fm.fileExists(atPath: url.path) {
                do { try fm.removeItem(at: url) } catch {
                    throw EmuuError.io(path: url.path, message: error.localizedDescription)
                }
            }
            log.notice("deleted instance \(id)")
        }
    }

    /// Copies `source` to a new instance `target`. The userdata overlays are copied with APFS clones
    /// (`FileManager.copyItem` uses clonefile), so this is fast and initially takes no extra disk space.
    /// Snapshots are not copied unless `includeSnapshots` (quick-boot RAM files are large and embed the
    /// source's identity). Refuses while the source runs (copying live qcow2 files corrupts them).
    @discardableResult
    public func clone(_ source: InstanceID, to target: InstanceID, displayName: String? = nil,
                      includeSnapshots: Bool = false) throws -> InstanceConfig {
        try lock.withLock { _ in
            var config = try load(source)
            guard !exists(target) else { throw EmuuError.instanceAlreadyExists(target) }
            guard !isRunning(source) else { throw EmuuError.invalidStateTransition(from: .running, action: "clone") }
            let fm = FileManager.default
            let srcDir = paths.avdDirectory(for: source)
            let dstDir = paths.avdDirectory(for: target)
            do {
                try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
                for item in try fm.contentsOfDirectory(atPath: srcDir.path) {
                    if Self.perLaunchArtifacts.contains(item) || item == "config.ini" { continue }
                    if item == "snapshots" && !includeSnapshots { continue }
                    try fm.copyItem(at: srcDir.appendingPathComponent(item), to: dstDir.appendingPathComponent(item))
                }
                config.id = target
                config.displayName = displayName ?? target.rawValue
                config.ports = nil
                config.createdAt = Self.wholeSeconds(Date())
                let tagDisplay = try checkImage(config.systemImage)
                try writeAVDFiles(config, tagDisplay: tagDisplay)
                try Self.encode(config, to: paths.instanceConfigFile(for: target))
            } catch {
                try? fm.removeItem(at: dstDir)
                try? fm.removeItem(at: paths.avdIniFile(for: target))
                try? fm.removeItem(at: paths.instanceConfigFile(for: target))
                if let e = error as? EmuuError { throw e }
                throw EmuuError.io(path: dstDir.path, message: error.localizedDescription)
            }
            log.notice("cloned \(source) -> \(target)")
            return config
        }
    }

    // MARK: Helpers

    private func checkImage(_ image: SystemImageRef) throws -> String? {
        guard let sdk else { return nil }
        let dir = sdk.directory(for: image)
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("system.img").path)
            || FileManager.default.fileExists(atPath: dir.appendingPathComponent("system").path) else {
            throw EmuuError.systemImageMissing(path: dir.path)
        }
        return SDKLocator.describeImage(ref: image, directory: dir).tagDisplay
    }

    private func writeAVDFiles(_ config: InstanceConfig, tagDisplay: String?) throws {
        let avdDir = paths.avdDirectory(for: config.id)
        try AVDConfigGenerator.configIni(for: config, tagDisplay: tagDisplay)
            .write(to: avdDir.appendingPathComponent("config.ini"))
        try AVDConfigGenerator.pointerIni(for: config, avdDirectory: avdDir).write(to: paths.avdIniFile(for: config.id))
    }

    static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    static func encode(_ config: InstanceConfig, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(config).write(to: url, options: .atomic)
        } catch {
            throw EmuuError.io(path: url.path, message: error.localizedDescription)
        }
    }

    static func decode(_ url: URL) throws -> InstanceConfig {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(InstanceConfig.self, from: Data(contentsOf: url))
        } catch let e as DecodingError {
            throw EmuuError.parse("\(url.lastPathComponent): \(e)")
        } catch {
            throw EmuuError.io(path: url.path, message: error.localizedDescription)
        }
    }
}

/// `run/<id>.hibernated`: present while an instance is hibernated (quick-boot snapshot saved by Emuu,
/// engine not running). Holds the save time as ISO-8601 text.
public enum HibernationMarker {
    public static func url(for id: InstanceID, paths: EmuuPaths) -> URL {
        paths.runDirectory.appendingPathComponent("\(id.rawValue).hibernated")
    }

    public static func isSet(for id: InstanceID, paths: EmuuPaths) -> Bool {
        FileManager.default.fileExists(atPath: url(for: id, paths: paths).path)
    }

    public static func set(for id: InstanceID, paths: EmuuPaths, at date: Date) throws {
        let url = url(for: id, paths: paths)
        do {
            try FileManager.default.createDirectory(at: paths.runDirectory, withIntermediateDirectories: true)
            try Data(ISO8601DateFormatter().string(from: date).utf8).write(to: url, options: .atomic)
        } catch {
            throw EmuuError.io(path: url.path, message: error.localizedDescription)
        }
    }

    public static func clear(for id: InstanceID, paths: EmuuPaths) {
        try? FileManager.default.removeItem(at: url(for: id, paths: paths))
    }
}
