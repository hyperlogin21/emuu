import Foundation
import EmuuBase

/// Incremental parser for the emulator console's line protocol (telnet-style, CRLF).
///
/// Verified against engine 36.4.9:
/// * The greeting ends with a line `OK`; when auth is required it names the token file in quotes:
///   `'/Users/<u>/.emulator_console_auth_token'`.
/// * Each command's reply ends with a line that is exactly `OK` or starts with `KO:`. Only those lines
///   terminate a reply: command output may itself contain lines ending in `OK` or starting with `KO`
///   (e.g. a snapshot named `pre_OK`), and treating those as terminators would shift every later reply on
///   the connection by one. (Some `help` texts glue `OK` to their last line without a newline; Emuu never
///   sends `help`, so that form is not recognised.)
public struct ConsoleResponseParser: Sendable {
    public enum Reply: Sendable, Hashable {
        case ok(String)
        case ko(message: String, output: String)
    }

    private var buffer = ""

    public init() {}

    /// Appends bytes and returns a reply once one is complete; leftover bytes stay buffered.
    public mutating func feed(_ text: String) -> Reply? {
        buffer += text.replacingOccurrences(of: "\r", with: "")
        return takeReply()
    }

    /// True when nothing is buffered.
    public var isEmpty: Bool { buffer.isEmpty }

    private mutating func takeReply() -> Reply? {
        // Find the first complete line that terminates a reply.
        var lineStart = buffer.startIndex
        while let nl = buffer[lineStart...].firstIndex(of: "\n") {
            let line = buffer[lineStart..<nl]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "KO" || trimmed.hasPrefix("KO:") {
                let output = String(buffer[buffer.startIndex..<lineStart]).trimmingCharacters(in: .newlines)
                var message = String(trimmed.dropFirst(2))
                if message.hasPrefix(":") { message.removeFirst() }
                buffer = String(buffer[buffer.index(after: nl)...])
                return .ko(message: message.trimmingCharacters(in: .whitespaces), output: output)
            }
            if trimmed == "OK" {
                let payload = String(buffer[buffer.startIndex..<lineStart]).trimmingCharacters(in: .newlines)
                buffer = String(buffer[buffer.index(after: nl)...])
                return .ok(payload)
            }
            lineStart = buffer.index(after: nl)
        }
        return nil
    }

    /// Token file named in the auth greeting, if any.
    public static func tokenPath(inGreeting greeting: String) -> String? {
        guard greeting.contains("Authentication required") else { return nil }
        // The greeting quotes both `'auth <auth_token>'` and the token file; take the quoted absolute path.
        let quoted = greeting.split(separator: "'", omittingEmptySubsequences: false).enumerated()
            .filter { $0.offset % 2 == 1 }.map { String($0.element) }
        return quoted.first { $0.hasPrefix("/") }
    }
}

/// Parsed `avd status` reply.
public enum ConsoleVMStatus: Sendable, Hashable {
    case running
    case stopped
    case other(String)

    /// `virtual device is running` / `virtual device is stopped` (also `paused` on some versions).
    public init(statusText: String) {
        let t = statusText.lowercased()
        if t.contains("running") { self = .running }
        else if t.contains("stopped") || t.contains("paused") { self = .stopped }
        else { self = .other(statusText) }
    }
}

enum ConsoleParsing {
    /// `avd snapshot list` output. Engine 36.4.9 prints `There is no snapshot available.` when empty and a
    /// table otherwise:
    /// ```
    /// List of snapshots present on all disks:
    /// ID        TAG                 VM SIZE                DATE       VM CLOCK
    /// --        default_boot           1.1G 2026-11-18 21:00:01   00:01:02.123
    /// ```
    static func snapshotNames(fromList text: String) -> [String] {
        var names: [String] = []
        var inTable = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("ID") && line.contains("TAG") { inTable = true; continue }
            guard inTable else { continue }
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard cols.count >= 2 else { continue }
            names.append(String(cols[1]))
        }
        return names
    }

    /// `avd snapshot get`: `(null)` when the session did not load a snapshot.
    static func loadedSnapshot(fromGet text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t == "(null)" ? nil : t
    }

    /// `avd heartbeat` -> `heartbeat: 7`.
    static func heartbeat(from text: String) -> Int? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        return Int(text[text.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
