import Foundation
import EmuuBase

/// Which Android versions Emuu creates instances from, which are installed, which can be installed, and which
/// one new instances get by default. Emuu only creates instances from the Google Play arm64 images
/// (`system-images;android-<v>;google_apis_playstore;arm64-v8a`), never from the 16 KB-page (`_ps16k`), tablet,
/// automotive, XR or `-extNN` variants.
public enum SystemImageCatalog {
    /// A version Emuu knows and supports.
    public struct Entry: Sendable, Hashable {
        public var version: AndroidVersion
        /// SDK directory (`android-36.1`).
        public var apiDirectory: String
        /// Approximate download size (Google's repository, sys-img2-3.xml, 2026-11).
        public var downloadBytes: UInt64
        /// Short note shown by `emuu images list`.
        public var note: String?

        public var ref: SystemImageRef { .playStore(version, apiDirectory: apiDirectory) }
    }

    /// Versions Emuu supports with engine 36.4.9. 36.1 is the version Emuu was developed on; 35 was smoke-tested
    /// (boot, display, adb, hibernate/resume, clone); 34 and 36 are expected to work the same way but were not run.
    public static let supported: [Entry] = [
        Entry(version: AndroidVersion(major: 34), apiDirectory: "android-34", downloadBytes: 1_550_000_000, note: "not tested by Emuu"),
        Entry(version: AndroidVersion(major: 35), apiDirectory: "android-35", downloadBytes: 1_790_000_000, note: nil),
        Entry(version: AndroidVersion(major: 36), apiDirectory: "android-36", downloadBytes: 1_890_000_000, note: "not tested by Emuu"),
        Entry(version: AndroidVersion(major: 36, minor: 1), apiDirectory: "android-36.1", downloadBytes: 1_960_000_000, note: nil),
    ]

    /// New instances get this version when it is installed (`SystemImageRef.playStoreDefault`).
    public static var defaultVersion: AndroidVersion { SystemImageRef.playStoreDefault.androidVersion ?? AndroidVersion(major: 36, minor: 1) }

    public static func entry(for version: AndroidVersion) -> Entry? { supported.first { $0.version == version } }

    /// True for the image kind Emuu creates instances from.
    public static func isEmuuImage(_ ref: SystemImageRef) -> Bool {
        ref.tag == "google_apis_playstore" && ref.abi == "arm64-v8a" && ref.androidVersion != nil
    }

    /// Installed Google Play arm64 images, newest first.
    public static func installed(in sdk: AndroidSDK) -> [InstalledSystemImage] {
        installed(from: SDKLocator.installedImages(in: sdk))
    }

    /// Pure filter + order of `installed(in:)`.
    public static func installed(from images: [InstalledSystemImage]) -> [InstalledSystemImage] {
        images.filter { isEmuuImage($0.ref) }
            .sorted { ($0.ref.androidVersion ?? .init(major: 0)) > ($1.ref.androidVersion ?? .init(major: 0)) }
    }

    /// The image new instances get: the default version if installed, else the newest installed supported
    /// version, else the newest installed Google Play arm64 image. nil when none is installed.
    public static func defaultImage(installed images: [InstalledSystemImage]) -> InstalledSystemImage? {
        let mine = installed(from: images)
        if let d = mine.first(where: { $0.ref.androidVersion == defaultVersion }) { return d }
        if let s = mine.first(where: { img in supported.contains { $0.version == img.ref.androidVersion } }) { return s }
        return mine.first
    }

    /// Errors from `resolve`.
    public enum ResolveError: Error, Equatable, LocalizedError {
        case unparsable(String)
        case notInstalled(AndroidVersion, supported: Bool)
        case noImageInstalled

        public var errorDescription: String? {
            switch self {
            case .unparsable(let text):
                return "'\(text)' is not an Android version. Use an API level such as \(SystemImageCatalog.supported.map(\.version.number).joined(separator: ", "))."
            case .notInstalled(let v, let supported):
                return supported
                    ? "\(v.label) is not installed. Install it with `emuu images install \(v.number)` (about \(ByteCount.format(SystemImageCatalog.entry(for: v)?.downloadBytes ?? 2_000_000_000)) download)."
                    : "\(v.label) is not installed, and Emuu does not support it (supported: \(SystemImageCatalog.supported.map(\.version.number).joined(separator: ", ")))."
            case .noImageInstalled:
                return "No Google Play arm64 system image is installed. Install one with `emuu images install \(SystemImageCatalog.defaultVersion.number)`."
            }
        }
    }

    /// The image for `emuu create --android <text>` (nil text: the default image). Any installed Google Play arm64
    /// image of that version is accepted, also one Emuu does not list as supported.
    public static func resolve(_ text: String?, installed images: [InstalledSystemImage]) throws -> InstalledSystemImage {
        guard let text else {
            guard let d = defaultImage(installed: images) else { throw ResolveError.noImageInstalled }
            return d
        }
        guard let version = AndroidVersion(text) else { throw ResolveError.unparsable(text) }
        if let hit = installed(from: images).first(where: { $0.ref.androidVersion == version }) { return hit }
        throw ResolveError.notInstalled(version, supported: entry(for: version) != nil)
    }

    // MARK: sdkmanager output

    /// Google Play arm64 versions listed by `sdkmanager --list` (installed and available sections alike), with
    /// the SDK directory each uses. Variants (`_ps16k`, `-extNN`, tablet…) are skipped.
    public static func parseSDKManagerList(_ output: String) -> [(version: AndroidVersion, apiDirectory: String)] {
        var seen: [AndroidVersion: String] = [:]
        for raw in output.split(whereSeparator: \.isNewline) {
            let first = raw.split(separator: "|").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            let parts = first.split(separator: ";").map(String.init)
            guard parts.count == 4, parts[0] == "system-images" else { continue }
            let ref = SystemImageRef(apiDirectory: parts[1], tag: parts[2], abi: parts[3])
            guard isEmuuImage(ref), let v = ref.androidVersion else { continue }
            seen[v] = parts[1]
        }
        return seen.map { ($0.key, $0.value) }.sorted { $0.version > $1.version }
    }

    // MARK: Listing

    /// One line of `emuu images list`.
    public struct Row: Sendable, Hashable, Codable {
        public var version: String
        public var name: String
        public var package: String
        public var installed: Bool
        public var supported: Bool
        public var isDefault: Bool
        /// Bytes on disk when installed, else the approximate download size (when known).
        public var sizeBytes: UInt64?
        public var revision: String?
        public var instances: [String]
        public var note: String?

        public init(version: String, name: String, package: String, installed: Bool, supported: Bool, isDefault: Bool,
                    sizeBytes: UInt64?, revision: String?, instances: [String], note: String?) {
            self.version = version; self.name = name; self.package = package; self.installed = installed
            self.supported = supported; self.isDefault = isDefault; self.sizeBytes = sizeBytes; self.revision = revision
            self.instances = instances; self.note = note
        }
    }

    /// Merges installed images, versions sdkmanager offers (nil: not queried) and the built-in catalogue, with the
    /// instances that use each image (pure; unit-tested). Newest first.
    public static func rows(installed images: [InstalledSystemImage], available: [(version: AndroidVersion, apiDirectory: String)]?,
                            instances: [InstanceConfig], sizeOnDisk: (URL) -> UInt64? = { _ in nil }) -> [Row] {
        let mine = installed(from: images)
        let def = defaultImage(installed: images)?.ref.androidVersion ?? defaultVersion
        var dirs: [AndroidVersion: String] = [:]
        for e in supported { dirs[e.version] = e.apiDirectory }
        for a in available ?? [] { dirs[a.version] = a.apiDirectory }
        for i in mine { if let v = i.ref.androidVersion { dirs[v] = i.ref.apiDirectory } }
        return dirs.keys.sorted(by: >).map { v in
            let img = mine.first { $0.ref.androidVersion == v }
            let entry = entry(for: v)
            let ref = img?.ref ?? .playStore(v, apiDirectory: dirs[v])
            let users = instances.filter { $0.systemImage.androidVersion == v && isEmuuImage($0.systemImage) }.map(\.id.rawValue).sorted()
            var note = entry?.note
            if entry == nil { note = "not supported by Emuu" }
            return Row(version: v.number, name: v.marketingName, package: ref.sdkManagerPackage, installed: img != nil,
                       supported: entry != nil, isDefault: v == def,
                       sizeBytes: img.flatMap { sizeOnDisk($0.directory) } ?? (img == nil ? entry?.downloadBytes : nil),
                       revision: img?.revision, instances: users, note: note)
        }
    }

    /// Allocated bytes under a directory (what the image costs on disk).
    public static func diskUsage(_ directory: URL) -> UInt64? {
        guard let e = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return nil }
        var total: UInt64 = 0
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += UInt64(v?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    /// Instances (of this EMUU_HOME) that use `ref`.
    public static func users(of ref: SystemImageRef, in instances: [InstanceConfig]) -> [InstanceID] {
        instances.filter { $0.systemImage == ref }.map(\.id)
    }
}
