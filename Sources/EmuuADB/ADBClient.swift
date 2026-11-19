import Foundation
import EmuuBase

/// Progress of a byte transfer to/from the device.
public struct TransferProgress: Sendable, Hashable {
    /// Local file name (or remote path for pulls).
    public var name: String
    public var bytesTransferred: UInt64
    public var totalBytes: UInt64

    public init(name: String, bytesTransferred: UInt64, totalBytes: UInt64) {
        self.name = name
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
    }

    public var fraction: Double { totalBytes == 0 ? 1 : min(1, Double(bytesTransferred) / Double(totalBytes)) }
}

public typealias TransferProgressHandler = @Sendable (TransferProgress) -> Void

/// File status from the sync `STAT` request.
public struct RemoteFileStat: Sendable, Hashable {
    public var mode: UInt32
    public var size: UInt32
    public var modified: Date
    public var exists: Bool { mode != 0 }
    public var isDirectory: Bool { mode & 0o170000 == 0o040000 }
    public var isRegularFile: Bool { mode & 0o170000 == 0o100000 }
}

/// adb client for one device. Implements `DeviceShell`.
///
/// Fast path: talks the smart-socket protocol directly to the adb server (`shell,v2,raw:`, `exec:`,
/// `sync:`), so a poll costs a localhost TCP round trip, not a process spawn. If the native path
/// is unavailable (the device lacks shell v2, or `transport == .binary`), it falls back to running the
/// adb binary through `ProcessRunner`. `adb(_:timeout:)` always runs the binary, because it takes
/// arbitrary command-line arguments.
///
/// Every request uses a fresh connection, so there is no long-lived socket to go stale: if the
/// device reboots or the server restarts, the next call reconnects (starting the server if needed).
public final class ADBClient: DeviceShell, Sendable {
    public enum Transport: Sendable, Hashable {
        /// Native protocol, falling back to the binary when the device/service does not support it.
        case automatic
        /// Native protocol only (fails instead of spawning adb).
        case socket
        /// Always spawn the adb binary.
        case binary
    }

    public let serial: DeviceSerial
    public let server: ADBServer
    public let transport: Transport
    private let nativeShellUnsupported = Locked(false)
    private let log = EmuuLogger(category: "adb")

    public init(serial: DeviceSerial, server: ADBServer = ADBServer(), transport: Transport = .automatic) {
        self.serial = serial
        self.server = server
        self.transport = transport
    }

    var runner: any ProcessRunner { server.runner }
    var adbURL: URL { server.adbExecutable ?? URL(fileURLWithPath: "adb") }

    // MARK: DeviceShell

    public func shell(_ command: String, timeout: Duration?) async throws -> ProcessResult {
        if transport != .binary && !nativeShellUnsupported.current {
            do {
                return try await nativeShell(command, timeout: timeout)
            } catch let unsupported as NativeServiceUnsupported {
                if transport == .socket { throw EmuuError.unsupported("shell v2 not available on \(serial): \(unsupported.message)") }
                log.info("native shell v2 unavailable on \(serial) (\(unsupported.message)); using adb binary")
                nativeShellUnsupported.set(true)
            }
        }
        return try await binary(["shell", command], timeout: timeout)
    }

    public func adb(_ arguments: [String], timeout: Duration?) async throws -> ProcessResult {
        try await binary(arguments, timeout: timeout)
    }

    // MARK: Native shell v2

    private func shellRequest(_ command: String, timeout: Duration?) -> ProcessRequest {
        ProcessRequest(executable: adbURL, arguments: ["-s", serial.rawValue, "shell", command], timeout: timeout)
    }

    func nativeShell(_ command: String, timeout: Duration?) async throws -> ProcessResult {
        let request = shellRequest(command, timeout: timeout)
        let started = ContinuousClock.now
        let deadline = timeout.map { started + $0 }
        do {
            let (out, err, code) = try await withService("shell,v2,raw:\(command)") { socket in
                try socket.write(ADBWire.shellV2Packet(.closeStdin), deadline: deadline)
                return try Self.readShellV2(socket, deadline: deadline)
            }
            return ProcessResult(request: request, termination: .exited(code: code), stdout: out, stderr: err, duration: ContinuousClock.now - started)
        } catch {
            throw mapped(error, command: "shell \(command.prefix(60))", timeout: timeout)
        }
    }

    /// Reads shell-v2 packets until the exit packet. Output is capped at 64 MiB per stream.
    static func readShellV2(_ socket: ADBSocket, deadline: ContinuousClock.Instant?) throws -> (Data, Data, Int32) {
        var out = Data(), err = Data()
        let cap = 64 * 1024 * 1024
        while true {
            let header: Data
            do {
                header = try socket.readExactly(5, deadline: deadline)
            } catch ADBSocketError.unexpectedEOF {
                throw ADBProtocolError.malformed("shell stream closed without an exit status")
            }
            let id = header[header.startIndex]
            let length = Int(ADBWire.readLE32(header, at: 1))
            let payload = length > 0 ? try socket.readExactly(length, deadline: deadline) : Data()
            switch ShellV2PacketID(rawValue: id) {
            case .stdout: if out.count < cap { out.append(payload) }
            case .stderr: if err.count < cap { err.append(payload) }
            case .exit: return (out, err, Int32(payload.first ?? 255))
            default: continue
            }
        }
    }

    // MARK: exec (raw binary-safe output, no pty, no exit status)

    /// `adb exec-out <command>`: raw stdout bytes (binary safe; used for `screencap -p`).
    public func execOut(_ command: String, timeout: Duration? = .seconds(60), limit: Int = 256 * 1024 * 1024) async throws -> Data {
        if transport == .binary {
            return try await binary(["exec-out", command], timeout: timeout).checked().stdout
        }
        let deadline = timeout.map { ContinuousClock.now + $0 }
        do {
            return try await withService("exec:\(command)") { socket in
                try socket.readToEnd(deadline: deadline, limit: limit)
            }
        } catch let unsupported as NativeServiceUnsupported {
            if transport == .socket { throw EmuuError.unsupported("exec service unavailable: \(unsupported.message)") }
            return try await binary(["exec-out", command], timeout: timeout).checked().stdout
        } catch {
            throw mapped(error, command: "exec-out \(command.prefix(60))", timeout: timeout)
        }
    }

    /// Runs `exec:<command>`, streams `file` to its stdin, then returns everything the command printed.
    /// Used for `cmd package install -S <size>` / `install-write`. Memory use is bounded (256 KiB chunks).
    /// `idleTimeout` bounds each write and the final read (installs of big games can take minutes).
    public func execStreaming(
        _ command: String,
        uploading file: URL,
        idleTimeout: Duration = .seconds(600),
        progress: TransferProgressHandler? = nil
    ) async throws -> String {
        let size = try Self.fileSize(file)
        let name = file.lastPathComponent
        do {
            return try await withService("exec:\(command)") { socket in
                guard let handle = FileHandle(forReadingAtPath: file.path) else {
                    throw EmuuError.io(path: file.path, message: "cannot open for reading")
                }
                defer { try? handle.close() }
                var sent: UInt64 = 0
                var reporter = ProgressThrottle(name: name, total: size, handler: progress)
                reporter.report(0)
                do {
                    while sent < size {
                        let chunk = try handle.read(upToCount: 256 * 1024) ?? Data()
                        if chunk.isEmpty { throw EmuuError.io(path: file.path, message: "file shrank while uploading") }
                        try socket.write(chunk, deadline: .now + idleTimeout)
                        sent += UInt64(chunk.count)
                        reporter.report(sent)
                    }
                } catch let e as ADBSocketError where e != .cancelled && e != .timedOut {
                    // The remote side gave up early (e.g. pm rejected the APK); its reply explains why.
                    let reply = String(decoding: (try? socket.readToEnd(deadline: .now + .seconds(5))) ?? Data(), as: UTF8.self)
                    if !reply.isEmpty { return reply }
                    throw e
                }
                reporter.finish()
                return String(decoding: try socket.readToEnd(deadline: .now + idleTimeout), as: UTF8.self)
            }
        } catch let unsupported as NativeServiceUnsupported {
            throw EmuuError.unsupported("exec service unavailable on \(serial): \(unsupported.message)")
        } catch {
            throw mapped(error, command: "exec \(command.prefix(60))", timeout: idleTimeout)
        }
    }

    // MARK: sync (push / pull / stat)

    /// Pushes a local file (any size; streamed in 64 KiB packets). adbd creates missing parent directories.
    public func push(
        _ local: URL,
        to remotePath: String,
        permissions: Int = 0o644,
        idleTimeout: Duration = .seconds(60),
        progress: TransferProgressHandler? = nil
    ) async throws {
        if transport == .binary {
            try await binary(["push", local.path, remotePath], timeout: nil).checked()
            return
        }
        let size = try Self.fileSize(local)
        let mtime = (try? FileManager.default.attributesOfItem(atPath: local.path)[.modificationDate] as? Date) ?? Date()
        let name = local.lastPathComponent
        do {
            try await withService("sync:") { socket in
                guard let handle = FileHandle(forReadingAtPath: local.path) else {
                    throw EmuuError.io(path: local.path, message: "cannot open for reading")
                }
                defer { try? handle.close() }
                let mode = 0o100000 | permissions
                try socket.write(ADBWire.syncPacket("SEND", Data("\(remotePath),\(mode)".utf8)), deadline: .now + idleTimeout)
                var sent: UInt64 = 0
                var reporter = ProgressThrottle(name: name, total: size, handler: progress)
                reporter.report(0)
                while sent < size {
                    let chunk = try handle.read(upToCount: ADBWire.syncDataMax) ?? Data()
                    if chunk.isEmpty { throw EmuuError.io(path: local.path, message: "file shrank while pushing") }
                    try socket.write(ADBWire.syncPacket("DATA", chunk), deadline: .now + idleTimeout)
                    sent += UInt64(chunk.count)
                    reporter.report(sent)
                }
                try socket.write(ADBWire.syncPacket("DONE", value: UInt32(truncatingIfNeeded: Int(mtime.timeIntervalSince1970))), deadline: .now + idleTimeout)
                try Self.readSyncStatus(socket, deadline: .now + idleTimeout, what: "push \(name) to \(remotePath)")
                reporter.finish()
                try? socket.write(ADBWire.syncPacket("QUIT", value: 0), deadline: .now + .seconds(2))
            }
        } catch {
            throw mapped(error, command: "push \(name)", timeout: idleTimeout)
        }
    }

    /// Pulls a remote file to `local` (streamed; any size).
    public func pull(_ remotePath: String, to local: URL, idleTimeout: Duration = .seconds(60), progress: TransferProgressHandler? = nil) async throws {
        if transport == .binary {
            try await binary(["pull", remotePath, local.path], timeout: nil).checked()
            return
        }
        let total = UInt64((try? await stat(remotePath).size) ?? 0)
        do {
            try await withService("sync:") { socket in
                FileManager.default.createFile(atPath: local.path, contents: nil)
                guard let handle = FileHandle(forWritingAtPath: local.path) else {
                    throw EmuuError.io(path: local.path, message: "cannot open for writing")
                }
                defer { try? handle.close() }
                try socket.write(ADBWire.syncPacket("RECV", Data(remotePath.utf8)), deadline: .now + idleTimeout)
                var received: UInt64 = 0
                var reporter = ProgressThrottle(name: remotePath, total: total, handler: progress)
                while true {
                    let header = try socket.readExactly(8, deadline: .now + idleTimeout)
                    let id = String(decoding: header.prefix(4), as: UTF8.self)
                    let length = Int(ADBWire.readLE32(header, at: 4))
                    switch id {
                    case "DATA":
                        let data = try socket.readExactly(length, deadline: .now + idleTimeout)
                        try handle.write(contentsOf: data)
                        received += UInt64(data.count)
                        reporter.report(received)
                    case "DONE":
                        reporter.finish()
                        try? socket.write(ADBWire.syncPacket("QUIT", value: 0), deadline: .now + .seconds(2))
                        return
                    case "FAIL":
                        let msg = String(decoding: try socket.readExactly(length, deadline: .now + idleTimeout), as: UTF8.self)
                        throw EmuuError.adb("pull \(remotePath): \(msg)")
                    default:
                        throw ADBProtocolError.malformed("unexpected sync reply '\(id)'")
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: local)
            throw mapped(error, command: "pull \(remotePath)", timeout: idleTimeout)
        }
    }

    /// sync `STAT` (v1: sizes are 32-bit). `exists == false` when the path is missing.
    public func stat(_ remotePath: String, timeout: Duration = .seconds(10)) async throws -> RemoteFileStat {
        do {
            return try await withService("sync:") { socket in
                let deadline = ContinuousClock.now + timeout
                try socket.write(ADBWire.syncPacket("STAT", Data(remotePath.utf8)), deadline: deadline)
                let reply = try socket.readExactly(16, deadline: deadline)
                guard String(decoding: reply.prefix(4), as: UTF8.self) == "STAT" else {
                    throw ADBProtocolError.malformed("unexpected STAT reply")
                }
                try? socket.write(ADBWire.syncPacket("QUIT", value: 0), deadline: deadline)
                return RemoteFileStat(
                    mode: ADBWire.readLE32(reply, at: 4),
                    size: ADBWire.readLE32(reply, at: 8),
                    modified: Date(timeIntervalSince1970: TimeInterval(ADBWire.readLE32(reply, at: 12)))
                )
            }
        } catch {
            throw mapped(error, command: "stat \(remotePath)", timeout: timeout)
        }
    }

    static func readSyncStatus(_ socket: ADBSocket, deadline: ContinuousClock.Instant, what: String) throws {
        let reply = try socket.readExactly(8, deadline: deadline)
        let id = String(decoding: reply.prefix(4), as: UTF8.self)
        let length = Int(ADBWire.readLE32(reply, at: 4))
        switch id {
        case "OKAY":
            return
        case "FAIL":
            let msg = String(decoding: try socket.readExactly(length, deadline: deadline), as: UTF8.self)
            throw EmuuError.adb("\(what) failed: \(msg)")
        default:
            throw ADBProtocolError.malformed("unexpected sync status '\(id)'")
        }
    }

    // MARK: Device state

    /// The device's state as the adb server sees it (nil = unknown serial).
    public func state() async throws -> ADBDevice.State? {
        try await server.state(of: serial)
    }

    /// True when `sys.boot_completed` is 1.
    public func isBootCompleted() async -> Bool {
        (try? await getprop("sys.boot_completed")) == "1"
    }

    // MARK: Internals

    /// Opens the service on this device; a `FAIL` reply to the service itself becomes `NativeServiceUnsupported`.
    private func withService<T: Sendable>(_ service: String, _ body: @escaping @Sendable (ADBSocket) throws -> T) async throws -> T {
        do {
            return try await server.withDeviceService(serial: serial, service: service, body)
        } catch ADBProtocolError.fail(let message) {
            if ADBTransportFailure(message: message).isDeviceUnavailable { throw EmuuError.deviceNotReady(serial) }
            throw NativeServiceUnsupported(message: message)
        }
    }

    private func mapped(_ error: any Error, command: String, timeout: Duration?) -> any Error {
        if error is NativeServiceUnsupported { return error }
        return ADBServer.mapError(error, serial: serial, command: command, timeout: timeout)
    }

    /// Runs `adb -s <serial> <args>` through `ProcessRunner`. Device-level failures throw `deviceNotReady`.
    func binary(_ arguments: [String], timeout: Duration?) async throws -> ProcessResult {
        guard let adb = server.adbExecutable else {
            throw EmuuError.toolNotFound(name: "adb", searched: ADBLocator.candidates().map(\.path))
        }
        var env: [String: String] = [:]
        if server.endpoint.port != 5037 { env["ANDROID_ADB_SERVER_PORT"] = String(server.endpoint.port) }
        let result = try await runner.run(ProcessRequest(
            executable: adb, arguments: ["-s", serial.rawValue] + arguments, environment: env, timeout: timeout
        ))
        if !result.succeeded, Self.isDeviceUnavailableMessage(result.stderrString) {
            throw EmuuError.deviceNotReady(serial)
        }
        return result
    }

    static func isDeviceUnavailableMessage(_ stderr: String) -> Bool {
        let s = stderr.lowercased()
        return (s.contains("device '") && s.contains("not found")) || s.contains("device offline")
            || s.contains("no devices/emulators found") || s.contains("device unauthorized")
            || s.contains("device still authorizing") || s.contains("device still connecting")
    }

    static func fileSize(_ url: URL) throws -> UInt64 {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        } catch {
            throw EmuuError.io(path: url.path, message: error.localizedDescription)
        }
    }
}

/// The device answered FAIL to a service request (e.g. no shell v2) — a fallback is possible.
struct NativeServiceUnsupported: Error, Sendable {
    let message: String
}

/// Calls a progress handler at most every 1 MiB (plus the first and last call).
struct ProgressThrottle {
    let name: String
    let total: UInt64
    let handler: TransferProgressHandler?
    private var lastReported: UInt64 = 0
    private var reportedAny = false
    static let step: UInt64 = 1024 * 1024

    init(name: String, total: UInt64, handler: TransferProgressHandler?) {
        self.name = name
        self.total = total
        self.handler = handler
    }

    mutating func report(_ sent: UInt64) {
        guard let handler else { return }
        if !reportedAny || sent >= lastReported + Self.step || sent == total {
            if reportedAny && sent == lastReported { return }
            reportedAny = true
            lastReported = sent
            handler(TransferProgress(name: name, bytesTransferred: sent, totalBytes: total))
        }
    }

    mutating func finish() { report(total) }
}
