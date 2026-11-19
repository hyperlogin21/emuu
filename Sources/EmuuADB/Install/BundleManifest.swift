import Foundation
import EmuuBase

/// `manifest.json` of an `.xapk` (APKPure format, versions 1 and 2) or `info.json` of an `.apkm`.
/// Only the fields Emuu uses are decoded; unknown fields are ignored.
public struct BundleManifest: Sendable, Hashable {
    public struct Expansion: Sendable, Hashable {
        /// Entry inside the archive (e.g. `Android/obb/com.game/main.12.com.game.obb`).
        public var file: String
        /// Path relative to external storage (`/sdcard/`); usually equal to `file`.
        public var installPath: String
    }

    public var packageName: String?
    public var versionName: String?
    public var versionCode: Int64?
    /// APK entry names listed by the manifest (XAPK v2 `split_apks[].file`), in order.
    public var apkFiles: [String]
    public var expansions: [Expansion]

    public static func parseXAPK(_ data: Data) throws -> BundleManifest {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EmuuError.install(code: "EMUU_BAD_XAPK", message: "The XAPK's manifest.json is not valid JSON.")
        }
        var m = BundleManifest(packageName: json["package_name"] as? String,
                               versionName: json["version_name"] as? String,
                               versionCode: int64(json["version_code"]),
                               apkFiles: [], expansions: [])
        if let splits = json["split_apks"] as? [[String: Any]] {
            m.apkFiles = splits.compactMap { $0["file"] as? String }
        }
        if let exps = json["expansions"] as? [[String: Any]] {
            m.expansions = exps.compactMap { e in
                guard let file = e["file"] as? String else { return nil }
                return Expansion(file: file, installPath: (e["install_path"] as? String) ?? file)
            }
        }
        return m
    }

    public static func parseAPKMInfo(_ data: Data) -> BundleManifest? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return BundleManifest(packageName: (json["pname"] as? String) ?? (json["package_name"] as? String),
                              versionName: (json["release_version"] as? String) ?? (json["versionname"] as? String),
                              versionCode: int64(json["versioncode"]) ?? int64(json["version_code"]),
                              apkFiles: [], expansions: [])
    }

    private static func int64(_ any: Any?) -> Int64? {
        if let n = any as? NSNumber { return n.int64Value }
        if let s = any as? String { return Int64(s) }
        return nil
    }
}
