import Darwin
import Foundation
import EmuuBase

/// Interop with the `emuu` CLI's supervisor (`emuu run`), which governs an instance from another process.
///
/// The CLI publishes, under `~/.emuu/run` (see Sources/emuu/Supervisor/SupervisorRegistry.swift):
/// * `<id>.supervisor.lock` — held with `flock` while a supervisor runs,
/// * `<id>.supervisor.json` — its status (pid, socketPath, governor summary),
/// * a unix control socket speaking one JSON request line → one JSON reply line per connection.
///
/// The app uses the same lock as the single "who governs this instance" token:
/// * if a CLI supervisor holds it, the app is display-only and forwards visibility / wake / touch hints over
///   the socket, so the CLI governor never freezes an instance the user is looking at;
/// * otherwise the app takes the lock itself for as long as it governs, so `emuu run` refuses to start a
///   second governor ("already supervised").
/// The JSON is read with `JSONSerialization` on purpose: the app depends only on a few stable keys.
struct CLISupervisorLink: Sendable {
    let id: InstanceID
    let paths: EmuuPaths

    var lockURL: URL { paths.runDirectory.appendingPathComponent("\(id.rawValue).supervisor.lock") }
    var statusURL: URL { paths.runDirectory.appendingPathComponent("\(id.rawValue).supervisor.json") }

    /// True while some process holds the supervisor lock.
    func isLive() -> Bool {
        let fd = open(lockURL.path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    /// The supervisor's published status file, if any.
    func status() -> [String: Any]? {
        guard let data = try? Data(contentsOf: statusURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    var supervisorPID: Int32? { (status()?["pid"] as? NSNumber)?.int32Value }

    var socketPath: String {
        if let p = status()?["socketPath"] as? String, !p.isEmpty { return p }
        return paths.runDirectory.appendingPathComponent("\(id.rawValue).sock").path
    }

    /// Sends one request (`{"command": …}` plus fields) and returns the decoded reply.
    /// Blocking; call off the main actor.
    func send(_ request: [String: Any], timeout: TimeInterval = 10) throws -> [String: Any] {
        let path = socketPath
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EmuuError.io(path: path, message: String(cString: strerror(errno))) }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard bytes.count <= capacity else { throw EmuuError.invalidConfiguration("socket path too long: \(path)") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard rc == 0 else { throw EmuuError.io(path: path, message: "connect: \(String(cString: strerror(errno)))") }

        var payload = try JSONSerialization.data(withJSONObject: request)
        payload.append(0x0A)
        var offset = 0
        while offset < payload.count {
            let n = payload.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: offset), payload.count - offset) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw EmuuError.io(path: path, message: "write: \(String(cString: strerror(errno)))") }
            offset += n
        }
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while reply.count < 4 * 1024 * 1024 {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            if n < 0 { throw EmuuError.io(path: path, message: "read: \(String(cString: strerror(errno)))") }
            if n == 0 { break }
            if let nl = buffer[0..<n].firstIndex(of: 0x0A) {
                reply.append(contentsOf: buffer[0..<nl])
                break
            }
            reply.append(contentsOf: buffer[0..<n])
        }
        guard let obj = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            throw EmuuError.parse("supervisor reply is not a JSON object")
        }
        return obj
    }

    /// Sends a request on a background thread; returns (ok, message).
    func sendAsync(_ request: [String: Any], timeout: TimeInterval = 10) async -> (ok: Bool, message: String?) {
        let link = self
        // JSON dictionaries are not Sendable; round-trip through Data.
        guard let data = try? JSONSerialization.data(withJSONObject: request) else { return (false, "bad request") }
        return await Task.detached {
            do {
                guard let req = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (false, "bad request") }
                let reply = try link.send(req, timeout: timeout)
                return ((reply["ok"] as? Bool) ?? false, reply["message"] as? String)
            } catch {
                return (false, error.localizedDescription)
            }
        }.value
    }
}

/// The app's hold on `<id>.supervisor.lock` while it governs an instance (an exclusive `flock`).
final class GovernorLock: @unchecked Sendable {
    private var fd: Int32

    /// nil when another process (a CLI supervisor) holds the lock.
    init?(url: URL) {
        let fd = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return nil }
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
