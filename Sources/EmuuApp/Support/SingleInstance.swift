import AppKit
import Darwin
import Foundation
import EmuuBase

/// Another running app process, as seen at launch.
struct RunningAppInfo: Sendable, Hashable {
    var pid: Int32
    var bundleIdentifier: String?
    var launchDate: Date?
}

/// What a freshly launched Emuu process should do (pure; unit-tested).
enum SingleInstanceDecision: Sendable, Hashable {
    /// This is the only Emuu: run normally.
    case proceed
    /// Another Emuu runs: activate it (forwarding files) and exit.
    case handOff(to: Int32)
}

enum SingleInstancePolicy {
    /// - Parameters:
    ///   - lockAcquired: whether this process got the exclusive `app.lock` (the guarantee: `flock` is released
    ///     by the kernel when its holder dies, so a crash never leaves a stale lock).
    ///   - lockOwnerPID: the pid written into the lock file by its holder.
    ///   - others: other running apps with Emuu's bundle id (for activation; also covers bundle copies).
    static func decide(selfPID: Int32, lockAcquired: Bool, lockOwnerPID: Int32?, others: [RunningAppInfo],
                       bundleIdentifier: String?, isAlive: (Int32) -> Bool) -> SingleInstanceDecision {
        if lockAcquired { return .proceed }
        if let owner = lockOwnerPID, owner != selfPID, isAlive(owner) { return .handOff(to: owner) }
        // Lock held but the pid file is unreadable/stale: hand off to the oldest same-bundle process.
        let candidates = others.filter { $0.pid != selfPID && (bundleIdentifier == nil || $0.bundleIdentifier == bundleIdentifier) }
            .sorted { ($0.launchDate ?? .distantPast, $0.pid) < ($1.launchDate ?? .distantPast, $1.pid) }
        if let first = candidates.first { return .handOff(to: first.pid) }
        // Someone holds the lock but cannot be found (e.g. still starting up): do not start a second app.
        return lockOwnerPID.map { .handOff(to: $0) } ?? .proceed
    }

    /// Install files passed on the command line (`Emuu foo.apk`), forwarded to the running instance.
    static func forwardableFiles(arguments: [String], fileExists: (String) -> Bool) -> [String] {
        arguments.dropFirst().filter { arg in
            guard !arg.hasPrefix("-") else { return false }
            let ext = (arg as NSString).pathExtension.lowercased()
            return InstanceSessionFileTypes.install.contains(ext) && fileExists(arg)
        }.map { ($0 as NSString).standardizingPath }
    }
}

enum InstanceSessionFileTypes {
    static let install: Set<String> = ["apk", "xapk", "apks", "apkm"]
}

/// Holds `~/.emuu/run/app.lock` for the life of the process.
enum SingleInstanceGuard {
    static let activateNotification = Notification.Name("dev.emuu.app.activate")
    nonisolated(unsafe) private static var lockFD: Int32 = -1

    /// Runs before any AppKit app object exists. Returns normally when this process should run.
    static func enforce() {
        let paths = EmuuPaths.default()
        try? FileManager.default.createDirectory(at: paths.runDirectory, withIntermediateDirectories: true)
        let lockURL = paths.runDirectory.appendingPathComponent("app.lock")
        let fd = open(lockURL.path, O_RDWR | O_CREAT, 0o644)
        var acquired = false
        if fd >= 0 {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)   // engines/children must not inherit the app's lock
            acquired = flock(fd, LOCK_EX | LOCK_NB) == 0
        }
        if acquired {
            lockFD = fd
            ftruncate(fd, 0)
            let text = "\(getpid())\n"
            _ = text.withCString { write(fd, $0, strlen($0)) }
            return
        }
        var ownerPID: Int32?
        if fd >= 0 {
            var buf = [UInt8](repeating: 0, count: 32)
            let n = pread(fd, &buf, buf.count - 1, 0)
            if n > 0 { ownerPID = Int32(String(decoding: buf[0..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) }
            close(fd)
        }
        let bundleID = Bundle.main.bundleIdentifier
        let others: [RunningAppInfo] = bundleID.map { id in
            NSRunningApplication.runningApplications(withBundleIdentifier: id).map {
                RunningAppInfo(pid: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier, launchDate: $0.launchDate)
            }
        } ?? []
        let decision = SingleInstancePolicy.decide(selfPID: getpid(), lockAcquired: false, lockOwnerPID: ownerPID, others: others,
                                                   bundleIdentifier: bundleID, isAlive: { kill($0, 0) == 0 || errno == EPERM })
        guard case .handOff(let pid) = decision else { return }
        if ProcessInfo.processInfo.environment["EMUU_APP_SELFTEST"] != nil {
            FileHandle.standardError.write(Data("SELFTEST refused: another Emuu app is running (pid \(pid)); quit it first\n".utf8))
            exit(3)
        }
        let files = SingleInstancePolicy.forwardableFiles(arguments: CommandLine.arguments,
                                                          fileExists: { FileManager.default.fileExists(atPath: $0) })
        // The running app activates itself and opens the files (it listens for this notification).
        DistributedNotificationCenter.default().postNotificationName(
            activateNotification, object: String(pid), userInfo: ["files": files], deliverImmediately: true)
        NSRunningApplication(processIdentifier: pid)?.activate()
        FileHandle.standardError.write(Data("Emuu is already running (pid \(pid)); activated it\(files.isEmpty ? "" : " and forwarded \(files.count) file(s)").\n".utf8))
        exit(0)
    }
}
