import Foundation
import EmuuBase

/// Where an engine's gRPC endpoint is and how to authenticate. `description` never shows the token.
public struct EmulatorGRPCEndpoint: Sendable, Hashable, CustomStringConvertible {
    public var port: UInt16
    public var token: String?

    public init(port: UInt16, token: String?) {
        self.port = port
        self.token = token
    }

    public var description: String { "127.0.0.1:\(port) (\(token == nil ? "no token" : "token auth"))" }
}

/// Reads the emulator's discovery file (`pid_<pid>.ini`), which the engine writes for Android Studio:
/// `grpc.port`, `grpc.token` (with `-grpc-use-token`). Verified on 36.4.9: the file is
/// `~/Library/Caches/TemporaryItems/avd/running/pid_<qemu pid>.ini` (the console's `avd discoverypath` prints
/// the same path) and has no `grpc.*` keys when the engine runs without `-grpc`.
public enum EmulatorDiscovery {
    public static func directory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Caches/TemporaryItems/avd/running", isDirectory: true)
    }

    public static func file(forPID pid: Int32, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        directory(home: home).appendingPathComponent("pid_\(pid).ini")
    }

    /// Parses `key=value` lines.
    public static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            out[String(line[..<eq]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: eq)...])
        }
        return out
    }

    public static func endpoint(fromDiscovery values: [String: String]) -> EmulatorGRPCEndpoint? {
        guard let p = values["grpc.port"].flatMap({ UInt16($0) }), p > 0 else { return nil }
        let token = values["grpc.token"].flatMap { $0.isEmpty ? nil : $0 }
        return EmulatorGRPCEndpoint(port: p, token: token)
    }

    /// The endpoint of the engine with QEMU pid `pid`, or nil (no discovery file yet, or no gRPC).
    public static func endpoint(forPID pid: Int32, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> EmulatorGRPCEndpoint? {
        guard let text = try? String(contentsOf: file(forPID: pid, home: home), encoding: .utf8) else { return nil }
        return endpoint(fromDiscovery: parse(text))
    }
}

/// Typed client for `android.emulation.control.EmulatorController` over one HTTP/2 connection.
/// Thread-safe; calls can be made from any thread/task.
public final class EmulatorController: @unchecked Sendable {
    public static let service = "/android.emulation.control.EmulatorController/"
    public let endpoint: EmulatorGRPCEndpoint
    let channel: GRPCChannel

    /// Connects (loopback TCP + HTTP/2 handshake). `onClose` fires once when the connection drops.
    public init(endpoint: EmulatorGRPCEndpoint, onClose: (@Sendable (String) -> Void)? = nil) throws {
        self.endpoint = endpoint
        self.channel = try GRPCChannel(port: endpoint.port, token: endpoint.token, onClose: onClose)
    }

    public var isClosed: Bool { channel.isClosed }
    public func close() { channel.close() }

    public func status(timeout: Duration = .seconds(5)) async throws -> EmulatorStatus {
        try EmulatorStatus.decode(try await channel.unary(Self.service + "getStatus", [], timeout: timeout)[...])
    }

    /// One frame. PNG comes compressed by the emulator (for screenshots); RGBA inline otherwise.
    public func screenshot(_ format: EmulatorImageFormat, timeout: Duration = .seconds(15)) async throws -> EmulatorImage {
        let reply = try await channel.unary(Self.service + "getScreenshot", format.encoded(), timeout: timeout)
        return try EmulatorImage.decode(reply[...])
    }

    /// Frames as the guest produces them (only on change). `onImage` runs on the connection's reader
    /// thread and must not block for long.
    public func streamScreenshots(_ format: EmulatorImageFormat,
                                  onImage: @escaping @Sendable (EmulatorImage) -> Void,
                                  onEnd: @escaping @Sendable (GRPCStatus) -> Void) throws -> GRPCStreamHandle {
        try channel.serverStream(Self.service + "streamScreenshot", format.encoded(), onMessage: { m in
            if let image = try? EmulatorImage.decode(m) { onImage(image) }
        }, onEnd: onEnd)
    }

    /// An ordered input stream (`streamInputEvent`): send `EmulatorInputEvent.encoded()` messages on it.
    public func openInputStream(onEnd: @escaping @Sendable (GRPCStatus) -> Void) throws -> GRPCStreamHandle {
        try channel.clientStream(Self.service + "streamInputEvent", onEnd: onEnd)
    }

    public func sendKey(_ event: EmulatorKeyEvent) async throws {
        var w = ProtoWriter()
        event.encode(into: &w)
        _ = try await channel.unary(Self.service + "sendKey", w.bytes)
    }

    public func sendTouch(_ touches: [EmulatorTouch], display: Int = 0) async throws {
        var w = ProtoWriter()
        EmulatorInputEvent.encodeTouches(touches, display: display, into: &w)
        _ = try await channel.unary(Self.service + "sendTouch", w.bytes)
    }

    public func setClipboard(_ text: String) async throws {
        _ = try await channel.unary(Self.service + "setClipboard", EmulatorClipData.encode(text))
    }

    public func clipboard() async throws -> String {
        try EmulatorClipData.decode(try await channel.unary(Self.service + "getClipboard", [])[...])
    }

    /// Guest clipboard changes (the first message is the current content).
    public func streamClipboard(onText: @escaping @Sendable (String) -> Void,
                                onEnd: @escaping @Sendable (GRPCStatus) -> Void) throws -> GRPCStreamHandle {
        try channel.serverStream(Self.service + "streamClipboard", [], onMessage: { m in
            if let t = try? EmulatorClipData.decode(m) { onText(t) }
        }, onEnd: onEnd)
    }

    /// Physically rotates the virtual device (accelerometer/gyro/orientation sensors, like the emulator's
    /// rotate buttons); Android follows when auto-rotate is on.
    public func setRotation(_ value: EmulatorRotationValue) async throws {
        _ = try await channel.unary(Self.service + "setPhysicalModel", value.encoded())
    }

    public func rotation() async throws -> EmulatorRotationValue {
        var w = ProtoWriter()
        w.int(1, 1)
        return try EmulatorRotationValue.decode(try await channel.unary(Self.service + "getPhysicalModel", w.bytes)[...])
    }
}
