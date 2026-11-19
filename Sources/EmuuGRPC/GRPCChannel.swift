import Foundation
import EmuuBase

/// A gRPC status (https://grpc.github.io/grpc/core/md_doc_statuscodes.html).
public struct GRPCStatus: Error, Sendable, Hashable, CustomStringConvertible {
    public var code: Int
    public var message: String

    public init(code: Int, message: String = "") {
        self.code = code
        self.message = message
    }

    public static let ok = GRPCStatus(code: 0)
    public static let cancelledCode = 1
    public static let invalidArgumentCode = 3
    public static let deadlineExceededCode = 4
    public static let failedPreconditionCode = 9
    public static let unimplementedCode = 12
    public static let unavailableCode = 14
    public static let unauthenticatedCode = 16

    public var isOK: Bool { code == 0 }

    public var description: String {
        let names = [0: "OK", 1: "CANCELLED", 2: "UNKNOWN", 3: "INVALID_ARGUMENT", 4: "DEADLINE_EXCEEDED",
                     5: "NOT_FOUND", 7: "PERMISSION_DENIED", 9: "FAILED_PRECONDITION", 12: "UNIMPLEMENTED",
                     13: "INTERNAL", 14: "UNAVAILABLE", 16: "UNAUTHENTICATED"]
        let name = names[code] ?? "code \(code)"
        return message.isEmpty ? "gRPC \(name)" : "gRPC \(name): \(message)"
    }
}

/// One gRPC call on an HTTP/2 stream: reassembles length-prefixed messages and reports the final status.
final class GRPCCall: HTTP2StreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [UInt8] = []
    private var finished = false
    private var httpStatusOK = true
    private let onMessage: @Sendable (ArraySlice<UInt8>) -> Void
    private let onEnd: @Sendable (GRPCStatus) -> Void

    init(onMessage: @escaping @Sendable (ArraySlice<UInt8>) -> Void, onEnd: @escaping @Sendable (GRPCStatus) -> Void) {
        self.onMessage = onMessage
        self.onEnd = onEnd
    }

    /// Ends the call locally (cancel); `onEnd` gets CANCELLED once.
    func finish(_ status: GRPCStatus) {
        let first = lock.withLock { () -> Bool in
            if finished { return false }
            finished = true
            buffer = []
            return true
        }
        if first { onEnd(status) }
    }

    var isFinished: Bool { lock.withLock { finished } }

    func http2Headers(_ fields: [HeaderField], endStream: Bool) {
        if let s = fields.first(where: { $0.name == ":status" }), s.value != "200" { httpStatusOK = false }
        if let code = fields.first(where: { $0.name == "grpc-status" }) {
            let message = fields.first(where: { $0.name == "grpc-message" })?.value.removingPercentEncoding ?? ""
            finish(GRPCStatus(code: Int(code.value) ?? 2, message: message))
        } else if endStream {
            finish(GRPCStatus(code: httpStatusOK ? 2 : GRPCStatus.unavailableCode, message: "stream ended without grpc-status"))
        }
    }

    func http2Data(_ bytes: ArraySlice<UInt8>, endStream: Bool) {
        var messages: [ArraySlice<UInt8>] = []
        lock.withLock {
            guard !finished else { return }
            if buffer.isEmpty, bytes.count >= 5 {
                // Fast path: whole messages in this frame (screenshot metadata, input acks).
                var i = bytes.startIndex
                while bytes.endIndex - i >= 5 {
                    let len = Int(bytes[i + 1]) << 24 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 8 | Int(bytes[i + 4])
                    guard bytes.endIndex - i - 5 >= len else { break }
                    messages.append(bytes[(i + 5)..<(i + 5 + len)])
                    i += 5 + len
                }
                if i < bytes.endIndex { buffer.append(contentsOf: bytes[i...]) }
            } else {
                buffer.append(contentsOf: bytes)
                var i = 0
                while buffer.count - i >= 5 {
                    let len = Int(buffer[i + 1]) << 24 | Int(buffer[i + 2]) << 16 | Int(buffer[i + 3]) << 8 | Int(buffer[i + 4])
                    guard buffer.count - i - 5 >= len else { break }
                    messages.append(ArraySlice(buffer[(i + 5)..<(i + 5 + len)]))
                    i += 5 + len
                }
                if i > 0 { buffer.removeFirst(i) }
            }
        }
        for m in messages { onMessage(m) }
        if endStream { finish(GRPCStatus(code: 2, message: "stream ended without trailers")) }
    }

    func http2Closed(resetCode: UInt32?, error: (any Error)?) {
        if let resetCode {
            finish(GRPCStatus(code: resetCode == 0x8 ? GRPCStatus.cancelledCode : GRPCStatus.unavailableCode,
                              message: "stream reset (HTTP/2 code \(resetCode))"))
        } else {
            finish(GRPCStatus(code: GRPCStatus.unavailableCode, message: error.map { "\($0)" } ?? "connection closed"))
        }
    }
}

/// A running server-streaming or client-streaming call. `cancel()` resets the stream (no more callbacks
/// except the single CANCELLED end).
public final class GRPCStreamHandle: @unchecked Sendable {
    let call: GRPCCall
    let streamID: UInt32
    weak var connection: HTTP2Connection?

    init(call: GRPCCall, streamID: UInt32, connection: HTTP2Connection) {
        self.call = call
        self.streamID = streamID
        self.connection = connection
    }

    public var isFinished: Bool { call.isFinished }

    /// Sends one request message (client streaming).
    public func send(_ message: [UInt8]) throws {
        guard let connection, !call.isFinished else { throw GRPCStatus(code: GRPCStatus.unavailableCode, message: "call finished") }
        try connection.sendData(stream: streamID, GRPCChannel.frame(message), endStream: false)
    }

    /// Half-closes the request side (client streaming).
    public func finishSending() {
        try? connection?.sendData(stream: streamID, [], endStream: true)
    }

    public func cancel() {
        guard !call.isFinished else { return }
        connection?.resetStream(streamID)
        call.finish(GRPCStatus(code: GRPCStatus.cancelledCode, message: "cancelled"))
    }
}

/// gRPC over one `HTTP2Connection` to the emulator's loopback endpoint, with optional bearer-token auth.
/// The token is only ever put in the `authorization` header (encoded never-indexed) and never logged.
public final class GRPCChannel: @unchecked Sendable {
    public let port: UInt16
    private let token: String?
    private let connection: HTTP2Connection
    /// Calls kept alive until they finish (the connection holds delegates weakly).
    private let live = Locked<[ObjectIdentifier: GRPCCall]>([:])

    public init(port: UInt16, token: String?, onClose: (@Sendable (String) -> Void)? = nil) throws {
        self.port = port
        self.token = token
        self.connection = try HTTP2Connection(loopbackPort: port, onClose: onClose)
    }

    public var isClosed: Bool { connection.isClosed }

    public func close() { connection.close() }

    static func frame(_ message: [UInt8]) -> [UInt8] {
        let n = UInt32(message.count)
        return [0, UInt8(n >> 24), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)] + message
    }

    private func headers(_ path: String, timeout: Duration?) -> [HeaderField] {
        var h = [
            HeaderField(":method", "POST"), HeaderField(":scheme", "http"), HeaderField(":path", path),
            HeaderField(":authority", "127.0.0.1:\(port)"), HeaderField("content-type", "application/grpc"),
            HeaderField("te", "trailers"),
        ]
        if let timeout {
            let ms = max(1, timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000)
            h.append(HeaderField("grpc-timeout", "\(ms)m"))
        }
        if let token { h.append(HeaderField("authorization", "Bearer \(token)", sensitive: true)) }
        return h
    }

    private func start(_ path: String, request: [UInt8]?, timeout: Duration?,
                       onMessage: @escaping @Sendable (ArraySlice<UInt8>) -> Void,
                       onEnd: @escaping @Sendable (GRPCStatus) -> Void) throws -> GRPCStreamHandle {
        let box = Locked<GRPCCall?>(nil)
        let call = GRPCCall(onMessage: onMessage, onEnd: { [live] status in
            if let c = box.current { live.withLock { $0[ObjectIdentifier(c)] = nil } }
            onEnd(status)
        })
        box.set(call)
        live.withLock { $0[ObjectIdentifier(call)] = call }
        do {
            let id = try connection.openStream(headers: headers(path, timeout: timeout), endStream: false, delegate: call)
            if let request { try connection.sendData(stream: id, Self.frame(request), endStream: true) }
            return GRPCStreamHandle(call: call, streamID: id, connection: connection)
        } catch {
            live.withLock { $0[ObjectIdentifier(call)] = nil }
            throw GRPCStatus(code: GRPCStatus.unavailableCode, message: "\(error)")
        }
    }

    /// Unary call: one request, one response.
    public func unary(_ path: String, _ request: [UInt8], timeout: Duration? = .seconds(10)) async throws -> [UInt8] {
        let result = Locked<[UInt8]?>(nil)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[UInt8], any Error>) in
            do {
                let handle = try start(path, request: request, timeout: timeout, onMessage: { m in
                    result.set(Array(m))
                }, onEnd: { status in
                    if status.isOK { cont.resume(returning: result.current ?? []) } else { cont.resume(throwing: status) }
                })
                // Client-side deadline too: a SIGSTOPped (frozen) engine cannot answer, not even with
                // DEADLINE_EXCEEDED.
                if let timeout {
                    let ns = timeout.components.seconds * 1_000_000_000 + timeout.components.attoseconds / 1_000_000_000 + 500_000_000
                    DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(ns))) {
                        guard !handle.isFinished else { return }
                        handle.connection?.resetStream(handle.streamID)
                        handle.call.finish(GRPCStatus(code: GRPCStatus.deadlineExceededCode, message: "no answer within \(timeout)"))
                    }
                }
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    /// Server streaming: one request, messages until the server ends or `cancel()`.
    public func serverStream(_ path: String, _ request: [UInt8],
                             onMessage: @escaping @Sendable (ArraySlice<UInt8>) -> Void,
                             onEnd: @escaping @Sendable (GRPCStatus) -> Void) throws -> GRPCStreamHandle {
        try start(path, request: request, timeout: nil, onMessage: onMessage, onEnd: onEnd)
    }

    /// Client streaming: send messages with `handle.send`, close with `finishSending()`.
    public func clientStream(_ path: String, onEnd: @escaping @Sendable (GRPCStatus) -> Void) throws -> GRPCStreamHandle {
        try start(path, request: nil, timeout: nil, onMessage: { _ in }, onEnd: onEnd)
    }
}
