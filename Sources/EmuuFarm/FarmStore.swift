import Darwin
import Foundation
import EmuuBase

/// Farm files under `<EMUU_HOME>/farm`:
///
///     farm/goldens/<name>.json        sealed golden images (GoldenRecord)
///     farm/pools/<pool>/state.json    FarmState (the `farm status --json` document)
///     farm/pools/<pool>/state.lock    flock for read-modify-write of state.json
///     farm/pools/<pool>/daemon.lock   held by the pool daemon for its whole life
///     farm/pools/<pool>/daemon.log    daemon output
///     farm/ephemeral/<instance>.json  owner of an `emuu run` clone (EphemeralOwner), for `farm gc`
public struct FarmPaths: Sendable {
    public let root: URL

    public init(paths: EmuuPaths) { root = paths.root.appendingPathComponent("farm", isDirectory: true) }

    public var goldens: URL { root.appendingPathComponent("goldens", isDirectory: true) }
    public var pools: URL { root.appendingPathComponent("pools", isDirectory: true) }
    public var ephemeral: URL { root.appendingPathComponent("ephemeral", isDirectory: true) }
    public func pool(_ name: String) -> URL { pools.appendingPathComponent(name, isDirectory: true) }
    public func stateFile(_ pool: String) -> URL { self.pool(pool).appendingPathComponent("state.json") }
    public func stateLock(_ pool: String) -> URL { self.pool(pool).appendingPathComponent("state.lock") }
    public func daemonLock(_ pool: String) -> URL { self.pool(pool).appendingPathComponent("daemon.lock") }
    public func daemonLog(_ pool: String) -> URL { self.pool(pool).appendingPathComponent("daemon.log") }
    public func golden(_ name: String) -> URL { goldens.appendingPathComponent("\(name).json") }
    public func ephemeralOwner(_ instance: String) -> URL { ephemeral.appendingPathComponent("\(instance).json") }

    public func ensure() throws {
        for d in [root, goldens, pools, ephemeral] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    public func poolNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: pools.path)) ?? []).filter {
            FileManager.default.fileExists(atPath: stateFile($0).path)
        }.sorted()
    }
}

/// An exclusive advisory lock on a file (`flock`), released on `release()` or process exit.
public final class FarmFileLock: @unchecked Sendable {
    private var fd: Int32

    /// Blocks until the lock is held. Throws when the file cannot be opened.
    public init(url: URL, blocking: Bool = true) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw EmuuError.io(path: url.path, message: String(cString: strerror(errno))) }
        while flock(fd, LOCK_EX | (blocking ? 0 : LOCK_NB)) != 0 {
            if errno == EINTR { continue }
            let e = errno
            close(fd)
            fd = -1
            throw e == EWOULDBLOCK ? EmuuError.engine("\(url.lastPathComponent) is held by another process")
                                   : EmuuError.io(path: url.path, message: String(cString: strerror(e)))
        }
    }

    /// Non-blocking: nil when another process holds it.
    public static func tryLock(url: URL) -> FarmFileLock? { try? FarmFileLock(url: url, blocking: false) }

    /// True when some process holds the lock on `url` (probe; does not keep it).
    public static func isHeld(url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let probe = tryLock(url: url) else { return true }
        probe.release()
        return false
    }

    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}

/// Read-modify-write of a pool's state under its flock.
public struct FarmStateStore: Sendable {
    public let farm: FarmPaths
    public let pool: String

    public init(farm: FarmPaths, pool: String) {
        self.farm = farm
        self.pool = pool
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: farm.stateFile(pool).path) }

    public func read() throws -> FarmState {
        let url = farm.stateFile(pool)
        guard let data = try? Data(contentsOf: url) else { throw EmuuError.engine("no farm pool '\(pool)' (run `emuu farm up`)") }
        do { return try FarmJSON.decoder.decode(FarmState.self, from: data) } catch {
            throw EmuuError.parse("\(url.path): \(error)")
        }
    }

    /// Runs `body` on the current state under the lock and writes the result back atomically.
    @discardableResult
    public func update<T>(_ body: (inout FarmState) throws -> T) throws -> T {
        let lock = try FarmFileLock(url: farm.stateLock(pool))
        defer { lock.release() }
        var state = try read()
        let result = try body(&state)
        state.updatedAt = Date()
        try write(state)
        return result
    }

    /// `update` for bodies that await (acquire's pre-lease health check). The flock is per open file, not per
    /// thread, so it stays held across suspension points.
    @discardableResult
    public func updateAsync<T>(_ body: (inout FarmState) async throws -> T) async throws -> T {
        let lock = try FarmFileLock(url: farm.stateLock(pool))
        defer { lock.release() }
        var state = try read()
        let result = try await body(&state)
        state.updatedAt = Date()
        try write(state)
        return result
    }

    /// Creates the state file (fails when one exists and `replace` is false).
    public func create(_ state: FarmState, replace: Bool = false) throws {
        try FileManager.default.createDirectory(at: farm.pool(pool), withIntermediateDirectories: true)
        let lock = try FarmFileLock(url: farm.stateLock(pool))
        defer { lock.release() }
        if !replace, exists { throw EmuuError.engine("farm pool '\(pool)' already exists") }
        try write(state)
    }

    public func remove() {
        try? FileManager.default.removeItem(at: farm.pool(pool))
    }

    private func write(_ state: FarmState) throws {
        let url = farm.stateFile(pool)
        do { try FarmJSON.encoder.encode(state).write(to: url, options: .atomic) } catch {
            throw EmuuError.io(path: url.path, message: error.localizedDescription)
        }
    }
}

public enum FarmJSON {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// Owner of an ephemeral (`emuu run`) clone, so `emuu farm gc` can reclaim it when the owner died.
public struct EphemeralOwner: Codable, Sendable, Hashable {
    public var instance: String
    public var ownerPID: Int32
    public var golden: String
    public var createdAt: Date
    public var keep: Bool = false
    public var consolePort: Int?

    public init(instance: String, ownerPID: Int32, golden: String, createdAt: Date, consolePort: Int? = nil) {
        self.consolePort = consolePort
        self.instance = instance
        self.ownerPID = ownerPID
        self.golden = golden
        self.createdAt = createdAt
    }
}

/// A sealed golden image: an Emuu instance with a quick-boot snapshot that farm clones resume from.
public struct GoldenRecord: Codable, Sendable, Hashable {
    public var name: String
    public var sealedAt: Date
    /// Guest `boot_id` at seal time. Every clone resumes with this exact id (the snapshot holds the running
    /// kernel), so a different id on a farm device means the guest rebooted.
    public var bootID: String?
    public var guestUptimeAtSeal: Double?
    public var guestRAMMB: Int
    public var cores: Int
    public var gpu: String
    public var image: String
    public var lean: Bool
    public var snapshotBytes: UInt64
    public var disabledPackages: [String]

    public init(name: String, sealedAt: Date, bootID: String?, guestUptimeAtSeal: Double?, guestRAMMB: Int, cores: Int,
                gpu: String, image: String, lean: Bool, snapshotBytes: UInt64, disabledPackages: [String]) {
        self.name = name
        self.sealedAt = sealedAt
        self.bootID = bootID
        self.guestUptimeAtSeal = guestUptimeAtSeal
        self.guestRAMMB = guestRAMMB
        self.cores = cores
        self.gpu = gpu
        self.image = image
        self.lean = lean
        self.snapshotBytes = snapshotBytes
        self.disabledPackages = disabledPackages
    }
}

public enum GoldenStore {
    public static func save(_ record: GoldenRecord, farm: FarmPaths) throws {
        try farm.ensure()
        try FarmJSON.encoder.encode(record).write(to: farm.golden(record.name), options: .atomic)
    }

    public static func load(_ name: String, farm: FarmPaths) -> GoldenRecord? {
        guard let data = try? Data(contentsOf: farm.golden(name)) else { return nil }
        return try? FarmJSON.decoder.decode(GoldenRecord.self, from: data)
    }

    public static func list(farm: FarmPaths) -> [GoldenRecord] {
        ((try? FileManager.default.contentsOfDirectory(at: farm.goldens, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .compactMap { try? FarmJSON.decoder.decode(GoldenRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name < $1.name }
    }

    public static func remove(_ name: String, farm: FarmPaths) {
        try? FileManager.default.removeItem(at: farm.golden(name))
    }
}
