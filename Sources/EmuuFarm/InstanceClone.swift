import Darwin
import Foundation
import EmuuBase
import EmuuEngine

// Instance-to-instance clone ("make a copy of `phone` that is already signed in"): `emuu clone-instance` and the
// app's "Clone…" menu item. The copy is made by the farm's machinery (`InstanceStore.clone`: APFS clonefile of the
// AVD, snapshot `hardware.ini` and `config.ini` fix-ups); this file adds the parts an interactive instance needs:
// naming, port choice, the decision what to do with a running source, and an isolation check.

/// Names for a clone: the display name the UI proposes ("phone copy", "phone copy 2", …) and the instance id
/// derived from what the user typed.
public enum CloneNaming {
    /// "phone" → "phone copy"; if a display name or derived id is taken, "phone copy 2", "phone copy 3", ….
    public static func suggestedDisplayName(source: String, existingDisplayNames: Set<String>, existingIDs: Set<String>) -> String {
        let base = "\(source) copy"
        var candidate = base
        var n = 2
        while existingDisplayNames.contains(candidate) || InstanceID.sanitized(from: candidate).map({ existingIDs.contains($0.rawValue) }) == true {
            candidate = "\(base) \(n)"
            n += 1
        }
        return candidate
    }

    /// Instance id for a display name the user typed: sanitized ("phone copy" → "phone_copy"), made unique with
    /// "-2", "-3", … (like "New Instance"). Throws `invalidInstanceID` when nothing usable remains.
    public static func instanceID(forDisplayName name: String, existingIDs: Set<String>) throws -> InstanceID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = InstanceID.sanitized(from: trimmed) else { throw EmuuError.invalidInstanceID(trimmed) }
        var unique = base
        var n = 2
        while existingIDs.contains(unique.rawValue) {
            let suffix = "-\(n)"
            guard let next = InstanceID(rawValue: String(base.rawValue.prefix(64 - suffix.count)) + suffix) else {
                throw EmuuError.invalidInstanceID(trimmed)
            }
            unique = next
            n += 1
        }
        return unique
    }

    /// Checks an explicit (CLI) name: a valid id that is not taken. Returns nil when fine, else the message.
    public static func problem(with name: String, existingIDs: Set<String>) -> String? {
        guard InstanceID.isValid(name) else {
            return "'\(name)' is not a valid instance name (letters, digits, '.', '_', '-'; up to 64; starting with a letter or digit)"
        }
        if existingIDs.contains(name) { return "an instance named '\(name)' exists already" }
        return nil
    }
}

/// What to do with the source before copying it.
///
/// A running engine has guest state that is not on disk (guest page cache, QEMU's qcow2 metadata cache), and the
/// qcow2 files are open for writing: a byte copy of them is not a consistent disk. The engine offers no "flush
/// and keep running" for its disks, but it has a consistent point it writes itself: the quick-boot save on a
/// console `kill` (VM paused, RAM + device state written to `snapshots/default_boot`, the disk state recorded as
/// a qcow2 internal snapshot, files closed). That is Emuu's hibernate. So a running or frozen source is hibernated,
/// copied, and resumed from the same snapshot: the source's apps continue where they were, and the clone
/// resumes from the identical state.
public enum CloneSourcePlan: Equatable, Sendable {
    /// The engine is not running; the files are consistent. Copy them as they are.
    case copyNow
    /// Running/frozen: hibernate, copy, resume (and re-freeze when it was frozen). Needs the user's consent.
    case hibernateCopyResume(refreeze: Bool)
    /// Cannot clone now; the message says why and what to do.
    case refuse(String)

    /// - Parameters:
    ///   - state: the source's engine state.
    ///   - mayPause: the user agreed to pause the source (`--stop-source`, or the app's confirmation).
    ///   - foreignOwner: another front end (CLI supervisor, other app) governs the source and this caller cannot
    ///     route the hibernate/resume through it; nil when this caller can.
    public static func decide(state: InstanceState, mayPause: Bool, foreignOwner: String? = nil, name: String) -> CloneSourcePlan {
        switch state {
        case .stopped, .hibernated:
            return .copyNow
        case .crashed:
            return .refuse("\(name) crashed last time, so its disks may be inconsistent. Start it once and shut it down (or hibernate it), then clone it.")
        case .booting, .stopping, .hibernating:
            return .refuse("\(name) is \(state); wait until it has finished, then clone it.")
        case .running, .frozen:
            if let foreignOwner {
                return .refuse("\(name) is running and governed by \(foreignOwner); hibernate or stop it there first (or use `emuu clone-instance \(name) <new> --stop-source`).")
            }
            guard mayPause else {
                return .refuse("\(name) is running. A running instance cannot be copied consistently (its disks are open and partly in memory). Stop or hibernate it first, or pass --stop-source to hibernate it for the copy and resume it afterwards (its apps continue where they were).")
            }
            return .hibernateCopyResume(refreeze: state == .frozen)
        }
    }
}

/// Console ports for a clone.
public enum ClonePorts {
    /// - `requested`: an explicit console port (CLI `--port`): must be even, within adb's scan range 5554–5584,
    ///   not fixed for another instance and not bound.
    /// - otherwise, when the source has fixed ports, the clone gets its own fixed port: the first free one in
    ///   5554–5584 (`FarmPorts.allocate`) that no other instance has fixed.
    /// - otherwise nil, like the source: the launcher picks a free pair at every start.
    public static func choose(requested: Int?, source: InstancePorts?, fixedByOthers: Set<Int>,
                              isFree: (Int) -> Bool) throws -> InstancePorts? {
        if let requested {
            guard FarmPorts.consolePorts.contains(requested) else {
                throw EmuuError.invalidConfiguration("console port \(requested): use an even port in 5554–5584 (adb only finds emulators there)")
            }
            guard !fixedByOthers.contains(requested) else {
                throw EmuuError.invalidConfiguration("console port \(requested) is already fixed for another instance")
            }
            guard isFree(requested), isFree(requested + 1) else {
                throw EmuuError.invalidConfiguration("console port \(requested) or \(requested + 1) is in use")
            }
            return try InstancePorts(console: requested)
        }
        guard source != nil else { return nil }
        guard let port = FarmPorts.allocate(count: 1, reserved: fixedByOthers, isFree: isFree).first else {
            throw EmuuError.invalidConfiguration("no free console port in 5554–5584 for the clone")
        }
        return try InstancePorts(console: port)
    }
}

/// Result of a clone.
public struct InstanceCloneResult: Sendable {
    public var config: InstanceConfig
    /// Wall time of the file copy (clonefile + fix-ups).
    public var duration: Duration
    /// The volume supports APFS clones (copy-on-write: no extra disk until the copies diverge).
    public var copyOnWrite: Bool
    /// The quick-boot snapshot came along (the clone resumes where the source was).
    public var carriedSnapshot: Bool
    /// Apparent size of the clone's AVD directory (what a byte copy would cost).
    public var apparentBytes: UInt64
}

/// Makes the copy. The source must not be running (see `CloneSourcePlan`); `InstanceStore.clone` checks it again.
public struct InstanceCloner: Sendable {
    public let store: InstanceStore

    public init(store: InstanceStore) { self.store = store }

    /// - `keepSnapshot`: carry the quick-boot snapshot (default; measured resume ≈ seconds instead of a cold boot).
    ///   Without it the clone cold-boots from the copied disks.
    public func clone(_ source: InstanceID, to target: InstanceID, displayName: String?, ports: InstancePorts?,
                      keepSnapshot: Bool = true) throws -> InstanceCloneResult {
        let paths = store.paths
        let snapshot = paths.avdDirectory(for: source).appendingPathComponent("snapshots/default_boot")
        let hasSnapshot = Self.hasUsableSnapshot(snapshot)
        let carry = keepSnapshot && hasSnapshot
        let cow = InstanceStore.supportsClones(at: paths.avdHome)
        let t0 = ContinuousClock.now
        let config = try store.clone(source, to: target, displayName: displayName, includeSnapshots: carry) { c in
            c.ports = ports
            // A clone is an ordinary instance of its own, not a farm device of the source's golden.
            c.goldenSource = nil
            c.discardStateOnExit = nil
        }
        let elapsed = ContinuousClock.now - t0
        let dst = paths.avdDirectory(for: target)
        let shared = Self.sharedFiles(paths.avdDirectory(for: source), dst)
        if !shared.isEmpty {
            // Never leave an instance that writes into the source's files.
            try? store.delete(target)
            throw EmuuError.io(path: dst.path, message: "clone shares files with \(source): \(shared.joined(separator: ", "))")
        }
        return InstanceCloneResult(config: config, duration: elapsed, copyOnWrite: cow, carriedSnapshot: carry,
                                   apparentBytes: Self.apparentSize(dst))
    }

    /// A `default_boot` with metadata and a plausible RAM image (a failed save leaves a stub).
    static func hasUsableSnapshot(_ dir: URL) -> Bool {
        let fm = FileManager.default
        let ram = ((try? fm.attributesOfItem(atPath: dir.appendingPathComponent("ram.bin").path))?[.size] as? NSNumber)?.uint64Value ?? 0
        return ram >= EngineInstance.minimumRAMSnapshotBytes
            && fm.fileExists(atPath: dir.appendingPathComponent("hardware.ini").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("snapshot.pb").path)
    }

    /// Relative paths of regular files that are the *same file* (same inode: hard link) in both directories, or
    /// symlinks in the clone that point into the source. clonefile gives every file its own inode, so this is
    /// empty unless something went wrong.
    public static func sharedFiles(_ source: URL, _ clone: URL) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        let srcRoot = source.standardizedFileURL.resolvingSymlinksInPath().path
        guard let walker = fm.enumerator(atPath: clone.path) else { return [] }
        for case let rel as String in walker {
            let dst = clone.appendingPathComponent(rel).path
            var ds = stat()
            guard lstat(dst, &ds) == 0 else { continue }
            if (ds.st_mode & S_IFMT) == S_IFLNK {
                let target = (try? fm.destinationOfSymbolicLink(atPath: dst)) ?? ""
                let resolved = URL(fileURLWithPath: target, relativeTo: URL(fileURLWithPath: dst).deletingLastPathComponent())
                    .standardizedFileURL.resolvingSymlinksInPath().path
                if resolved == srcRoot || resolved.hasPrefix(srcRoot + "/") { out.append(rel) }
                continue
            }
            var ss = stat()
            if lstat(source.appendingPathComponent(rel).path, &ss) == 0, ss.st_dev == ds.st_dev, ss.st_ino == ds.st_ino {
                out.append(rel)
            }
        }
        return out.sorted()
    }

    /// Sum of the regular files' sizes under `dir` (what a byte copy would take).
    public static func apparentSize(_ dir: URL) -> UInt64 {
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: UInt64 = 0
        for case let url as URL in walker {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += UInt64(v?.fileSize ?? 0) }
        }
        return total
    }
}
