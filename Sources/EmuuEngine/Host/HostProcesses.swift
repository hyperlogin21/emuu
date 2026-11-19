import Darwin
import Foundation
import EmuuBase

/// Read-only view of host processes plus signalling. Lets the engine adopt an engine started by another
/// Emuu process (the CLI is one process per command) and lets tests fake the OS.
public protocol HostProcessInspecting: Sendable {
    /// True while `pid` exists (including zombies-to-be and stopped processes).
    func isAlive(_ pid: Int32) -> Bool
    /// True when `pid` is stopped by a signal (SIGSTOP), i.e. `ps` state `T`.
    func isStopped(_ pid: Int32) -> Bool
    /// argv of `pid` (same user only), nil if unavailable.
    func arguments(of pid: Int32) -> [String]?
    /// Environment of `pid` (same user only), nil if unavailable.
    func environment(of pid: Int32) -> [String: String]?
    /// All pids visible to this user.
    func allPIDs() -> [Int32]
    /// kill(2). Returns false if the process does not exist or may not be signalled.
    @discardableResult func signal(_ pid: Int32, _ signal: Int32) -> Bool
}

extension HostProcessInspecting {
    /// Engine processes (`qemu-system-*` or the `emulator` launcher) running `-avd <id>` with
    /// `ANDROID_AVD_HOME == avdHome`. Processes whose environment cannot be read are matched on argv only
    /// when `requireAVDHome` is false.
    public func enginePIDs(for id: InstanceID, avdHome: URL, requireAVDHome: Bool = true) -> [Int32] {
        let wantedHome = avdHome.standardizedFileURL.path
        return allPIDs().filter { pid in
            guard let argv = arguments(of: pid), let exe = argv.first else { return false }
            let name = (exe as NSString).lastPathComponent
            guard name.hasPrefix("qemu-system") || name == "emulator" else { return false }
            guard let i = argv.firstIndex(of: "-avd"), i + 1 < argv.count, argv[i + 1] == id.rawValue else { return false }
            guard let env = environment(of: pid), let home = env["ANDROID_AVD_HOME"] else { return !requireAVDHome }
            return URL(fileURLWithPath: home).standardizedFileURL.path == wantedHome
        }
    }
}

/// Real implementation over libproc / sysctl.
public struct SystemHostProcesses: HostProcessInspecting {
    public init() {}

    public func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    public func isStopped(_ pid: Int32) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_status == UInt32(SSTOP)
    }

    public func arguments(of pid: Int32) -> [String]? { procArgs(pid)?.argv }

    public func environment(of pid: Int32) -> [String: String]? { procArgs(pid)?.env }

    public func allPIDs() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let n = pids.withUnsafeMutableBufferPointer { buf in
            proc_listallpids(buf.baseAddress, Int32(buf.count * MemoryLayout<Int32>.size))
        }
        guard n > 0 else { return [] }
        return Array(pids.prefix(Int(n))).filter { $0 > 0 }
    }

    @discardableResult
    public func signal(_ pid: Int32, _ signal: Int32) -> Bool {
        guard pid > 0 else { return false }
        return Darwin.kill(pid, signal) == 0
    }

    /// Parses `KERN_PROCARGS2`: argc (Int32), exec path, NULs, argv[argc], env…
    private func procArgs(_ pid: Int32) -> (argv: [String], env: [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var idx = MemoryLayout<Int32>.size
        // Skip exec path.
        while idx < size, buffer[idx] != 0 { idx += 1 }
        while idx < size, buffer[idx] == 0 { idx += 1 }
        var strings: [String] = []
        var start = idx
        while idx < size {
            if buffer[idx] == 0 {
                if idx > start { strings.append(String(decoding: buffer[start..<idx], as: UTF8.self)) }
                else if strings.count >= Int(argc) { break }
                start = idx + 1
            }
            idx += 1
        }
        let argv = Array(strings.prefix(Int(argc)))
        var env: [String: String] = [:]
        for entry in strings.dropFirst(Int(argc)) {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return (argv, env)
    }
}

/// The engine holds an exclusive `flock` on `<avd>/multiinstance.lock` for its whole life; the kernel drops
/// it when the process dies, so this probe never sees a stale lock.
public enum AVDLockProbe {
    public static func lockFile(in avdDirectory: URL) -> URL {
        avdDirectory.appendingPathComponent("multiinstance.lock")
    }

    /// True if some process currently holds the engine lock for this AVD directory.
    public static func isHeld(avdDirectory: URL) -> Bool {
        let path = lockFile(in: avdDirectory).path
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return false } // no lock file: nothing running
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    /// Files the engine leaves behind after a crash that can confuse the next launch.
    /// Only call this when `isHeld` is false.
    public static func staleLockArtifacts(in avdDirectory: URL, fileManager: FileManager = .default) -> [URL] {
        guard let items = try? fileManager.contentsOfDirectory(at: avdDirectory, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { $0.lastPathComponent.hasSuffix(".lock") && $0.lastPathComponent != "multiinstance.lock" }
    }

    /// Removes stale `*.lock` artifacts if no engine holds the AVD. Returns the removed files.
    @discardableResult
    public static func cleanStaleLocks(avdDirectory: URL, fileManager: FileManager = .default) -> [URL] {
        guard !isHeld(avdDirectory: avdDirectory) else { return [] }
        var removed: [URL] = []
        for url in staleLockArtifacts(in: avdDirectory, fileManager: fileManager) {
            if (try? fileManager.removeItem(at: url)) != nil { removed.append(url) }
        }
        return removed
    }
}
