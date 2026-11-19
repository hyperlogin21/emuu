import Foundation

extension Duration {
    /// The duration as fractional seconds (lossy below nanoseconds, which is irrelevant here).
    public var timeInterval: TimeInterval {
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }

    /// Builds a `Duration` from fractional seconds.
    public static func fromTimeInterval(_ interval: TimeInterval) -> Duration {
        .nanoseconds(Int64((interval * 1e9).rounded()))
    }

    public static func minutes(_ m: Int) -> Duration { .seconds(m * 60) }
    public static func hours(_ h: Int) -> Duration { .seconds(h * 3600) }
}

/// Byte-count helpers. Emuu uses bytes (`UInt64`) as the canonical unit everywhere in contracts.
public enum ByteCount {
    public static let kib: UInt64 = 1024
    public static let mib: UInt64 = 1024 * 1024
    public static let gib: UInt64 = 1024 * 1024 * 1024

    public static func mib(_ value: Int) -> UInt64 { UInt64(max(0, value)) * mib }
    public static func kib(_ value: UInt64) -> UInt64 { value * kib }

    /// Human-readable rendering ("512 MiB", "1.50 GiB").
    public static func format(_ bytes: UInt64) -> String {
        let b = Double(bytes)
        if bytes >= gib { return String(format: "%.2f GiB", b / Double(gib)) }
        if bytes >= mib { return String(format: "%.0f MiB", b / Double(mib)) }
        if bytes >= kib { return String(format: "%.0f KiB", b / Double(kib)) }
        return "\(bytes) B"
    }

    /// Signed variant used for deltas/trends.
    public static func format(signed bytes: Int64) -> String {
        bytes < 0 ? "-" + format(UInt64(-bytes)) : "+" + format(UInt64(bytes))
    }
}
