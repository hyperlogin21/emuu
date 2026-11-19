import Foundation
import EmuuBase

/// A validated Android SDK installation.
public struct AndroidSDK: Sendable, Hashable {
    public var root: URL
    /// `emulator/emulator` launcher. It `exec`s into `emulator/qemu/darwin-aarch64/qemu-system-aarch64-headless`
    /// under `-no-window` (same pid), so the spawned pid is the QEMU pid.
    public var emulator: URL
    /// adb: the SDK copy, or a fallback (`/opt/homebrew/bin/adb`).
    public var adb: URL
    /// `Pkg.Revision` from `emulator/source.properties`, e.g. "36.4.9".
    public var emulatorVersion: String?

    public init(root: URL, emulator: URL, adb: URL, emulatorVersion: String?) {
        self.root = root
        self.emulator = emulator
        self.adb = adb
        self.emulatorVersion = emulatorVersion
    }

    public var systemImagesDirectory: URL { root.appendingPathComponent("system-images", isDirectory: true) }

    /// Absolute directory of a system image.
    public func directory(for image: SystemImageRef) -> URL {
        root.appendingPathComponent(image.sdkRelativePath, isDirectory: true)
    }

    /// `sdkmanager` inside cmdline-tools if present (used only for advice text).
    public var sdkManagerPath: String {
        let latest = root.appendingPathComponent("cmdline-tools/latest/bin/sdkmanager").path
        return FileManager.default.isExecutableFile(atPath: latest) ? latest : "sdkmanager"
    }
}

/// An installed system image, parsed from its `source.properties` (falling back to `package.xml`).
public struct InstalledSystemImage: Sendable, Hashable, CustomStringConvertible {
    public var ref: SystemImageRef
    public var directory: URL
    /// `AndroidVersion.ApiLevel` (may be fractional, e.g. "36.1").
    public var apiLevel: String
    public var revision: String?
    public var displayName: String?
    /// `SystemImage.TagDisplay`, e.g. "Google Play".
    public var tagDisplay: String?

    public var hasPlayStore: Bool { ref.hasPlayStore }

    /// Numeric API level for ordering ("36.1" -> 36.1).
    public var apiLevelValue: Double { Double(apiLevel) ?? 0 }

    public var description: String { "\(ref.sdkManagerPackage) (API \(apiLevel)\(hasPlayStore ? ", Play Store" : ""))" }
}

/// Finds and validates the SDK, its tools and its system images.
public struct SDKLocator: Sendable {
    public var environment: [String: String]
    public var home: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.environment = environment
        self.home = home
    }

    /// First candidate root that has an executable `emulator/emulator`, plus a usable adb.
    /// Throws `sdkNotFound` (no root with an emulator) or `toolNotFound("adb")`.
    public func locate() throws -> AndroidSDK {
        let fm = FileManager.default
        let candidates = SDKDiscovery.candidateRoots(environment: environment, home: home)
        guard let root = candidates.first(where: { fm.isExecutableFile(atPath: SDKDiscovery.emulatorBinary(in: $0).path) }) else {
            throw EmuuError.sdkNotFound(searched: candidates.map(\.path))
        }
        let sdkADB = SDKDiscovery.adbBinary(in: root)
        let adbCandidates = [sdkADB.path] + SDKDiscovery.fallbackADBPaths
        guard let adbPath = adbCandidates.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            throw EmuuError.toolNotFound(name: "adb", searched: adbCandidates)
        }
        let props = try? IniFile(contentsOf: root.appendingPathComponent("emulator/source.properties"))
        return AndroidSDK(root: root,
                          emulator: SDKDiscovery.emulatorBinary(in: root),
                          adb: URL(fileURLWithPath: adbPath),
                          emulatorVersion: props?["Pkg.Revision"])
    }

    // MARK: System images

    /// Every image under `system-images/<api>/<tag>/<abi>/` that has a `system.img` (or `system/`),
    /// sorted best-first by `preferenceOrder`.
    public static func installedImages(in sdk: AndroidSDK, hostABI: String = "arm64-v8a") -> [InstalledSystemImage] {
        let fm = FileManager.default
        let base = sdk.systemImagesDirectory
        var found: [InstalledSystemImage] = []
        for api in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] where !api.hasPrefix(".") {
            let apiDir = base.appendingPathComponent(api, isDirectory: true)
            for tag in (try? fm.contentsOfDirectory(atPath: apiDir.path)) ?? [] where !tag.hasPrefix(".") {
                let tagDir = apiDir.appendingPathComponent(tag, isDirectory: true)
                for abi in (try? fm.contentsOfDirectory(atPath: tagDir.path)) ?? [] where !abi.hasPrefix(".") {
                    let dir = tagDir.appendingPathComponent(abi, isDirectory: true)
                    guard fm.fileExists(atPath: dir.appendingPathComponent("system.img").path)
                        || fm.fileExists(atPath: dir.appendingPathComponent("system").path) else { continue }
                    let ref = SystemImageRef(apiDirectory: api, tag: tag, abi: abi)
                    found.append(describeImage(ref: ref, directory: dir))
                }
            }
        }
        return found.sorted { a, b in
            let ka = preferenceKey(a, hostABI: hostABI), kb = preferenceKey(b, hostABI: hostABI)
            if ka != kb { return ka.lexicographicallyPrecedes(kb) == false }
            return a.ref.sdkManagerPackage < b.ref.sdkManagerPackage
        }
    }

    /// Best image for Emuu: Play Store > Google APIs > other; host ABI first; then highest API.
    public static func preferredImage(in sdk: AndroidSDK, hostABI: String = "arm64-v8a") -> InstalledSystemImage? {
        installedImages(in: sdk, hostABI: hostABI).first { $0.ref.abi == hostABI }
    }

    /// Advice shown when no usable Play Store image exists.
    public static func missingImageAdvice(sdk: AndroidSDK?, wanted: SystemImageRef = .playStoreDefault) -> String {
        let tool = sdk?.sdkManagerPath ?? "sdkmanager"
        return """
        No Google Play system image for arm64 is installed. Install one with:
          emuu images install \(wanted.androidVersion?.number ?? wanted.apiDirectory)
        or: \(tool) "\(wanted.sdkManagerPackage)"
        (accept the licence when prompted; about 2 GB). Only google_apis_playstore images include the Play Store.
        `emuu images list` shows the Android versions Emuu supports.
        """
    }

    static func preferenceKey(_ image: InstalledSystemImage, hostABI: String) -> [Double] {
        let tagRank: Double
        switch image.ref.tag {
        case let t where t.contains("playstore"): tagRank = 3
        case "google_apis": tagRank = 2
        case "default", "android": tagRank = 1
        default: tagRank = 0
        }
        // ps16k / tv / wear / automotive variants sort below plain ones with the same rank.
        let plain: Double = image.ref.tag.contains("ps16k") || image.ref.tag.contains("tv") || image.ref.tag.contains("wear")
            || image.ref.tag.contains("automotive") ? 0 : 1
        return [image.ref.abi == hostABI ? 1 : 0, tagRank, plain, image.apiLevelValue]
    }

    static func describeImage(ref: SystemImageRef, directory: URL) -> InstalledSystemImage {
        if let props = try? IniFile(contentsOf: directory.appendingPathComponent("source.properties")),
           let api = props["AndroidVersion.ApiLevel"] {
            return InstalledSystemImage(ref: ref, directory: directory, apiLevel: api,
                                        revision: props["Pkg.Revision"], displayName: props["Pkg.Desc"],
                                        tagDisplay: props["SystemImage.TagDisplay"])
        }
        if let xml = try? String(contentsOf: directory.appendingPathComponent("package.xml"), encoding: .utf8) {
            let parsed = PackageXML.parse(xml)
            return InstalledSystemImage(ref: ref, directory: directory,
                                        apiLevel: parsed.apiLevel ?? apiFromDirectory(ref.apiDirectory),
                                        revision: parsed.revision, displayName: parsed.displayName, tagDisplay: parsed.tagDisplay)
        }
        return InstalledSystemImage(ref: ref, directory: directory, apiLevel: apiFromDirectory(ref.apiDirectory),
                                    revision: nil, displayName: nil, tagDisplay: nil)
    }

    /// "android-36.1" -> "36.1"; codenames are returned unchanged.
    static func apiFromDirectory(_ dir: String) -> String {
        dir.hasPrefix("android-") ? String(dir.dropFirst("android-".count)) : dir
    }
}

/// Minimal extraction from an SDK `package.xml` (no full XML parsing needed for these fields).
enum PackageXML {
    struct Fields: Equatable {
        var apiLevel: String?
        var minorApiLevel: String?
        var revision: String?
        var displayName: String?
        var tagDisplay: String?
    }

    static func parse(_ fullXML: String) -> Fields {
        // Only look inside <localPackage …> so licence text and dependency revisions are ignored.
        let xml = fullXML.range(of: "<localPackage").map { String(fullXML[$0.lowerBound...]) } ?? fullXML
        var f = Fields()
        f.apiLevel = firstElement("api-level", in: xml)
        f.minorApiLevel = firstElement("minor-api-level", in: xml)
        if let api = f.apiLevel, !api.contains("."), let minor = f.minorApiLevel, minor != "0" { f.apiLevel = "\(api).\(minor)" }
        if let rev = firstElement("revision", in: xml), let major = firstElement("major", in: rev) {
            let minor = firstElement("minor", in: rev) ?? "0"
            let micro = firstElement("micro", in: rev) ?? "0"
            f.revision = minor == "0" && micro == "0" ? major : "\(major).\(minor).\(micro)"
        }
        f.displayName = firstElement("display-name", in: xml)
        if let tagBlock = firstElement("tag", in: xml) { f.tagDisplay = firstElement("display", in: tagBlock) }
        return f
    }

    static func firstElement(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
