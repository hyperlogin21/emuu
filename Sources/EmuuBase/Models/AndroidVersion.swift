import Foundation

/// An Android platform version as the SDK names its system images: API level plus an optional minor level
/// (`35`, `36`, `36.1`). Equality and ordering are numeric, so "37" and "37.0" are the same version.
public struct AndroidVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public var major: Int
    public var minor: Int

    public init(major: Int, minor: Int = 0) {
        self.major = major
        self.minor = minor
    }

    /// Parses what a user types: `35`, `36.1`, `android-35`, `API 35`, `api35`, `Android 35`.
    /// Rejects SDK variants that are not plain platform images (`android-35-ext15`, `36.1-ps16k`, codenames).
    public init?(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["android-", "android ", "android", "api-", "api ", "api"] where t.hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]), major > 0, major < 1000 else { return nil }
        let minor = parts.count == 2 ? Int(parts[1]) : 0
        guard let minor else { return nil }
        self.init(major: major, minor: minor)
    }

    /// Parses an SDK `system-images/<dir>` name such as `android-36.1` (nil for `android-35-ext15`, codenames…).
    public init?(apiDirectory: String) {
        guard apiDirectory.hasPrefix("android-") else { return nil }
        self.init(String(apiDirectory.dropFirst("android-".count)))
    }

    /// `35`, `36.1` (the form `emuu create --android` takes).
    public var number: String { minor == 0 ? "\(major)" : "\(major).\(minor)" }

    /// The SDK directory / package component. The SDK writes `android-36.1` but also `android-37.0`, so a version
    /// known only from user input uses the short form; resolve against installed or available images when it matters.
    public var defaultAPIDirectory: String { "android-\(number)" }

    /// Consumer name: "Android 15", "Android 16 QPR2" (API 36.1 is the Android 16 QPR2 platform).
    public var marketingName: String {
        let base: Int? = major >= 21 ? Self.releaseNumber(api: major) : nil
        guard let base else { return "API \(number)" }
        return minor == 0 ? "Android \(base)" : "Android \(base) QPR\(minor + 1)"
    }

    /// "Android 15 (API 35)".
    public var label: String { "\(marketingName) (API \(number))" }

    public var description: String { number }

    public static func < (a: AndroidVersion, b: AndroidVersion) -> Bool {
        (a.major, a.minor) < (b.major, b.minor)
    }

    /// API level → Android release number for the levels Emuu can meet.
    static func releaseNumber(api: Int) -> Int? {
        switch api {
        case 21, 22: return 5
        case 23: return 6
        case 24, 25: return 7
        case 26, 27: return 8
        case 28: return 9
        case 29: return 10
        case 30: return 11
        case 31, 32: return 12
        case 33...: return api - 20
        default: return nil
        }
    }
}

extension SystemImageRef {
    /// The Android version of this image, when its directory is a plain platform directory (`android-35`).
    public var androidVersion: AndroidVersion? { AndroidVersion(apiDirectory: apiDirectory) }

    /// "Android 15 (API 35)", or the directory name for images Emuu cannot parse.
    public var androidLabel: String { androidVersion?.label ?? apiDirectory }

    /// The Google Play arm64 image for `version` (the only kind Emuu creates instances from).
    public static func playStore(_ version: AndroidVersion, apiDirectory: String? = nil) -> SystemImageRef {
        SystemImageRef(apiDirectory: apiDirectory ?? version.defaultAPIDirectory, tag: "google_apis_playstore", abi: "arm64-v8a")
    }
}
