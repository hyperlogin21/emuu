import Foundation

/// An installed Android package as reported by `pm`/`dumpsys package`.
public struct PackageInfo: Codable, Sendable, Hashable, Identifiable {
    public var packageName: String
    public var versionName: String?
    public var versionCode: Int64?
    /// Human label, when resolvable (often unavailable without aapt; may be nil).
    public var label: String?
    public var isSystem: Bool
    public var isEnabled: Bool
    /// Installer package (e.g. `com.android.vending` for Play Store installs, nil for adb sideloads).
    public var installerPackage: String?
    /// Base + split APK paths on the device.
    public var apkPaths: [String]

    public var id: String { packageName }

    public init(
        packageName: String, versionName: String? = nil, versionCode: Int64? = nil, label: String? = nil,
        isSystem: Bool = false, isEnabled: Bool = true, installerPackage: String? = nil, apkPaths: [String] = []
    ) {
        self.packageName = packageName
        self.versionName = versionName
        self.versionCode = versionCode
        self.label = label
        self.isSystem = isSystem
        self.isEnabled = isEnabled
        self.installerPackage = installerPackage
        self.apkPaths = apkPaths
    }

    public static let playStorePackage = "com.android.vending"
    public var isFromPlayStore: Bool { installerPackage == Self.playStorePackage }
}

/// Where an install comes from.
public enum InstallSource: Codable, Sendable, Hashable, CustomStringConvertible {
    /// A single `.apk`.
    case apk(URL)
    /// A set of split APKs for one package (base + config splits), installed with `install-multiple`.
    case splitAPKs([URL])
    /// `.xapk` bundle (zip with manifest.json, APKs, optional OBB under Android/obb).
    case xapk(URL)
    /// `.apks` bundle (bundletool / SAI output: zip of split APKs).
    case apks(URL)
    /// `.apkm` bundle (APKMirror; zip of split APKs — encrypted variants are unsupported).
    case apkm(URL)
    /// Open the Play Store listing for the package on the device (user completes install there).
    case playStore(packageName: String)

    /// Infers the source kind from a file extension (case-insensitive). nil for unknown extensions.
    public static func detect(fileURL: URL) -> InstallSource? {
        switch fileURL.pathExtension.lowercased() {
        case "apk": return .apk(fileURL)
        case "xapk": return .xapk(fileURL)
        case "apks": return .apks(fileURL)
        case "apkm": return .apkm(fileURL)
        default: return nil
        }
    }

    public var description: String {
        switch self {
        case .apk(let url): return "apk \(url.lastPathComponent)"
        case .splitAPKs(let urls): return "split apks (\(urls.count))"
        case .xapk(let url): return "xapk \(url.lastPathComponent)"
        case .apks(let url): return "apks \(url.lastPathComponent)"
        case .apkm(let url): return "apkm \(url.lastPathComponent)"
        case .playStore(let pkg): return "play store \(pkg)"
        }
    }
}

/// Outcome of an install attempt. Failures with an adb/PackageManager code (e.g.
/// `INSTALL_FAILED_NO_MATCHING_ABIS`) are reported here rather than thrown, so batch installs can continue;
/// infrastructure failures (device offline, adb missing) are thrown as `EmuuError`.
public struct InstallResult: Codable, Sendable, Hashable {
    public enum Status: Codable, Sendable, Hashable {
        case installed
        /// The Play Store listing was opened; installation continues on the device.
        case openedInPlayStore
        case failed(code: String, message: String)
    }

    public var source: InstallSource
    public var packageName: String?
    public var status: Status
    /// Number of APK files pushed (1 for plain APKs).
    public var apkCount: Int
    /// Number of OBB files copied (XAPK).
    public var obbCount: Int
    public var duration: Duration

    public init(source: InstallSource, packageName: String?, status: Status, apkCount: Int = 0, obbCount: Int = 0, duration: Duration = .zero) {
        self.source = source
        self.packageName = packageName
        self.status = status
        self.apkCount = apkCount
        self.obbCount = obbCount
        self.duration = duration
    }

    public var succeeded: Bool {
        switch status {
        case .installed, .openedInPlayStore: return true
        case .failed: return false
        }
    }
}
