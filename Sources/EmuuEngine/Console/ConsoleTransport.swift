import Darwin
import Foundation
import EmuuBase

/// Byte stream to an emulator console. Abstracted so the client can be tested without an engine.
public protocol ConsoleTransport: AnyObject, Sendable {
    func send(_ data: Data) async throws
    /// Next chunk of bytes; nil on EOF. Throws `EmuuError.console` on timeout.
    func receive(timeout: Duration) async throws -> Data?
    func close()
}

/// Opens console connections.
public protocol ConsoleConnector: Sendable {
    func connect(port: Int, timeout: Duration) async throws -> any ConsoleTransport
}

/// Plain TCP to 127.0.0.1:<port> over POSIX sockets. Blocking calls run on a private queue, never on the
/// cooperative pool.
public struct TCPConsoleConnector: ConsoleConnector {
    public init() {}

    public func connect(port: Int, timeout: Duration) async throws -> any ConsoleTransport {
        try await TCPConsoleTransport.open(port: port, timeout: timeout)
    }
}

public final class TCPConsoleTransport: ConsoleTransport, @unchecked Sendable {
    private let fd: Int32
    private let queue = DispatchQueue(label: "dev.emuu.console.socket")
    private let closed = Locked(false)

    private init(fd: Int32) { self.fd = fd }

    deinit { close() }

    static func open(port: Int, timeout: Duration) async throws -> TCPConsoleTransport {
        let queue = DispatchQueue(label: "dev.emuu.console.connect")
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: TCPConsoleTransport(fd: try connectSocket(port: port, timeout: timeout))) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    private static func connectSocket(port: Int, timeout: Duration) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EmuuError.console("socket(): \(String(cString: strerror(errno)))") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc != 0 {
            guard errno == EINPROGRESS else {
                let msg = String(cString: strerror(errno))
                Darwin.close(fd)
                throw EmuuError.console("connect to port \(port): \(msg)")
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pfd, 1, Int32(timeout.timeInterval * 1000))
            var soError: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
            guard ready == 1, soError == 0 else {
                Darwin.close(fd)
                let why = ready == 0 ? "timed out" : String(cString: strerror(soError == 0 ? errno : soError))
                throw EmuuError.console("connect to port \(port): \(why)")
            }
        }
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        return fd
    }

    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard !closed.current else { return cont.resume(throwing: EmuuError.console("connection closed")) }
                var offset = 0
                let ok: Bool = data.withUnsafeBytes { raw in
                    while offset < raw.count {
                        let n = Darwin.send(fd, raw.baseAddress! + offset, raw.count - offset, 0)
                        if n < 0 { if errno == EINTR { continue }; return false }
                        offset += n
                    }
                    return true
                }
                ok ? cont.resume() : cont.resume(throwing: EmuuError.console("send: \(String(cString: strerror(errno)))"))
            }
        }
    }

    public func receive(timeout: Duration) async throws -> Data? {
        try await withCheckedThrowingContinuation { cont in
            queue.async { [self] in
                guard !closed.current else { return cont.resume(returning: nil) }
                // Still open here, and close(fd) is queued behind this block, so fd cannot be reused under us.
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, Int32(max(1, timeout.timeInterval * 1000)))
                if ready == 0 { return cont.resume(throwing: EmuuError.console("no reply within \(timeout)")) }
                if ready < 0 { return cont.resume(throwing: EmuuError.console("poll: \(String(cString: strerror(errno)))")) }
                var buf = [UInt8](repeating: 0, count: 16 * 1024)
                let n = recv(fd, &buf, buf.count, 0)
                if n > 0 { cont.resume(returning: Data(buf[0..<n])) }
                else if n == 0 { cont.resume(returning: nil) }
                else { cont.resume(throwing: EmuuError.console("recv: \(String(cString: strerror(errno)))")) }
            }
        }
    }

    /// `shutdown()` right away (wakes a `poll`/`recv` blocked on the queue with EOF), but `close(fd)` only on the
    /// transport's own serial queue, after any in-flight send/receive: closing underneath a blocked syscall would
    /// free the fd number for reuse while that syscall (or the next queued one) still uses it, so it could read
    /// from or write to an unrelated socket (e.g. an adb connection) that got the same number.
    public func close() {
        let wasOpen = closed.withLock { c -> Bool in
            defer { c = true }
            return !c
        }
        guard wasOpen else { return }
        let fd = self.fd
        Darwin.shutdown(fd, SHUT_RDWR)
        queue.async { Darwin.close(fd) }
    }
}
