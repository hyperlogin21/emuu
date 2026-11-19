import Foundation
import Darwin
import EmuuBase

/// Errors raised by the socket layer. Mapped to `EmuuError` at the public API.
enum ADBSocketError: Error, Sendable, Equatable {
    /// Nothing listens on the adb server port (server not started).
    case connectionRefused
    case connectFailed(String)
    case timedOut
    /// Peer closed the stream before the expected number of bytes arrived.
    case unexpectedEOF
    case io(String)
    case cancelled
}

/// A blocking TCP socket to the adb server with deadline-based I/O (via `poll`).
///
/// All calls block the calling thread; `ADBIO.perform` runs them on a dedicated dispatch queue so
/// the Swift cooperative pool is never blocked. `cancel()` may be called from any thread: it shuts
/// the socket down so a blocked `poll` wakes up and the operation throws `.cancelled`.
final class ADBSocket: @unchecked Sendable {
    private let fd: Int32
    private let cancelledFlag = Locked(false)
    private let closedFlag = Locked(false)

    init() throws {
        let s = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { throw ADBSocketError.io("socket(): \(String(cString: strerror(errno)))") }
        fd = s
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    deinit { close() }

    var isCancelled: Bool { cancelledFlag.current }

    func cancel() {
        cancelledFlag.set(true)
        if !closedFlag.current { Darwin.shutdown(fd, SHUT_RDWR) }
    }

    func close() {
        let wasClosed = closedFlag.withLock { c -> Bool in
            defer { c = true }
            return c
        }
        if !wasClosed { Darwin.close(fd) }
    }

    /// Connects to an IPv4 address (`127.0.0.1` for the adb server).
    func connect(host: String, port: UInt16, deadline: ContinuousClock.Instant) throws {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host == "localhost" ? "127.0.0.1" : host, &addr.sin_addr) == 1 else {
            throw ADBSocketError.connectFailed("invalid IPv4 address \(host)")
        }
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc == 0 { return }
        let err = errno
        if err == ECONNREFUSED { throw ADBSocketError.connectionRefused }
        guard err == EINPROGRESS else { throw ADBSocketError.connectFailed(String(cString: strerror(err))) }
        try waitFor(events: Int16(POLLOUT), deadline: deadline)
        var soErr: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
        if soErr == ECONNREFUSED { throw ADBSocketError.connectionRefused }
        if soErr != 0 { throw ADBSocketError.connectFailed(String(cString: strerror(soErr))) }
    }

    private func waitFor(events: Int16, deadline: ContinuousClock.Instant?) throws {
        while true {
            if isCancelled { throw ADBSocketError.cancelled }
            var timeoutMS: Int32 = -1
            if let deadline {
                let remaining = deadline - ContinuousClock.now
                if remaining <= .zero { throw ADBSocketError.timedOut }
                // Wake at least every 250 ms to observe cancellation even if shutdown() is missed.
                timeoutMS = Int32(min(250, max(1, remaining.timeInterval * 1000)))
            } else {
                timeoutMS = 250
            }
            var pfd = pollfd(fd: fd, events: events, revents: 0)
            let rc = Darwin.poll(&pfd, 1, timeoutMS)
            if rc < 0 {
                if errno == EINTR { continue }
                throw ADBSocketError.io("poll: \(String(cString: strerror(errno)))")
            }
            if rc == 0 { continue }
            if isCancelled { throw ADBSocketError.cancelled }
            return  // readable/writable/HUP/ERR: let the read/write report the condition
        }
    }

    /// Writes all bytes or throws.
    func write(_ data: Data, deadline: ContinuousClock.Instant?) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base + offset, raw.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0 && (errno == EAGAIN || errno == EINTR) {
                    try waitFor(events: Int16(POLLOUT), deadline: deadline)
                    continue
                }
                if isCancelled { throw ADBSocketError.cancelled }
                throw ADBSocketError.io("write: \(String(cString: strerror(errno)))")
            }
        }
    }

    /// Reads up to `max` bytes. Returns empty Data on EOF.
    func readSome(max: Int, deadline: ContinuousClock.Instant?) throws -> Data {
        var buffer = Data(count: max)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, max) }
            if n > 0 { buffer.count = n; return buffer }
            if n == 0 {
                if isCancelled { throw ADBSocketError.cancelled }
                return Data()
            }
            if errno == EAGAIN || errno == EINTR {
                try waitFor(events: Int16(POLLIN), deadline: deadline)
                continue
            }
            if isCancelled { throw ADBSocketError.cancelled }
            if errno == ECONNRESET { return Data() }
            throw ADBSocketError.io("read: \(String(cString: strerror(errno)))")
        }
    }

    /// Reads exactly `count` bytes or throws `.unexpectedEOF`.
    func readExactly(_ count: Int, deadline: ContinuousClock.Instant?) throws -> Data {
        var out = Data()
        out.reserveCapacity(count)
        while out.count < count {
            let chunk = try readSome(max: count - out.count, deadline: deadline)
            if chunk.isEmpty { throw ADBSocketError.unexpectedEOF }
            out.append(chunk)
        }
        return out
    }

    /// Reads until EOF, keeping at most `limit` bytes (the newest are dropped once the limit is reached).
    func readToEnd(deadline: ContinuousClock.Instant?, limit: Int = 64 * 1024 * 1024) throws -> Data {
        var out = Data()
        while true {
            let chunk = try readSome(max: 64 * 1024, deadline: deadline)
            if chunk.isEmpty { return out }
            if out.count < limit { out.append(chunk.prefix(limit - out.count)) }
        }
    }
}

/// Runs blocking socket work off the cooperative thread pool, with task cancellation wired to the socket.
enum ADBIO {
    private static let queue = DispatchQueue(label: "dev.emuu.adb.io", qos: .utility, attributes: .concurrent)

    static func perform<T: Sendable>(socket: ADBSocket, _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                queue.async {
                    cont.resume(with: Result { try body() })
                }
            }
        } onCancel: {
            socket.cancel()
        }
    }
}
