import Foundation
import EmuuBase

/// Where the adb server listens. Honors `ANDROID_ADB_SERVER_PORT` like the adb binary does.
public struct ADBServerEndpoint: Sendable, Hashable {
    public var host: String
    public var port: UInt16

    public init(host: String = "127.0.0.1", port: UInt16 = 5037) {
        self.host = host
        self.port = port
    }

    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> ADBServerEndpoint {
        if let raw = environment["ANDROID_ADB_SERVER_PORT"], let port = UInt16(raw) {
            return ADBServerEndpoint(port: port)
        }
        return ADBServerEndpoint()
    }
}

/// Protocol-level failures (internal; mapped to `EmuuError` at the API).
enum ADBProtocolError: Error, Sendable, Equatable {
    /// The server answered `FAIL` with this message.
    case fail(String)
    case malformed(String)
}

/// Finds the adb binary: SDK copies (in `SDKDiscovery` order), then `SDKDiscovery.fallbackADBPaths`, then PATH.
public enum ADBLocator {
    public static func candidates(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        SDKDiscovery.candidateRoots(environment: environment, home: home).map(SDKDiscovery.adbBinary(in:))
            + SDKDiscovery.fallbackADBPaths.map { URL(fileURLWithPath: $0) }
    }

    public static func find(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        for url in candidates(environment: environment, home: home) where fileManager.isExecutableFile(atPath: url.path) {
            return url
        }
        return ExecutableLocator.find("adb", environment: environment)
    }

    public static func require(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        if let url = find(environment: environment) { return url }
        throw EmuuError.toolNotFound(name: "adb", searched: candidates(environment: environment).map(\.path) + ["$PATH"])
    }
}

/// Client for the host-side adb server (`127.0.0.1:5037`).
///
/// Every request opens a short-lived TCP connection to the already-running server, so polling costs
/// one localhost connect instead of a process spawn. If nothing listens, the server is started once
/// with `adb start-server` (through `ProcessRunner`) and the request is retried. The server is never
/// killed by Emuu (other tools such as Android Studio share it).
public final class ADBServer: Sendable {
    public let endpoint: ADBServerEndpoint
    /// adb binary used to start the server and for binary fallbacks. nil = no binary fallback.
    public let adbExecutable: URL?
    let runner: any ProcessRunner
    let connectTimeout: Duration
    private let starter = ServerStarter()
    private let log = EmuuLogger(category: "adb")

    public init(
        endpoint: ADBServerEndpoint = .fromEnvironment(),
        adbExecutable: URL? = ADBLocator.find(),
        runner: any ProcessRunner = SystemProcessRunner(),
        connectTimeout: Duration = .seconds(3)
    ) {
        self.endpoint = endpoint
        self.adbExecutable = adbExecutable
        self.runner = runner
        self.connectTimeout = connectTimeout
    }

    // MARK: Host queries

    /// `host:version` — the server's protocol version (41 for current platform-tools).
    public func version(timeout: Duration = .seconds(5)) async throws -> Int {
        let text = try await hostQuery("host:version", timeout: timeout)
        guard let v = Int(text, radix: 16) else { throw EmuuError.parse("adb host:version returned '\(text)'") }
        return v
    }

    /// `host:devices-l`.
    public func devices(timeout: Duration = .seconds(5)) async throws -> [ADBDevice] {
        ADBDevice.parseList(try await hostQuery("host:devices-l", timeout: timeout))
    }

    /// The device's state, or nil when the server does not know the serial.
    public func state(of serial: DeviceSerial, timeout: Duration = .seconds(5)) async throws -> ADBDevice.State? {
        try await devices(timeout: timeout).first { $0.serial == serial.rawValue }?.state
    }

    /// `host-serial:<serial>:features` (e.g. `shell_v2`, `cmd`, `stat_v2`, `abb_exec`).
    public func features(of serial: DeviceSerial, timeout: Duration = .seconds(5)) async throws -> Set<String> {
        let text = try await hostQuery("host-serial:\(serial.rawValue):features", timeout: timeout, serial: serial)
        return Set(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    /// Polls `host:devices-l` until `serial` is in state `device`. Cheap (one localhost connect per poll).
    @discardableResult
    public func waitForDevice(
        _ serial: DeviceSerial,
        timeout: Duration,
        pollInterval: Duration = .milliseconds(500),
        clock: any EmuuClock = SystemClock()
    ) async throws -> ADBDevice {
        let deadline = clock.monotonicNow() + timeout
        while true {
            if let device = try await devices().first(where: { $0.serial == serial.rawValue }), device.state == .device {
                return device
            }
            if clock.monotonicNow() >= deadline { throw EmuuError.deviceNotReady(serial) }
            try await clock.sleep(for: pollInterval)
        }
    }

    /// Runs `adb start-server` (idempotent; concurrent callers share one attempt).
    public func startServer() async throws {
        try await starter.start { [self] in
            guard let adb = adbExecutable else {
                throw EmuuError.toolNotFound(name: "adb", searched: ADBLocator.candidates().map(\.path))
            }
            var env: [String: String] = [:]
            if endpoint.port != 5037 { env["ANDROID_ADB_SERVER_PORT"] = String(endpoint.port) }
            log.notice("adb server not reachable on \(endpoint.host):\(endpoint.port); running adb start-server")
            let result = try await runner.run(ProcessRequest(
                executable: adb, arguments: ["start-server"], environment: env, timeout: .seconds(30),
                stdout: .discard, stderr: .pipe
            ))
            try result.checked()
        }
    }

    // MARK: Connections

    /// Opens a connection (starting the server once if refused) and runs `body` on the adb I/O queue.
    /// The socket is closed afterwards. `timeout` bounds the connect only; `body` manages its own deadlines.
    func withConnection<T: Sendable>(_ body: @escaping @Sendable (ADBSocket) throws -> T) async throws -> T {
        do {
            return try await attempt(body)
        } catch ADBSocketError.connectionRefused {
            try await startServer()
            return try await attempt(body)
        }
    }

    private func attempt<T: Sendable>(_ body: @escaping @Sendable (ADBSocket) throws -> T) async throws -> T {
        let socket = try ADBSocket()
        let endpoint = endpoint
        let connectTimeout = connectTimeout
        defer { socket.close() }
        return try await ADBIO.perform(socket: socket) {
            try socket.connect(host: endpoint.host, port: endpoint.port, deadline: .now + connectTimeout)
            return try body(socket)
        }
    }

    /// Sends a `host:*` query and returns the length-prefixed payload.
    func hostQuery(_ service: String, timeout: Duration, serial: DeviceSerial? = nil) async throws -> String {
        do {
            return try await withConnection { socket in
                let deadline = ContinuousClock.now + timeout
                try socket.write(try ADBWire.request(service), deadline: deadline)
                try Self.readStatus(socket, deadline: deadline)
                return try Self.readLengthPrefixedString(socket, deadline: deadline)
            }
        } catch {
            throw Self.mapError(error, serial: serial, command: service, timeout: timeout)
        }
    }

    /// Opens `host:transport:<serial>` then `service` on one connection, then runs `body` with the
    /// connected stream (service already acknowledged with OKAY).
    func withDeviceService<T: Sendable>(
        serial: DeviceSerial,
        service: String,
        setupTimeout: Duration = .seconds(10),
        _ body: @escaping @Sendable (ADBSocket) throws -> T
    ) async throws -> T {
        try await withConnection { socket in
            let deadline = ContinuousClock.now + setupTimeout
            try socket.write(try ADBWire.request("host:transport:\(serial.rawValue)"), deadline: deadline)
            do {
                try Self.readStatus(socket, deadline: deadline)
            } catch ADBProtocolError.fail(let message) {
                throw ADBTransportFailure(message: message)
            }
            try socket.write(try ADBWire.request(service), deadline: deadline)
            try Self.readStatus(socket, deadline: deadline)
            return try body(socket)
        }
    }

    // MARK: Wire helpers

    static func readStatus(_ socket: ADBSocket, deadline: ContinuousClock.Instant?) throws {
        let status = try socket.readExactly(4, deadline: deadline)
        switch String(decoding: status, as: UTF8.self) {
        case "OKAY":
            return
        case "FAIL":
            let message = (try? readLengthPrefixedString(socket, deadline: deadline)) ?? "unknown failure"
            throw ADBProtocolError.fail(message)
        default:
            throw ADBProtocolError.malformed("unexpected status '\(String(decoding: status, as: UTF8.self))'")
        }
    }

    static func readLengthPrefixedString(_ socket: ADBSocket, deadline: ContinuousClock.Instant?) throws -> String {
        guard let length = ADBWire.parseHexLength(try socket.readExactly(4, deadline: deadline)) else {
            throw ADBProtocolError.malformed("bad length prefix")
        }
        return String(decoding: try socket.readExactly(length, deadline: deadline), as: UTF8.self)
    }

    /// Maps socket/protocol errors to `EmuuError`.
    static func mapError(_ error: any Error, serial: DeviceSerial?, command: String, timeout: Duration?) -> any Error {
        switch error {
        case let e as EmuuError:
            return e
        case is CancellationError:
            return error
        case let t as ADBTransportFailure:
            if let serial, t.isDeviceUnavailable { return EmuuError.deviceNotReady(serial) }
            return EmuuError.adb(t.message)
        case let e as ADBSocketError:
            switch e {
            case .cancelled: return CancellationError()
            case .timedOut: return EmuuError.processTimedOut(command: "adb \(command)", timeout: timeout ?? .zero)
            case .connectionRefused: return EmuuError.adb("cannot connect to the adb server")
            case .connectFailed(let m): return EmuuError.adb("cannot connect to the adb server: \(m)")
            case .unexpectedEOF: return EmuuError.adb("connection closed unexpectedly during \(command)")
            case .io(let m): return EmuuError.adb("\(command): \(m)")
            }
        case let e as ADBProtocolError:
            switch e {
            case .fail(let m):
                if let serial, ADBTransportFailure(message: m).isDeviceUnavailable { return EmuuError.deviceNotReady(serial) }
                return EmuuError.adb(m)
            case .malformed(let m): return EmuuError.parse("adb \(command): \(m)")
            }
        default:
            return EmuuError.adb("\(command): \(error.localizedDescription)")
        }
    }
}

/// `host:transport:<serial>` was refused (device unknown/offline/unauthorized).
struct ADBTransportFailure: Error, Sendable, Equatable {
    let message: String

    var isDeviceUnavailable: Bool {
        let m = message.lowercased()
        return m.contains("not found") || m.contains("offline") || m.contains("unauthorized")
            || m.contains("no devices") || m.contains("authorizing") || m.contains("connecting")
            || m.contains("no permissions")
    }
}

/// Serialises `adb start-server` so concurrent requests don't spawn several servers.
private actor ServerStarter {
    private var inFlight: Task<Void, Error>?

    func start(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        if let inFlight { return try await inFlight.value }
        let task = Task { try await operation() }
        inFlight = task
        defer { inFlight = nil }
        try await task.value
    }
}
