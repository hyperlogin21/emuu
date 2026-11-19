import Foundation
import EmuuBase

/// Client for the emulator console (`telnet localhost <console port>`).
///
/// Keeps one authenticated connection and reconnects once if it drops. Commands are serialized explicitly
/// (`exclusive`): the actor alone does not do it, because a command suspends while it writes and while it
/// waits for its reply, and another caller's command would otherwise interleave on the same socket and
/// parser (and a first use by two callers would open two connections). Auth uses the token file named in the console's greeting (normally `~/.emulator_console_auth_token`).
///
/// While the engine process is SIGSTOPped the console cannot answer; calls then fail with a timeout.
public actor ConsoleClient {
    public let port: Int
    private let connector: any ConsoleConnector
    private let tokenOverride: String?
    private let fallbackTokenFile: URL
    private let connectTimeout: Duration
    public let defaultTimeout: Duration

    private var transport: (any ConsoleTransport)?
    private var parser = ConsoleResponseParser()
    private let log = EmuuLogger(category: "console")
    /// FIFO mutex over connect + send + reply (see the type comment).
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(port: Int,
                connector: any ConsoleConnector = TCPConsoleConnector(),
                token: String? = nil,
                tokenFile: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".emulator_console_auth_token"),
                connectTimeout: Duration = .seconds(3),
                defaultTimeout: Duration = .seconds(10)) {
        self.port = port
        self.connector = connector
        self.tokenOverride = token
        self.fallbackTokenFile = tokenFile
        self.connectTimeout = connectTimeout
        self.defaultTimeout = defaultTimeout
    }

    /// Sends one command and returns its output (without the trailing `OK`).
    /// Throws `EmuuError.console` for `KO:` replies, timeouts and connection failures.
    @discardableResult
    public func send(_ command: String, timeout: Duration? = nil) async throws -> String {
        try await exclusive { try await self.sendRetrying(command, timeout: timeout ?? self.defaultTimeout) }
    }

    private func sendRetrying(_ command: String, timeout limit: Duration) async throws -> String {
        do {
            return try await sendOnce(command, timeout: limit)
        } catch let error as ConsoleDropped {
            // The engine closed the socket (e.g. idle connection reaped); retry once on a fresh one.
            log.debug("console connection dropped (\(error.reason)); reconnecting")
            disconnect()
            return try await sendOnce(command, timeout: limit)
        }
    }

    /// Closes the connection (polite `quit` is not needed; the console tolerates abrupt closes).
    public func disconnect() {
        transport?.close()
        transport = nil
        parser = ConsoleResponseParser()
    }

    // MARK: Typed commands (all verified against `help avd` / `help avd snapshot` on 36.4.9)

    /// `ping` -> `I am alive!`. False on any failure, never throws.
    public func ping(timeout: Duration = .seconds(2)) async -> Bool {
        (try? await send("ping", timeout: timeout))?.contains("alive") == true
    }

    public func vmStatus() async throws -> ConsoleVMStatus {
        ConsoleVMStatus(statusText: try await send("avd status"))
    }

    /// Stops guest vCPUs (QEMU `vm_stop`); the engine keeps serving the console. Guest clock does not advance.
    public func avdStop() async throws { try await send("avd stop") }
    /// Restarts vCPUs after `avdStop`.
    public func avdStart() async throws { try await send("avd start") }
    public func avdName() async throws -> String { try await send("avd name") }
    public func heartbeat() async throws -> Int? { ConsoleParsing.heartbeat(from: try await send("avd heartbeat")) }

    public func snapshotSave(_ name: String, timeout: Duration = .seconds(180)) async throws {
        try Self.checkSnapshotName(name)
        try await send("avd snapshot save \(name)", timeout: timeout)
    }

    public func snapshotLoad(_ name: String, timeout: Duration = .seconds(180)) async throws {
        try Self.checkSnapshotName(name)
        try await send("avd snapshot load \(name)", timeout: timeout)
    }

    public func snapshotDelete(_ name: String) async throws {
        try Self.checkSnapshotName(name)
        try await send("avd snapshot delete \(name)", timeout: .seconds(60))
    }

    public func snapshotList() async throws -> [String] {
        ConsoleParsing.snapshotNames(fromList: try await send("avd snapshot list", timeout: .seconds(30)))
    }

    /// Name of the snapshot the session booted from, nil after a cold boot.
    public func loadedSnapshot() async throws -> String? {
        ConsoleParsing.loadedSnapshot(fromGet: try await send("avd snapshot get"))
    }

    /// `kill`: the engine replies, then exits (saving the quick-boot snapshot unless launched with
    /// `-no-snapshot-save`). The connection closing right after is expected.
    public func kill() async throws {
        try await exclusive {
            do {
                _ = try await self.sendOnce("kill", timeout: .seconds(10))
            } catch is ConsoleDropped {
                // Closed before/without `OK`: the engine is going down, which is what we asked for.
            }
            await self.disconnect()
        }
    }

    /// Runs `body` with the connection to itself; later callers wait in FIFO order.
    private func exclusive<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        return try await body()
    }

    static func checkSnapshotName(_ name: String) throws {
        let ok = !name.isEmpty && name.count <= 64 && name.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" || $0 == ".")
        }
        guard ok else { throw EmuuError.invalidConfiguration("snapshot name '\(name)' must be 1-64 of [A-Za-z0-9._-]") }
    }

    // MARK: Internals

    private struct ConsoleDropped: Error { let reason: String }

    private func sendOnce(_ command: String, timeout: Duration) async throws -> String {
        let t = try await connectedTransport()
        guard !command.contains("\n"), !command.contains("\r") else {
            throw EmuuError.console("command must be a single line")
        }
        do {
            try await t.send(Data((command + "\r\n").utf8))
        } catch {
            throw ConsoleDropped(reason: "send failed: \(error.localizedDescription)")
        }
        switch try await readReply(on: t, timeout: timeout) {
        case .ok(let output): return output
        case .ko(let message, let output):
            throw EmuuError.console("'\(command)' failed: \(message.isEmpty ? output : message)")
        }
    }

    private func connectedTransport() async throws -> any ConsoleTransport {
        if let transport { return transport }
        let t = try await connector.connect(port: port, timeout: connectTimeout)
        parser = ConsoleResponseParser()
        do {
            try await handshake(t)
        } catch let e as ConsoleDropped {
            t.close()
            throw EmuuError.console("console on port \(port) closed during greeting/auth (\(e.reason))")
        } catch {
            t.close()
            throw error
        }
        transport = t
        return t
    }

    private func handshake(_ t: any ConsoleTransport) async throws {
        // The greeting ends with OK.
        guard case .ok(let greeting) = try await readReply(on: t, timeout: connectTimeout) else {
            throw EmuuError.console("unexpected greeting on port \(port)")
        }
        guard greeting.contains("Authentication required") else { return }
        let token = try authToken(greeting: greeting)
        try await t.send(Data("auth \(token)\r\n".utf8))
        if case .ko(let message, _) = try await readReply(on: t, timeout: connectTimeout) {
            throw EmuuError.console("authentication failed: \(message)")
        }
    }

    private func authToken(greeting: String) throws -> String {
        if let tokenOverride { return tokenOverride }
        let file = ConsoleResponseParser.tokenPath(inGreeting: greeting).map { URL(fileURLWithPath: $0) } ?? fallbackTokenFile
        do {
            let token = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw EmuuError.console("console auth token file \(file.path) is empty") }
            return token
        } catch let e as EmuuError {
            throw e
        } catch {
            throw EmuuError.console("cannot read console auth token \(file.path): \(error.localizedDescription)")
        }
    }

    private func readReply(on t: any ConsoleTransport, timeout: Duration) async throws -> ConsoleResponseParser.Reply {
        let deadline = ContinuousClock.now + timeout
        while true {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else {
                disconnect()
                throw EmuuError.console("no reply within \(timeout) (engine paused or hung?)")
            }
            let chunk: Data?
            do { chunk = try await t.receive(timeout: remaining) } catch {
                disconnect()
                throw error
            }
            guard let chunk else {
                if transport === t { transport = nil }
                throw ConsoleDropped(reason: "EOF")
            }
            if let reply = parser.feed(String(decoding: chunk, as: UTF8.self)) { return reply }
        }
    }
}
