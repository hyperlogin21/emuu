import Darwin
import Foundation
import EmuuBase

/// Where supervisors publish themselves under `~/.emuu/run`:
/// * `<id>.supervisor.lock` – held with `flock` for the supervisor's lifetime (liveness, pid-reuse safe)
/// * `<id>.supervisor.pid`  – the supervisor pid
/// * `<id>.supervisor.json` – `SupervisorStatus`, rewritten atomically
/// * `<id>.sock`            – control socket (falls back to `/tmp/emuu-<uid>-<hash>.sock` when the path
///                            would not fit in `sun_path`)
/// * `logs/supervisor-<id>.log` – stdout/stderr of a `--detach`ed supervisor
struct SupervisorRegistry: Sendable {
    let paths: EmuuPaths

    func lockFile(for id: InstanceID) -> URL { paths.runDirectory.appendingPathComponent("\(id.rawValue).supervisor.lock") }
    func pidFile(for id: InstanceID) -> URL { paths.runDirectory.appendingPathComponent("\(id.rawValue).supervisor.pid") }
    func statusFile(for id: InstanceID) -> URL { paths.runDirectory.appendingPathComponent("\(id.rawValue).supervisor.json") }
    func logFile(for id: InstanceID) -> URL { paths.logsDirectory.appendingPathComponent("supervisor-\(id.rawValue).log") }
    func samplesFile(for id: InstanceID) -> URL { paths.logsDirectory.appendingPathComponent("memory-\(id.rawValue).csv") }

    func socketPath(for id: InstanceID) -> String {
        Self.socketPath(preferred: paths.runDirectory.appendingPathComponent("\(id.rawValue).sock").path)
    }

    /// The preferred path when it fits in `sun_path`, otherwise a short, stable path in /tmp.
    static func socketPath(preferred: String) -> String {
        if preferred.utf8.count <= UnixSocket.maxPathBytes { return preferred }
        // FNV-1a: stable across runs (unlike Hasher).
        var h: UInt64 = 0xcbf29ce484222325
        for b in preferred.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return "/tmp/emuu-\(getuid())-\(String(h, radix: 16)).sock"
    }

    /// True while some process holds the supervisor lock.
    func isLocked(_ id: InstanceID) -> Bool {
        let fd = open(lockFile(for: id).path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    struct Live: Sendable, Hashable {
        var pid: Int32
        var socketPath: String
        var status: SupervisorStatus?
    }

    /// The running CLI supervisor of `id` (lock held and a published status with a socket), or nil.
    /// The Emuu app takes the same lock while it governs an instance but publishes no socket; such an
    /// instance is controlled directly (see `otherHolder`).
    func liveSupervisor(for id: InstanceID) -> Live? {
        guard isLocked(id), let status = readStatus(id),
              FileManager.default.fileExists(atPath: status.socketPath) else { return nil }
        return Live(pid: status.pid, socketPath: status.socketPath, status: status)
    }

    /// Who holds the lock when it is not a CLI supervisor: the app's `run/<id>.frontend.json`
    /// (`ownerKind`, `ownerPID`), e.g. "the Emuu app (pid 123)". nil when the lock is free.
    func otherHolder(for id: InstanceID) -> String? {
        guard isLocked(id) else { return nil }
        let url = paths.runDirectory.appendingPathComponent("\(id.rawValue).frontend.json")
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let kind = obj["ownerKind"] as? String ?? "front end"
            let pid = (obj["ownerPID"] as? NSNumber).map { " (pid \($0))" } ?? ""
            return (kind == "app" ? "the Emuu app" : kind) + pid
        }
        let pid = (try? String(contentsOf: pidFile(for: id), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return "another Emuu process" + (pid.map { " (pid \($0))" } ?? "")
    }

    func readStatus(_ id: InstanceID) -> SupervisorStatus? {
        guard let data = try? Data(contentsOf: statusFile(for: id)) else { return nil }
        return try? JSONText.decoder.decode(SupervisorStatus.self, from: data)
    }

    func writeStatus(_ status: SupervisorStatus, for id: InstanceID) throws {
        let data = try JSONText.encoder(pretty: true).encode(status)
        try data.write(to: statusFile(for: id), options: .atomic)
    }

    /// Removes the files a supervisor leaves (not the lock file, which another supervisor may hold next).
    func cleanUp(_ id: InstanceID, socketPath: String) {
        try? FileManager.default.removeItem(at: pidFile(for: id))
        try? FileManager.default.removeItem(at: statusFile(for: id))
        unlink(socketPath)
    }
}

/// An exclusive `flock` held for the life of the object.
final class FileLock: @unchecked Sendable {
    let url: URL
    private var fd: Int32

    /// Returns nil when another process holds the lock.
    init?(url: URL) throws {
        self.url = url
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)   // children (engine, adb) must not inherit the lock
        guard fd >= 0 else { throw EmuuError.io(path: url.path, message: String(cString: strerror(errno))) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        self.fd = fd
    }

    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}
