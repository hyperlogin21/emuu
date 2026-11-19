import Foundation
import os

public enum LogLevel: Int, Codable, Sendable, Hashable, Comparable, CaseIterable, CustomStringConvertible {
    case debug = 0, info, notice, warning, error

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String {
        switch self {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .warning: return "warning"
        case .error: return "error"
        }
    }

    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .notice: return .default
        case .warning: return .error
        case .error: return .fault
        }
    }
}

/// Lightweight logger: always goes to unified logging (`log stream --predicate 'subsystem == "dev.emuu"'`),
/// and additionally to the global `LogFileSink` when one is installed via `EmuuLogging.bootstrap`.
///
/// Messages are autoclosures and are only built when some destination wants them.
/// Messages are logged as public (Emuu logs contain no secrets; never log credentials/tokens).
public struct EmuuLogger: Sendable {
    public static let subsystem = "dev.emuu"

    public let category: String
    private let osLog: OSLog
    private let logger: Logger

    public init(category: String) {
        self.category = category
        self.osLog = OSLog(subsystem: Self.subsystem, category: category)
        self.logger = Logger(osLog)
    }

    public func log(_ level: LogLevel, _ message: @autoclosure () -> String) {
        let sink = EmuuLogging.activeFileSink(for: level)
        let osWants = level != .debug || osLog.isEnabled(type: .debug)
        guard osWants || sink != nil else { return }
        let text = message()
        if osWants { logger.log(level: level.osLogType, "\(text, privacy: .public)") }
        sink?.write(level: level, category: category, message: text)
    }

    public func debug(_ message: @autoclosure () -> String) { log(.debug, message()) }
    public func info(_ message: @autoclosure () -> String) { log(.info, message()) }
    public func notice(_ message: @autoclosure () -> String) { log(.notice, message()) }
    public func warning(_ message: @autoclosure () -> String) { log(.warning, message()) }
    public func error(_ message: @autoclosure () -> String) { log(.error, message()) }
}

/// Global logging configuration.
public enum EmuuLogging {
    private struct Config {
        var sink: LogFileSink?
        var minimumFileLevel: LogLevel = .info
    }

    private static let config = Locked(Config())

    /// Installs (or removes, with nil) the file sink. Typically called once at startup with
    /// `LogFileSink(url: paths.mainLogFile)`.
    public static func bootstrap(fileSink: LogFileSink?, minimumFileLevel: LogLevel = .info) {
        config.set(Config(sink: fileSink, minimumFileLevel: minimumFileLevel))
    }

    public static var fileSink: LogFileSink? { config.current.sink }

    static func activeFileSink(for level: LogLevel) -> LogFileSink? {
        config.withLock { c in level >= c.minimumFileLevel ? c.sink : nil }
    }
}

/// Append-only log file with size-capped rotation: `emuu.log`, `emuu.1.log` … `emuu.<maxFiles-1>.log`.
/// Total disk use is bounded by roughly `maxBytes * maxFiles`.
public final class LogFileSink: @unchecked Sendable {
    public let url: URL
    public let maxBytes: UInt64
    public let maxFiles: Int

    private let lock = NSLock()
    private var handle: FileHandle?
    private var currentSize: UInt64 = 0
    private let formatter: ISO8601DateFormatter

    public init(url: URL, maxBytes: UInt64 = 4 * ByteCount.mib, maxFiles: Int = 3) {
        self.url = url
        self.maxBytes = max(1024, maxBytes)
        self.maxFiles = max(1, maxFiles)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.formatter = f
    }

    deinit {
        try? handle?.close()
    }

    /// Path of rotated file `index` (0 = live file).
    public func rotatedURL(_ index: Int) -> URL {
        guard index > 0 else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let name = ext.isEmpty ? "\(base).\(index)" : "\(base).\(index).\(ext)"
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    public func write(level: LogLevel, category: String, message: String, date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(formatter.string(from: date)) [\(level)] [\(category)] \(message)\n"
        let data = Data(line.utf8)
        if handle == nil { openLocked() }
        if currentSize > 0, currentSize + UInt64(data.count) > maxBytes {
            rotateLocked()
        }
        guard let h = handle else { return }
        do {
            try h.write(contentsOf: data)
            currentSize += UInt64(data.count)
        } catch {
            // Disk full or file removed underneath us: reopen next time.
            try? h.close()
            handle = nil
        }
    }

    /// Flushes to disk.
    public func flush() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.synchronize()
    }

    private func openLocked() {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        currentSize = (try? h.seekToEnd()) ?? 0
        handle = h
    }

    private func rotateLocked() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        if maxFiles == 1 {
            try? fm.removeItem(at: url)
        } else {
            try? fm.removeItem(at: rotatedURL(maxFiles - 1))
            for i in stride(from: maxFiles - 2, through: 0, by: -1) {
                let src = rotatedURL(i)
                if fm.fileExists(atPath: src.path) {
                    try? fm.moveItem(at: src, to: rotatedURL(i + 1))
                }
            }
        }
        openLocked()
    }
}
