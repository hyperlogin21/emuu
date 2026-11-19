import Darwin
import Foundation
import EmuuBase

/// Unix-domain stream socket helpers (blocking POSIX; one request per connection).
enum UnixSocket {
    /// `sun_path` capacity on Darwin (104 bytes including the NUL).
    static let maxPathBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count <= maxPathBytes else {
            throw EmuuError.invalidConfiguration("socket path too long (\(bytes.count) > \(maxPathBytes) bytes): \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    static func setTimeouts(_ fd: Int32, _ timeout: Duration) {
        let secs = max(0.05, timeout.timeInterval)
        var tv = timeval(tv_sec: Int(secs), tv_usec: Int32((secs - floor(secs)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
    }

    /// Reads until a newline (or EOF). nil on timeout/error or when `limit` bytes pass without a newline.
    static func readLine(_ fd: Int32, limit: Int = 16 * 1024 * 1024) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while buffer.count < limit {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { return buffer.isEmpty ? nil : buffer }
            if let nl = chunk[0..<n].firstIndex(of: 0x0A) {
                buffer.append(contentsOf: chunk[0..<nl])
                return buffer
            }
            buffer.append(contentsOf: chunk[0..<n])
        }
        return nil
    }
}

/// Supervisor side: accepts connections on a background thread and answers each with `handler`.
final class ControlServer: @unchecked Sendable {
    typealias Handler = @Sendable (ControlRequest) async -> ControlReply

    let socketPath: String
    private let handler: Handler
    private let fd: Int32
    private let closed = Locked(false)
    private let log = EmuuLogger(category: "cli.control")

    init(socketPath: String, handler: @escaping Handler) throws {
        self.socketPath = socketPath
        self.handler = handler
        var addr = try UnixSocket.address(socketPath)
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EmuuError.io(path: socketPath, message: String(cString: strerror(errno))) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            let msg = String(cString: strerror(errno))
            Darwin.close(fd)
            throw EmuuError.io(path: socketPath, message: "bind/listen failed: \(msg)")
        }
        chmod(socketPath, 0o600)
        self.fd = fd
        let thread = Thread { [self] in acceptLoop() }
        thread.name = "emuu.control.accept"
        thread.start()
    }

    deinit { close() }

    func close() {
        let already = closed.withLock { c -> Bool in
            defer { c = true }
            return c
        }
        guard !already else { return }
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        unlink(socketPath)
    }

    private func acceptLoop() {
        while !closed.current {
            let client = accept(fd, nil, nil)
            if client >= 0 { _ = fcntl(client, F_SETFD, FD_CLOEXEC) }
            if client < 0 {
                if errno == EINTR { continue }
                if closed.current { return }
                log.warning("accept failed: \(String(cString: strerror(errno)))")
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }
            UnixSocket.setTimeouts(client, .seconds(10))
            let handler = self.handler
            let log = self.log
            DispatchQueue.global().async {
                guard let line = UnixSocket.readLine(client, limit: 64 * 1024) else {
                    Darwin.close(client)
                    return
                }
                let request: ControlRequest
                do {
                    request = try JSONText.decoder.decode(ControlRequest.self, from: line)
                } catch {
                    _ = UnixSocket.writeAll(client, Self.encode(.failure("bad request: \(error)")))
                    Darwin.close(client)
                    return
                }
                Task {
                    let reply = await handler(request)
                    // Long operations (hibernate/stop) can outlive the 10 s default; replies are small.
                    UnixSocket.setTimeouts(client, .seconds(30))
                    if !UnixSocket.writeAll(client, Self.encode(reply)) {
                        log.notice("control client went away before the \(request.command.rawValue) reply")
                    }
                    Darwin.close(client)
                }
            }
        }
    }

    static func encode(_ reply: ControlReply) -> Data {
        var data = (try? JSONText.encoder(pretty: false).encode(reply)) ?? Data(#"{"ok":false,"message":"encode failed"}"#.utf8)
        data.append(0x0A)
        return data
    }
}

/// Client side: one blocking request/reply.
struct ControlClient: Sendable {
    let socketPath: String

    /// Sends on a GCD thread, so callers on the cooperative pool never block it (a blocked pool can starve
    /// an in-process server's handler tasks).
    func send(_ request: ControlRequest, timeout: Duration = .seconds(10)) async throws -> ControlReply {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                cont.resume(with: Result { try sendBlocking(request, timeout: timeout) })
            }
        }
    }

    func sendBlocking(_ request: ControlRequest, timeout: Duration = .seconds(10)) throws -> ControlReply {
        var addr = try UnixSocket.address(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EmuuError.io(path: socketPath, message: String(cString: strerror(errno))) }
        defer { close(fd) }
        UnixSocket.setTimeouts(fd, timeout)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else {
            throw EmuuError.io(path: socketPath, message: "cannot connect to supervisor: \(String(cString: strerror(errno)))")
        }
        var payload = try JSONText.encoder(pretty: false).encode(request)
        payload.append(0x0A)
        guard UnixSocket.writeAll(fd, payload) else {
            throw EmuuError.io(path: socketPath, message: "write failed: \(String(cString: strerror(errno)))")
        }
        guard let line = UnixSocket.readLine(fd) else {
            throw EmuuError.processTimedOut(command: "supervisor \(request.command.rawValue)", timeout: timeout)
        }
        do {
            return try JSONText.decoder.decode(ControlReply.self, from: line)
        } catch {
            throw EmuuError.parse("supervisor reply: \(error)")
        }
    }
}
