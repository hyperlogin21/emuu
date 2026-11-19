import Foundation
import EmuuBase

/// Terminal output helpers. Normal output goes to stdout; diagnostics and progress go to stderr so
/// `--json` output stays machine-readable.
enum Out {
    static func line(_ text: String = "") {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    static func err(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    /// Progress on one rewritten stderr line (only when stderr is a terminal).
    static func progress(_ text: String) {
        guard isatty(STDERR_FILENO) != 0 else { return }
        FileHandle.standardError.write(Data(("\r\u{1B}[2K" + text).utf8))
    }

    static func endProgress() {
        guard isatty(STDERR_FILENO) != 0 else { return }
        FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8))
    }

    static func json<T: Encodable>(_ value: T, pretty: Bool = true) throws {
        line(try JSONText.encode(value, pretty: pretty))
    }
}

enum JSONText {
    static func encoder(pretty: Bool) -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func encode<T: Encodable>(_ value: T, pretty: Bool = false) throws -> String {
        String(decoding: try encoder(pretty: pretty).encode(value), as: UTF8.self)
    }
}

/// Small formatting helpers shared by the commands (pure; unit-tested).
enum Fmt {
    static func mib(_ bytes: UInt64?) -> String {
        guard let bytes else { return "-" }
        return String(format: "%.0f MiB", Double(bytes) / Double(ByteCount.mib))
    }

    static func bytes(_ bytes: UInt64?) -> String {
        bytes.map(ByteCount.format) ?? "-"
    }

    static func seconds(_ d: Duration) -> String {
        String(format: "%.1f s", d.timeInterval)
    }

    static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "-" }
        return String(format: "%.0f%%", fraction * 100)
    }

    /// "2h 05m", "4m 10s", "12s".
    static func uptime(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        if s >= 86_400 { return "\(s / 86_400)d \(String(format: "%02dh", (s % 86_400) / 3600))" }
        if s >= 3600 { return "\(s / 3600)h \(String(format: "%02dm", (s % 3600) / 60))" }
        if s >= 60 { return "\(s / 60)m \(String(format: "%02ds", s % 60))" }
        return "\(s)s"
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    /// Left-aligned text table with a header row. Columns are padded to their widest cell.
    static func table(_ header: [String], _ rows: [[String]]) -> String {
        let all = [header] + rows
        let columns = all.map(\.count).max() ?? 0
        var widths = Array(repeating: 0, count: columns)
        for row in all {
            for (i, cell) in row.enumerated() { widths[i] = max(widths[i], cell.count) }
        }
        return all.map { row in
            row.enumerated().map { i, cell in
                i == row.count - 1 ? cell : cell.padding(toLength: widths[i], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }

    /// One-line memory summary used by `status` and `mem`:
    /// "guest 1.10 GiB/1.92 GiB used (avail 42%) · engine 4.28 GiB (peak 4.40 GiB) · cpu 3% · host normal".
    static func memoryLine(guestTotal: UInt64?, guestAvailable: UInt64?, engineFootprint: UInt64?,
                           enginePeak: UInt64?, cpuPercent: Double?, hostPressure: MemoryPressureLevel?,
                           swapUsed: UInt64? = nil) -> String {
        var parts: [String] = []
        if let total = guestTotal, let avail = guestAvailable, total > 0 {
            let used = total > avail ? total - avail : 0
            var s = "guest \(ByteCount.format(used))/\(ByteCount.format(total)) used (avail \(percent(Double(avail) / Double(total))))"
            if let swapUsed, swapUsed > 0 { s += ", zram \(ByteCount.format(swapUsed))" }
            parts.append(s)
        } else {
            parts.append("guest -")
        }
        if let fp = engineFootprint {
            var s = "engine \(ByteCount.format(fp))"
            if let peak = enginePeak, peak > fp { s += " (peak \(ByteCount.format(peak)))" }
            parts.append(s)
        } else {
            parts.append("engine -")
        }
        if let cpu = cpuPercent { parts.append(String(format: "cpu %.0f%%", cpu)) }
        if let hp = hostPressure { parts.append("host \(hp)") }
        return parts.joined(separator: " · ")
    }
}

/// An error with a message for the user and a process exit code. Thrown by commands; `EmuuCLI`
/// prints it as `emuu: <message>` and exits with `code`.
struct CLIError: Error, LocalizedError, Equatable {
    var message: String
    var code: Int32 = 1
    var errorDescription: String? { message }

    init(_ message: String, code: Int32 = 1) {
        self.message = message
        self.code = code
    }
}

func describe(_ error: Error) -> String {
    if let e = error as? LocalizedError, let d = e.errorDescription { return d }
    return "\(error)"
}
