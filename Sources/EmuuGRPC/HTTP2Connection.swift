import Foundation
import Darwin
import EmuuBase

/// Receives one HTTP/2 stream's events. Called on the connection's reader thread: keep it short.
public protocol HTTP2StreamDelegate: AnyObject, Sendable {
    func http2Headers(_ fields: [HeaderField], endStream: Bool)
    func http2Data(_ bytes: ArraySlice<UInt8>, endStream: Bool)
    /// The stream ended abnormally: RST_STREAM from the peer (`resetCode`) or the connection closed.
    func http2Closed(resetCode: UInt32?, error: (any Error)?)
}

public enum HTTP2Error: Error, CustomStringConvertible, Sendable {
    case connectFailed(String)
    case closed(String)
    case protocolError(String)

    public var description: String {
        switch self {
        case .connectFailed(let m): return "connect failed: \(m)"
        case .closed(let m): return "connection closed: \(m)"
        case .protocolError(let m): return "HTTP/2 protocol error: \(m)"
        }
    }
}

/// A minimal HTTP/2 client over cleartext TCP (h2c with prior knowledge), enough for gRPC to the Android
/// Emulator on loopback: streams, HPACK headers, DATA with flow control in both directions, SETTINGS,
/// PING, WINDOW_UPDATE, RST_STREAM and GOAWAY. No server push (disabled in our SETTINGS), no priorities.
///
/// One reader thread per connection blocks in `recv`; writers take a lock and write synchronously (frames
/// are small; loopback). Stream callbacks run on the reader thread.
public final class HTTP2Connection: @unchecked Sendable {
    public static let preface = Array("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
    /// Receive window we grant per stream and (×2) for the connection.
    static let streamReceiveWindow = 8 << 20
    static let connectionReceiveWindow = 16 << 20

    enum FrameType: UInt8 {
        case data = 0, headers = 1, priority = 2, rstStream = 3, settings = 4, pushPromise = 5, ping = 6,
             goAway = 7, windowUpdate = 8, continuation = 9
    }

    private struct StreamState {
        weak var delegate: (any HTTP2StreamDelegate)?
        var sendWindow: Int
        var unacknowledgedReceive = 0
        var localClosed = false
    }

    private let fd: Int32
    public let port: UInt16
    private let lock = NSLock()
    private var streams: [UInt32: StreamState] = [:]
    private var nextStreamID: UInt32 = 1
    private var connectionSendWindow = 65_535
    private var peerInitialWindow = 65_535
    private var peerMaxFrameSize = 16_384
    private var connectionUnacknowledged = 0
    private var pending: [(id: UInt32, bytes: ArraySlice<UInt8>, end: Bool)] = []
    private var closedReason: String?
    private let encoder = HPACKEncoder()
    // Reader-thread only:
    private var decoder = HPACKDecoder()
    private var headerBlock: (id: UInt32, bytes: [UInt8], endStream: Bool)?
    private var onClose: (@Sendable (String) -> Void)?
    private let log = EmuuLogger(category: "grpc.h2")

    /// Connects to 127.0.0.1:`port` and starts the reader thread.
    public init(loopbackPort port: UInt16, onClose: (@Sendable (String) -> Void)? = nil) throws {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw HTTP2Error.connectFailed("socket(): \(String(cString: strerror(errno)))") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw HTTP2Error.connectFailed("127.0.0.1:\(port): \(message)")
        }
        self.fd = fd
        self.port = port
        self.onClose = onClose
        var hello = Self.preface
        // SETTINGS: ENABLE_PUSH=0, INITIAL_WINDOW_SIZE=8 MiB.
        var settings: [UInt8] = []
        Self.appendSetting(id: 0x2, value: 0, to: &settings)
        Self.appendSetting(id: 0x4, value: UInt32(Self.streamReceiveWindow), to: &settings)
        hello += Self.frameHeader(length: settings.count, type: .settings, flags: 0, stream: 0) + settings
        hello += Self.windowUpdateFrame(stream: 0, increment: UInt32(Self.connectionReceiveWindow - 65_535))
        do { try writeRaw(hello) } catch {
            Darwin.close(fd)
            throw HTTP2Error.connectFailed("handshake: \(error)")
        }
        let thread = Thread { [self] in readLoop() }
        thread.name = "emuu.grpc.reader.\(port)"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    deinit {
        Darwin.close(fd)
    }

    public var isClosed: Bool { lock.withLock { closedReason != nil } }

    /// Opens a stream by sending HEADERS. The delegate is held weakly: keep it alive while the stream runs.
    public func openStream(headers: [HeaderField], endStream: Bool, delegate: any HTTP2StreamDelegate) throws -> UInt32 {
        let block = encoder.encode(headers)
        guard block.count <= 16_384 else { throw HTTP2Error.protocolError("header block too large") }
        return try lock.withLock {
            if let r = closedReason { throw HTTP2Error.closed(r) }
            let id = nextStreamID
            nextStreamID += 2
            streams[id] = StreamState(delegate: delegate, sendWindow: peerInitialWindow, localClosed: endStream)
            let flags: UInt8 = 0x4 | (endStream ? 0x1 : 0)   // END_HEADERS
            try writeRawLocked(Self.frameHeader(length: block.count, type: .headers, flags: flags, stream: id) + block)
            return id
        }
    }

    /// Queues DATA (split by frame size and flow-control window; written as the window allows).
    public func sendData(stream id: UInt32, _ bytes: [UInt8], endStream: Bool) throws {
        try lock.withLock {
            if let r = closedReason { throw HTTP2Error.closed(r) }
            guard var s = streams[id], !s.localClosed else { throw HTTP2Error.protocolError("stream \(id) not open for sending") }
            if endStream { s.localClosed = true; streams[id] = s }
            pending.append((id, bytes[...], endStream))
            try flushLocked()
        }
    }

    /// Cancels a stream (RST_STREAM CANCEL). No more callbacks are delivered for it.
    public func resetStream(_ id: UInt32, code: UInt32 = 0x8) {
        lock.withLock {
            guard streams.removeValue(forKey: id) != nil else { return }
            pending.removeAll { $0.id == id }
            guard closedReason == nil else { return }
            var payload: [UInt8] = []
            Self.appendUInt32(code, to: &payload)
            try? writeRawLocked(Self.frameHeader(length: 4, type: .rstStream, flags: 0, stream: id) + payload)
        }
    }

    /// Closes the connection (GOAWAY, then the socket). Open streams get `http2Closed`.
    public func close() {
        let wasOpen = lock.withLock { () -> Bool in
            guard closedReason == nil else { return false }
            var payload: [UInt8] = []
            Self.appendUInt32(0, to: &payload)
            Self.appendUInt32(0, to: &payload)
            try? writeRawLocked(Self.frameHeader(length: 8, type: .goAway, flags: 0, stream: 0) + payload)
            return true
        }
        if wasOpen { Darwin.shutdown(fd, SHUT_RDWR) }
    }

    // MARK: Writing

    private func writeRaw(_ bytes: [UInt8]) throws {
        try lock.withLock { try writeRawLocked(bytes) }
    }

    private func writeRawLocked(_ bytes: [UInt8]) throws {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { raw in Darwin.send(fd, raw.baseAddress! + sent, bytes.count - sent, 0) }
            if n > 0 { sent += n; continue }
            if n < 0, errno == EINTR { continue }
            throw HTTP2Error.closed("send(): \(String(cString: strerror(errno)))")
        }
    }

    private func flushLocked() throws {
        while let first = pending.first {
            guard var s = streams[first.id] else { pending.removeFirst(); continue }
            let allowed = min(connectionSendWindow, s.sendWindow, peerMaxFrameSize)
            if first.bytes.isEmpty {
                try writeRawLocked(Self.frameHeader(length: 0, type: .data, flags: first.end ? 0x1 : 0, stream: first.id))
                pending.removeFirst()
                continue
            }
            guard allowed > 0 else { return }   // wait for WINDOW_UPDATE
            let n = min(allowed, first.bytes.count)
            let chunk = first.bytes.prefix(n)
            let last = n == first.bytes.count
            try writeRawLocked(Self.frameHeader(length: n, type: .data, flags: (last && first.end) ? 0x1 : 0, stream: first.id) + chunk)
            connectionSendWindow -= n
            s.sendWindow -= n
            streams[first.id] = s
            if last { pending.removeFirst() } else { pending[0].bytes = first.bytes.dropFirst(n) }
        }
    }

    // MARK: Reading

    private func readLoop() {
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        var inbox: [UInt8] = []
        inbox.reserveCapacity(128 << 10)
        var start = 0
        var reason = "peer closed the connection"
        loop: while true {
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n < 0 {
                if errno == EINTR { continue }
                reason = "recv(): \(String(cString: strerror(errno)))"
                break
            }
            if n == 0 { break }
            inbox.append(contentsOf: buffer[0..<n])
            while inbox.count - start >= 9 {
                let length = Int(inbox[start]) << 16 | Int(inbox[start + 1]) << 8 | Int(inbox[start + 2])
                guard inbox.count - start >= 9 + length else { break }
                let type = inbox[start + 3], flags = inbox[start + 4]
                let id = (UInt32(inbox[start + 5]) << 24 | UInt32(inbox[start + 6]) << 16
                          | UInt32(inbox[start + 7]) << 8 | UInt32(inbox[start + 8])) & 0x7fff_ffff
                let payload = inbox[(start + 9)..<(start + 9 + length)]
                start += 9 + length
                do {
                    try handleFrame(type: type, flags: flags, stream: id, payload: payload)
                } catch {
                    reason = "\(error)"
                    break loop
                }
            }
            if start > 0 && start >= inbox.count / 2 {
                inbox.removeFirst(start)
                start = 0
            }
        }
        shutdownAll(reason)
    }

    private func shutdownAll(_ reason: String) {
        let (delegates, callback) = lock.withLock { () -> ([any HTTP2StreamDelegate], (@Sendable (String) -> Void)?) in
            if closedReason == nil { closedReason = reason }
            let ds = streams.values.compactMap(\.delegate)
            streams.removeAll()
            pending.removeAll()
            let cb = onClose
            onClose = nil
            return (ds, cb)
        }
        Darwin.shutdown(fd, SHUT_RDWR)
        for d in delegates { d.http2Closed(resetCode: nil, error: HTTP2Error.closed(reason)) }
        callback?(reason)
    }

    private func delegate(for id: UInt32) -> (any HTTP2StreamDelegate)? {
        lock.withLock { streams[id]?.delegate }
    }

    private func handleFrame(type: UInt8, flags: UInt8, stream id: UInt32, payload: ArraySlice<UInt8>) throws {
        if let hb = headerBlock, FrameType(rawValue: type) != .continuation || hb.id != id {
            throw HTTP2Error.protocolError("expected CONTINUATION for stream \(hb.id)")
        }
        switch FrameType(rawValue: type) {
        case .data:
            var body = payload
            if flags & 0x8 != 0 {   // PADDED
                guard let pad = body.first, Int(pad) < body.count else { throw HTTP2Error.protocolError("bad padding") }
                body = body.dropFirst().dropLast(Int(pad))
            }
            let end = flags & 0x1 != 0
            receivedData(id: id, flowControlled: payload.count, endStream: end)
            delegate(for: id)?.http2Data(body, endStream: end)
            if end { lock.withLock { streams[id] = nil } }
        case .headers:
            var body = payload
            var padLength = 0
            if flags & 0x8 != 0 {
                guard let pad = body.first else { throw HTTP2Error.protocolError("bad padding") }
                padLength = Int(pad)
                body = body.dropFirst()
            }
            if flags & 0x20 != 0 { body = body.dropFirst(5) }   // PRIORITY
            guard padLength <= body.count else { throw HTTP2Error.protocolError("bad padding") }
            body = body.dropLast(padLength)
            headerBlock = (id, Array(body), flags & 0x1 != 0)
            if flags & 0x4 != 0 { try finishHeaderBlock() }
        case .continuation:
            guard var hb = headerBlock, hb.id == id else { throw HTTP2Error.protocolError("unexpected CONTINUATION") }
            hb.bytes += payload
            headerBlock = hb
            if flags & 0x4 != 0 { try finishHeaderBlock() }
        case .rstStream:
            let code = payload.count >= 4 ? Self.readUInt32(payload, at: payload.startIndex) : 0
            let d = lock.withLock { () -> (any HTTP2StreamDelegate)? in
                let d = streams[id]?.delegate
                streams[id] = nil
                pending.removeAll { $0.id == id }
                return d
            }
            d?.http2Closed(resetCode: code, error: nil)
        case .settings:
            guard flags & 0x1 == 0 else { return }   // ACK of ours
            try lock.withLock {
                var i = payload.startIndex
                while i + 6 <= payload.endIndex {
                    let key = UInt16(payload[i]) << 8 | UInt16(payload[i + 1])
                    let value = Self.readUInt32(payload, at: i + 2)
                    switch key {
                    case 0x4:
                        let delta = Int(value) - peerInitialWindow
                        peerInitialWindow = Int(value)
                        for k in streams.keys { streams[k]?.sendWindow += delta }
                    case 0x5:
                        peerMaxFrameSize = Int(value)
                    default:
                        break
                    }
                    i += 6
                }
                try writeRawLocked(Self.frameHeader(length: 0, type: .settings, flags: 0x1, stream: 0))
                try flushLocked()
            }
        case .ping:
            guard flags & 0x1 == 0 else { return }
            try writeRaw(Self.frameHeader(length: payload.count, type: .ping, flags: 0x1, stream: 0) + payload)
        case .goAway:
            let code = payload.count >= 8 ? Self.readUInt32(payload, at: payload.startIndex + 4) : 0
            throw HTTP2Error.closed("GOAWAY (error code \(code))")
        case .windowUpdate:
            guard payload.count >= 4 else { return }
            let inc = Int(Self.readUInt32(payload, at: payload.startIndex) & 0x7fff_ffff)
            try lock.withLock {
                if id == 0 { connectionSendWindow += inc } else if streams[id] != nil { streams[id]!.sendWindow += inc }
                try flushLocked()
            }
        case .priority, .pushPromise, .none:
            break
        }
    }

    private func finishHeaderBlock() throws {
        guard let hb = headerBlock else { return }
        headerBlock = nil
        let fields: [HeaderField]
        do { fields = try decoder.decode(hb.bytes) } catch {
            throw HTTP2Error.protocolError("HPACK: \(error)")
        }
        delegate(for: hb.id)?.http2Headers(fields, endStream: hb.endStream)
        if hb.endStream { lock.withLock { streams[hb.id] = nil } }
    }

    /// Returns flow-control credit once enough was consumed (we consume immediately).
    private func receivedData(id: UInt32, flowControlled n: Int, endStream: Bool) {
        guard n > 0 else { return }
        lock.withLock {
            var frames: [UInt8] = []
            connectionUnacknowledged += n
            if connectionUnacknowledged >= Self.connectionReceiveWindow / 4 {
                frames += Self.windowUpdateFrame(stream: 0, increment: UInt32(connectionUnacknowledged))
                connectionUnacknowledged = 0
            }
            if !endStream, var s = streams[id] {
                s.unacknowledgedReceive += n
                if s.unacknowledgedReceive >= Self.streamReceiveWindow / 4 {
                    frames += Self.windowUpdateFrame(stream: id, increment: UInt32(s.unacknowledgedReceive))
                    s.unacknowledgedReceive = 0
                }
                streams[id] = s
            }
            if !frames.isEmpty { try? writeRawLocked(frames) }
        }
    }

    // MARK: Encoding helpers

    static func frameHeader(length: Int, type: FrameType, flags: UInt8, stream: UInt32) -> [UInt8] {
        [UInt8((length >> 16) & 0xff), UInt8((length >> 8) & 0xff), UInt8(length & 0xff), type.rawValue, flags,
         UInt8((stream >> 24) & 0x7f), UInt8((stream >> 16) & 0xff), UInt8((stream >> 8) & 0xff), UInt8(stream & 0xff)]
    }

    static func windowUpdateFrame(stream: UInt32, increment: UInt32) -> [UInt8] {
        var p: [UInt8] = []
        appendUInt32(increment & 0x7fff_ffff, to: &p)
        return frameHeader(length: 4, type: .windowUpdate, flags: 0, stream: stream) + p
    }

    static func appendSetting(id: UInt16, value: UInt32, to out: inout [UInt8]) {
        out.append(UInt8(id >> 8))
        out.append(UInt8(id & 0xff))
        appendUInt32(value, to: &out)
    }

    static func appendUInt32(_ v: UInt32, to out: inout [UInt8]) {
        out += [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    }

    static func readUInt32(_ b: ArraySlice<UInt8>, at i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
}
