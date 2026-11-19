import Darwin
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
            if let existing = try? load(config.id) { try Self.checkSameImage(existing: existing.systemImage, requested: config.systemImage) }
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
            let image = config.systemImage
            change(&config)
            try Self.checkSameImage(existing: image, requested: config.systemImage)
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
                        paths.pidFile(for: id), HibernationMarker.url(for: id, paths: paths), FreezeMarker.url(for: id, paths: paths),
                        CrashMarker.url(for: id, paths: paths),
                        paths.runDirectory.appendingPathComponent("\(id.rawValue).bootid")] where fm.fileExists(atPath: url.path) {
                do { try fm.removeItem(at: url) } catch {
                    throw EmuuError.io(path: url.path, message: error.localizedDescription)
                }
            }
            log.notice("deleted instance \(id)")
        }
    }

    /// Copies `source` to a new instance `target` with APFS clones (`clonefile(2)`: instant, and no extra disk until
    /// either side writes). Refuses while the source runs (copying live qcow2 files corrupts them).
    ///
    /// With `includeSnapshots` the quick-boot snapshot comes along, so the clone resumes the source's exact state.
    /// The engine refuses a snapshot whose `hardware.ini` does not match the launch ("The emulator hardware cannot
    /// load snapshot", measured on 36.4.9 when the disk paths and `avd.name` still named the source), so each
    /// `snapshots/*/hardware.ini` is rewritten for the target. `snapshot.pb` also embeds the source's absolute disk
    /// paths, but the engine does not check them (verified: the clone loads `default_boot` and its writes go to its
    /// own files). Per-launch files (`perLaunchArtifacts`) are not copied.
    @discardableResult
    public func clone(_ source: InstanceID, to target: InstanceID, displayName: String? = nil,
                      includeSnapshots: Bool = false, configure: (inout InstanceConfig) -> Void = { _ in }) throws -> InstanceConfig {
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
                    if Self.perLaunchArtifacts.contains(item) || item.hasSuffix(".lock") || item == "config.ini" { continue }
                    if item == "snapshots" && !includeSnapshots { continue }
                    try Self.cloneItem(srcDir.appendingPathComponent(item), to: dstDir.appendingPathComponent(item))
                }
                if includeSnapshots {
                    try Self.rewriteSnapshotHardware(in: dstDir.appendingPathComponent("snapshots"),
                                                     fromAVD: srcDir.standardizedFileURL.path, toAVD: dstDir.standardizedFileURL.path,
                                                     newID: target.rawValue)
                }
                config.id = target
                config.displayName = displayName ?? target.rawValue
                config.ports = nil
                config.createdAt = Self.wholeSeconds(Date())
                let image = config.systemImage
                configure(&config)
                config.id = target
                // A clone's disks are the source's, so it runs the source's Android version.
                try Self.checkSameImage(existing: image, requested: config.systemImage)
                let tagDisplay = try checkImage(config.systemImage)
                try writeAVDFiles(config, tagDisplay: tagDisplay)
                if includeSnapshots, var ini = try? IniFile(contentsOf: srcDir.appendingPathComponent("config.ini")) {
                    // The snapshot only loads when the hardware matches what the source last ran with. The engine
                    // rewrites config.ini on first boot (measured: `disk.dataPartition.size` 4096M → 6442450944 for
                    // android-36.1), so keep the source's file and change only the identity keys.
                    ini["AvdId"] = target.rawValue
                    ini["avd.ini.displayname"] = config.displayName
                    try ini.write(to: dstDir.appendingPathComponent("config.ini"))
                }
                try Self.encode(config, to: paths.instanceConfigFile(for: target))
            } catch {
                try? fm.removeItem(at: dstDir)
                try? fm.removeItem(at: paths.avdIniFile(for: target))
                try? fm.removeItem(at: paths.instanceConfigFile(for: target))
                if let e = error as? EmuuError { throw e }
                throw EmuuError.io(path: dstDir.path, message: error.localizedDescription)
            }
            log.notice("cloned \(source) -> \(target)\(includeSnapshots ? " (with snapshots)" : "")")
            return config
        }
    }

    /// `clonefile(2)` (copy-on-write, recursive for directories); falls back to a byte copy on volumes without
    /// clone support (non-APFS), which is slow and uses full disk space.
    static func cloneItem(_ src: URL, to dst: URL) throws {
        if Darwin.clonefile(src.path, dst.path, 0) == 0 { return }
        let err = errno
        guard err == ENOTSUP || err == EXDEV else {
            throw EmuuError.io(path: dst.path, message: "clonefile: \(String(cString: strerror(err)))")
        }
        try FileManager.default.copyItem(at: src, to: dst)
    }

    /// True when `directory`'s volume supports APFS clones (`VOL_CAP_INT_CLONE`).
    public static func supportsClones(at directory: URL) -> Bool {
        (try? directory.resourceValues(forKeys: [.volumeSupportsFileCloningKey]).volumeSupportsFileCloning) == true
    }

    static func rewriteSnapshotHardware(in snapshots: URL, fromAVD: String, toAVD: String, newID: String) throws {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: snapshots.path) else { return }
        for name in names {
            let ini = snapshots.appendingPathComponent(name).appendingPathComponent("hardware.ini")
            guard let text = try? String(contentsOf: ini, encoding: .utf8) else { continue }
            let rewritten = rewriteHardwareIni(text, fromAVD: fromAVD, toAVD: toAVD, newID: newID)
            // Replace (not overwrite in place): the file is a clone shared with the source.
            try? fm.removeItem(at: ini)
            try Data(rewritten.utf8).write(to: ini, options: .atomic)
        }
    }

    /// Rewrites a snapshot's `hardware.ini` for a cloned AVD: paths under the source AVD directory and
    /// `avd.name`/`avd.id` (pure; unit-tested).
    public static func rewriteHardwareIni(_ text: String, fromAVD: String, toAVD: String, newID: String) -> String {
        let from = fromAVD.hasSuffix("/") ? fromAVD : fromAVD + "/"
        let to = toAVD.hasSuffix("/") ? toAVD : toAVD + "/"
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { raw -> String in
            let line = String(raw)
            let key = line.split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if key == "avd.name" || key == "avd.id" { return "\(key) = \(newID)" }
            return line.replacingOccurrences(of: from, with: to)
        }.joined(separator: "\n")
    }

    // MARK: Helpers

    /// An instance's Android version cannot change in place: its data partition (and snapshots) were created by
    /// that system image, and booting them with another one fails or corrupts them (pure; unit-tested).
    public static func checkSameImage(existing: SystemImageRef, requested: SystemImageRef) throws {
        guard existing != requested else { return }
        throw EmuuError.invalidConfiguration(
            "an instance's Android version cannot be changed (it runs \(existing.androidLabel), \(existing.sdkManagerPackage)); "
            + "its data partition belongs to that version. Create a new instance with `emuu create <name> --android "
            + "\(requested.androidVersion?.number ?? requested.apiDirectory)` instead")
    }

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

/// `run/<id>.frozen`: present while Emuu itself has frozen the engine (T4, `emuu freeze`). A SIGSTOPped engine
/// *without* this marker was stopped by someone else (or is wedged), which the health check reports as hung.
public enum FreezeMarker {
    public static func url(for id: InstanceID, paths: EmuuPaths) -> URL {
        paths.runDirectory.appendingPathComponent("\(id.rawValue).frozen")
    }

    public static func isSet(for id: InstanceID, paths: EmuuPaths) -> Bool {
        FileManager.default.fileExists(atPath: url(for: id, paths: paths).path)
    }

    public static func set(for id: InstanceID, paths: EmuuPaths) {
        try? FileManager.default.createDirectory(at: paths.runDirectory, withIntermediateDirectories: true)
        try? Data().write(to: url(for: id, paths: paths))
    }

    public static func clear(for id: InstanceID, paths: EmuuPaths) {
        try? FileManager.default.removeItem(at: url(for: id, paths: paths))
    }
}

/// `run/<id>.crashed`: the engine exited without a clean stop (crash, SIGKILL from outside). Holds the reason.
/// Written by whichever Emuu process watched the engine die, cleared by the next successful start, so a later
/// `emuu health` in another process can still report the instance as dead rather than merely stopped.
public enum CrashMarker {
    public static func url(for id: InstanceID, paths: EmuuPaths) -> URL {
        paths.runDirectory.appendingPathComponent("\(id.rawValue).crashed")
    }

    public static func reason(for id: InstanceID, paths: EmuuPaths) -> String? {
        try? String(contentsOf: url(for: id, paths: paths), encoding: .utf8)
    }

    public static func set(for id: InstanceID, paths: EmuuPaths, reason: String) {
        try? FileManager.default.createDirectory(at: paths.runDirectory, withIntermediateDirectories: true)
        try? Data(reason.utf8).write(to: url(for: id, paths: paths), options: .atomic)
    }

    public static func clear(for id: InstanceID, paths: EmuuPaths) {
        try? FileManager.default.removeItem(at: url(for: id, paths: paths))
    }
}
