import Darwin
import Foundation

// Shared run-state between Emuu front ends (the `emuu` CLI and EmuuApp).
//
// The engine itself is discovered by EmuuEngine (pid file `run/<id>.pid`, process scan, hibernation marker
// `run/<id>.hibernated`). This file adds what the *front ends* need to agree on: which Emuu process is
// currently attached to an instance and whether that process runs the memory governor and/or a display
// stream. Only one process may govern an instance at a time; a second front end attaches read-only
// (it may show the screen and install apps, but must not start a second governor).
//
// File: `~/.emuu/run/<id>.frontend.json` (`RunStateStore.url(for:paths:)`), JSON, written atomically.
// A record whose `ownerPID` is no longer alive is stale and is ignored (and may be deleted by anyone).

/// Which kind of Emuu process owns a run-state record.
public enum RunStateOwnerKind: String, Codable, Sendable, Hashable {
    case app
    case cli
}

/// One front end's claim on a running instance.
public struct InstanceRunState: Codable, Sendable, Hashable {
    public var instanceID: InstanceID
    public var ownerKind: RunStateOwnerKind
    /// Process id of the front end that wrote the record.
    public var ownerPID: Int32
    /// The engine (QEMU) pid when known.
    public var enginePID: Int32?
    /// adb serial of the running engine when known.
    public var serial: DeviceSerial?
    /// True while `ownerPID` runs a MemoryGovernor for this instance.
    public var governorActive: Bool
    /// True while `ownerPID` shows the display (engine framebuffer over gRPC) for this instance.
    public var displayActive: Bool
    /// Governor profile in effect, when governing.
    public var profile: MemoryProfile?
    public var startedAt: Date
    public var updatedAt: Date

    public init(instanceID: InstanceID, ownerKind: RunStateOwnerKind, ownerPID: Int32 = getpid(),
                enginePID: Int32? = nil, serial: DeviceSerial? = nil, governorActive: Bool = false,
                displayActive: Bool = false, profile: MemoryProfile? = nil,
                startedAt: Date = Date(), updatedAt: Date = Date()) {
        self.instanceID = instanceID
        self.ownerKind = ownerKind
        self.ownerPID = ownerPID
        self.enginePID = enginePID
        self.serial = serial
        self.governorActive = governorActive
        self.displayActive = displayActive
        self.profile = profile
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    /// Whether the owning process still exists (`kill(pid, 0)`; EPERM counts as alive).
    public var isOwnerAlive: Bool { RunStateStore.isProcessAlive(ownerPID) }
}

/// Reads/writes `run/<id>.frontend.json`. All functions are synchronous, cheap and thread-safe
/// (atomic file replacement; last writer wins).
public enum RunStateStore {
    public static let fileSuffix = ".frontend.json"

    public static func url(for id: InstanceID, paths: EmuuPaths) -> URL {
        paths.runDirectory.appendingPathComponent("\(id.rawValue)\(fileSuffix)", isDirectory: false)
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// The record for `id`, or nil when absent or unreadable. Stale records (dead owner) are returned too;
    /// check `isOwnerAlive` or use `live(_:paths:)`.
    public static func read(_ id: InstanceID, paths: EmuuPaths) -> InstanceRunState? {
        guard let data = try? Data(contentsOf: url(for: id, paths: paths)) else { return nil }
        return try? decoder().decode(InstanceRunState.self, from: data)
    }

    /// The record for `id` only if its owner is alive.
    public static func live(_ id: InstanceID, paths: EmuuPaths) -> InstanceRunState? {
        guard let s = read(id, paths: paths), s.isOwnerAlive else { return nil }
        return s
    }

    /// Writes the record atomically (creates `run/` when needed).
    public static func write(_ state: InstanceRunState, paths: EmuuPaths) throws {
        let target = url(for: state.instanceID, paths: paths)
        do {
            try FileManager.default.createDirectory(at: paths.runDirectory, withIntermediateDirectories: true)
            try encoder().encode(state).write(to: target, options: .atomic)
        } catch {
            throw EmuuError.io(path: target.path, message: error.localizedDescription)
        }
    }

    /// Removes the record when it belongs to `ownerPID` (default: this process) or is stale.
    /// Returns true when a file was removed.
    @discardableResult
    public static func remove(_ id: InstanceID, paths: EmuuPaths, ownedBy ownerPID: Int32 = getpid()) -> Bool {
        guard let s = read(id, paths: paths) else {
            // Unreadable garbage: remove it.
            return (try? FileManager.default.removeItem(at: url(for: id, paths: paths))) != nil
        }
        guard s.ownerPID == ownerPID || !s.isOwnerAlive else { return false }
        return (try? FileManager.default.removeItem(at: url(for: id, paths: paths))) != nil
    }

    /// All records in `run/` (including stale ones).
    public static func all(paths: EmuuPaths) -> [InstanceRunState] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: paths.runDirectory.path) else { return [] }
        return names.filter { $0.hasSuffix(fileSuffix) }.compactMap { name in
            let raw = String(name.dropLast(fileSuffix.count))
            guard let id = InstanceID(rawValue: raw) else { return nil }
            return read(id, paths: paths)
        }.sorted { $0.instanceID < $1.instanceID }
    }

    /// Another live process that governs `id`, if any (never this process).
    public static func otherGovernor(of id: InstanceID, paths: EmuuPaths, selfPID: Int32 = getpid()) -> InstanceRunState? {
        guard let s = live(id, paths: paths), s.governorActive, s.ownerPID != selfPID else { return nil }
        return s
    }

    /// Deletes every record whose owner is dead. Returns the ids cleaned.
    @discardableResult
    public static func removeStale(paths: EmuuPaths) -> [InstanceID] {
        all(paths: paths).filter { !$0.isOwnerAlive }.compactMap { s in
            (try? FileManager.default.removeItem(at: url(for: s.instanceID, paths: paths))) != nil ? s.instanceID : nil
        }
    }

    public static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
