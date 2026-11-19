import Foundation
import EmuuBase

/// Tolerant parsers for guest `/proc` text and `dumpsys` output. They never throw on unexpected
/// lines: unknown or malformed lines are skipped, and missing fields come back as nil/0.
public enum GuestParsers {
    // MARK: /proc/meminfo

    /// Parses `/proc/meminfo` into a key → bytes map ("MemTotal: 2014536 kB" → 2014536*1024).
    /// Values without a unit (e.g. HugePages_Total) are kept as-is.
    public static func meminfo(_ text: String) -> [String: UInt64] {
        var out: [String: UInt64] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            guard let colon = raw.firstIndex(of: ":") else { continue }
            let key = raw[..<colon].trimmingCharacters(in: .whitespaces)
            let rest = raw[raw.index(after: colon)...].split(separator: " ", omittingEmptySubsequences: true)
            guard !key.isEmpty, let first = rest.first, let n = UInt64(first) else { continue }
            let unit = rest.count > 1 ? rest[1].lowercased() : ""
            let mult: UInt64
            switch unit {
            case "kb": mult = 1024
            case "mb": mult = 1024 * 1024
            case "gb": mult = 1024 * 1024 * 1024
            default: mult = 1
            }
            let (v, overflow) = n.multipliedReportingOverflow(by: mult)
            out[key] = overflow ? UInt64.max : v
        }
        return out
    }

    /// Builds `GuestMemory` from a meminfo map. Returns nil if MemTotal is missing.
    /// When MemAvailable is absent (very old kernels) it is estimated as Free + Cached + Buffers.
    public static func guestMemory(meminfo m: [String: UInt64]) -> GuestMemory? {
        guard let total = m["MemTotal"], total > 0 else { return nil }
        let free = m["MemFree"] ?? 0
        let cached = m["Cached"] ?? 0
        let buffers = m["Buffers"] ?? 0
        let available = min(total, m["MemAvailable"] ?? (free + cached + buffers))
        return GuestMemory(
            totalBytes: total, freeBytes: free, availableBytes: available,
            cachedBytes: cached, buffersBytes: buffers,
            swapTotalBytes: m["SwapTotal"] ?? 0, swapFreeBytes: m["SwapFree"] ?? 0
        )
    }

    // MARK: /proc/pressure/memory

    /// Parses PSI text:
    /// ```
    /// some avg10=0.00 avg60=0.00 avg300=0.00 total=0
    /// full avg10=0.00 avg60=0.00 avg300=0.00 total=0
    /// ```
    /// Returns nil unless at least the `some` line is present. A missing `full` line reads as zeros.
    public static func pressureStall(_ text: String) -> PressureStall? {
        var some: [String: Double]?
        var full: [String: Double]?
        for raw in text.split(whereSeparator: \.isNewline) {
            let parts = raw.split(separator: " ", omittingEmptySubsequences: true)
            guard let kind = parts.first else { continue }
            var values: [String: Double] = [:]
            for p in parts.dropFirst() {
                let kv = p.split(separator: "=", maxSplits: 1)
                if kv.count == 2, let d = Double(kv[1]) { values[String(kv[0])] = d }
            }
            guard values["avg10"] != nil else { continue }
            if kind == "some" { some = values } else if kind == "full" { full = values }
        }
        guard let some else { return nil }
        let f = full ?? [:]
        return PressureStall(
            someAvg10: some["avg10"] ?? 0, someAvg60: some["avg60"] ?? 0, someAvg300: some["avg300"] ?? 0,
            fullAvg10: f["avg10"] ?? 0, fullAvg60: f["avg60"] ?? 0, fullAvg300: f["avg300"] ?? 0
        )
    }

    // MARK: /proc/vmstat

    /// Parses `key value` lines; non-numeric lines are skipped.
    public static func vmstat(_ text: String) -> [String: UInt64] {
        var out: [String: UInt64] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let parts = raw.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let v = UInt64(parts[1]) else { continue }
            out[String(parts[0])] = v
        }
        return out
    }

    // MARK: process scan

    /// Result of the cheap `/proc/<pid>/oom_score_adj` scan run on the device.
    public struct ProcessScan: Sendable, Hashable {
        /// Process names with oom_score_adj == 0 (FOREGROUND_APP_ADJ), in scan order.
        public var foreground: [String]
        /// Number of processes with oom_score_adj >= 900 (CACHED_APP_MIN_ADJ).
        public var cachedCount: Int?
    }

    /// Parses the output of `GuestSampler.processScanScript`: lines `fg <name>` and `cached <n>`.
    public static func processScan(_ text: String) -> ProcessScan {
        var fg: [String] = []
        var cached: Int?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces.union(.controlCharacters))
            if line.hasPrefix("fg ") {
                let name = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces.union(.controlCharacters))
                if !name.isEmpty, !fg.contains(name) { fg.append(name) }
            } else if line.hasPrefix("cached ") {
                cached = Int(line.dropFirst(7).trimmingCharacters(in: .whitespaces))
            }
        }
        return ProcessScan(foreground: fg, cachedCount: cached)
    }

    /// Parses `adbd <children> <lastpid>` from `GuestSampler.adbProbeScript`.
    public static func adbProbe(_ text: String) -> (children: Int, lastPID: Int?)? {
        for raw in text.split(whereSeparator: \.isNewline) {
            let f = raw.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 2, f[0] == "adbd", let n = Int(f[1]) else { continue }
            let pid: Int? = f.count >= 3 ? Int(f[2].split(separator: "/").last ?? "") : nil
            return (n, pid)
        }
        return nil
    }

    /// Lines `<adj> <name>` from the background-process scan used by effectors.
    public struct ProcessEntry: Sendable, Hashable {
        public var adj: Int
        public var name: String
    }

    public static func processEntries(_ text: String) -> [ProcessEntry] {
        var out: [ProcessEntry] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let parts = raw.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let adj = Int(parts[0]) else { continue }
            let name = parts[1].trimmingCharacters(in: .whitespaces.union(.controlCharacters))
            guard !name.isEmpty else { continue }
            out.append(ProcessEntry(adj: adj, name: name))
        }
        return out
    }

    /// Package name from a process name: "com.foo.bar:remote" → "com.foo.bar". Returns nil for
    /// names that are not package-like (kernel threads, native daemons, paths).
    public static func packageName(fromProcessName name: String) -> String? {
        let base = name.split(separator: ":", maxSplits: 1).first.map(String.init) ?? name
        guard base.contains("."), !base.hasPrefix("/"), !base.hasPrefix("["),
              base.unicodeScalars.allSatisfy({ ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "." || $0 == "_" }),
              let f = base.unicodeScalars.first, CharacterSet.letters.contains(f)
        else { return nil }
        return base
    }

    // MARK: dumpsys meminfo -c

    /// Parses the compact (`dumpsys meminfo -c`) per-process lines:
    /// `proc,<category>,<name>,<pid>,<pss KB>,…`. Categories include `fore`, `vis`, `perc`, `cch`, …
    /// The foreground flag is set for category `fore` (or `top`).
    public static func dumpsysMeminfoCompact(_ text: String) -> [AppMemoryUsage] {
        // API 36 prints every process twice: an RSS pass ("Total RSS by OOM adjustment") and then the PSS pass,
        // each with its own `oom,`/`proc,` lines (verified on android-36.1: `proc,sys,system,3596,275996` then
        // `proc,sys,system,3596,190539`). Keep one row per pid with the smaller value: PSS never exceeds RSS.
        var byPID: [Int32: AppMemoryUsage] = [:]
        var order: [Int32] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let f = raw.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 5, f[0] == "proc", let pid = Int32(f[3]), let pssKB = UInt64(f[4].trimmingCharacters(in: .whitespaces)) else { continue }
            let category = String(f[1])
            let row = AppMemoryUsage(packageName: String(f[2]), pid: pid, pssBytes: pssKB * 1024,
                                     isForeground: category == "fore" || category == "top")
            if let existing = byPID[pid] {
                if row.pssBytes < existing.pssBytes { byPID[pid] = row }
            } else {
                byPID[pid] = row
                order.append(pid)
            }
        }
        return order.compactMap { byPID[$0] }.sorted { $0.pssBytes > $1.pssBytes }
    }

    // MARK: sectioned output

    /// Splits the combined sampler output (`@@<name>` marker lines) into sections.
    public static func sections(_ text: String, marker: String = "@@") -> [String: String] {
        var out: [String: String] = [:]
        var current: String?
        var buf: [Substring] = []
        func flush() {
            if let c = current { out[c] = buf.joined(separator: "\n") }
            buf.removeAll(keepingCapacity: true)
        }
        for line in text.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(marker) {
                flush()
                current = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            } else if current != nil {
                buf.append(line)
            }
        }
        flush()
        return out
    }
}
