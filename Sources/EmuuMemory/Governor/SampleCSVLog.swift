import Foundation
import EmuuBase

/// Compact per-sample record kept in the governor's in-memory history (fixed size, no arrays).
public struct HistoryPoint: Codable, Sendable, Hashable {
    public var timestamp: Date
    public var monotonic: Duration
    public var level: MemoryPressureLevel
    public var tier: GovernorTier
    public var guestTotalBytes: UInt64?
    public var guestAvailableBytes: UInt64?
    public var guestSwapUsedBytes: UInt64?
    public var psiSomeAvg10: Double?
    public var cachedProcessCount: Int?
    public var engineFootprintBytes: UInt64?
    public var engineLifetimeMaxFootprintBytes: UInt64?
    public var engineCPUPercent: Double?
    public var hostPressure: MemoryPressureLevel?
    public var hostFreeBytes: UInt64?
    public var hostCompressedBytes: UInt64?
    public var hostSwapUsedBytes: UInt64?
    public var sampleRoundTrip: Duration?

    public init(timestamp: Date, monotonic: Duration, level: MemoryPressureLevel, tier: GovernorTier) {
        self.timestamp = timestamp
        self.monotonic = monotonic
        self.level = level
        self.tier = tier
    }

    public static let csvHeader = "timestamp,uptime_s,level,tier,guest_total_mib,guest_avail_mib,guest_swap_used_mib,psi_some10,cached_procs,engine_footprint_mib,engine_peak_mib,engine_cpu_pct,host_pressure,host_free_mib,host_compressed_mib,host_swap_used_mib,sample_ms"

    public var csvRow: String {
        func mib(_ b: UInt64?) -> String { b.map { String(format: "%.1f", Double($0) / 1_048_576) } ?? "" }
        func num(_ d: Double?) -> String { d.map { String(format: "%.2f", $0) } ?? "" }
        let iso = ISO8601DateFormatter.emuu.string(from: timestamp)
        return [
            iso, String(format: "%.1f", monotonic.timeInterval), level.description, String(tier.rawValue),
            mib(guestTotalBytes), mib(guestAvailableBytes), mib(guestSwapUsedBytes), num(psiSomeAvg10),
            cachedProcessCount.map(String.init) ?? "",
            mib(engineFootprintBytes), mib(engineLifetimeMaxFootprintBytes), num(engineCPUPercent),
            hostPressure?.description ?? "", mib(hostFreeBytes), mib(hostCompressedBytes), mib(hostSwapUsedBytes),
            sampleRoundTrip.map { String(Int(($0.timeInterval * 1000).rounded())) } ?? "",
        ].joined(separator: ",")
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let emuu: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

/// Appends `HistoryPoint` rows to a CSV file and rotates by size: `name.csv`, `name.1.csv`, … up
/// to `maxFiles` files, so disk use is bounded too. Not thread-safe by itself; the governor actor owns it.
public final class SampleCSVLog: @unchecked Sendable {
    public let url: URL
    public let maxBytes: UInt64
    public let maxFiles: Int
    private var handle: FileHandle?
    private var size: UInt64 = 0
    private let lock = NSLock()

    public init(url: URL, maxBytes: UInt64 = 4 * ByteCount.mib, maxFiles: Int = 3) {
        self.url = url
        self.maxBytes = max(1024, maxBytes)
        self.maxFiles = max(1, maxFiles)
    }

    deinit { try? handle?.close() }

    public func rotatedURL(_ index: Int) -> URL {
        guard index > 0 else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "csv" : url.pathExtension
        return url.deletingLastPathComponent().appendingPathComponent("\(base).\(index).\(ext)")
    }

    public func append(_ point: HistoryPoint) throws {
        lock.lock()
        defer { lock.unlock() }
        if handle == nil { try open() }
        let line = Data((point.csvRow + "\n").utf8)
        if size + UInt64(line.count) > maxBytes, size > 0 {
            try rotate()
        }
        try handle?.write(contentsOf: line)
        size += UInt64(line.count)
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }

    private func open() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: Data((HistoryPoint.csvHeader + "\n").utf8)) else {
                throw EmuuError.io(path: url.path, message: "cannot create CSV log")
            }
        }
        do {
            let h = try FileHandle(forWritingTo: url)
            size = try h.seekToEnd()
            handle = h
        } catch {
            throw EmuuError.io(path: url.path, message: error.localizedDescription)
        }
    }

    private func rotate() throws {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        if maxFiles > 1 {
            try? fm.removeItem(at: rotatedURL(maxFiles - 1))
            for i in stride(from: maxFiles - 2, through: 0, by: -1) {
                let src = rotatedURL(i)
                if fm.fileExists(atPath: src.path) { try? fm.moveItem(at: src, to: rotatedURL(i + 1)) }
            }
        } else {
            try? fm.removeItem(at: url)
        }
        try open()
    }
}
