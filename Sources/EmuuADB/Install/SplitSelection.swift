import Foundation
import EmuuBase

/// What the installer needs to know about the device to pick config splits.
public struct DeviceSpec: Sendable, Hashable, Codable {
    /// `ro.product.cpu.abilist`, most preferred first (e.g. `["arm64-v8a"]`).
    public var abis: [String]
    /// Effective screen density in dpi (`wm density` override if set, else physical).
    public var density: Int
    /// Language codes, most preferred first (e.g. `["en"]`).
    public var languages: [String]
    /// `ro.build.version.sdk`.
    public var sdkLevel: Int

    public init(abis: [String], density: Int, languages: [String], sdkLevel: Int) {
        self.abis = abis
        self.density = density
        self.languages = languages
        self.sdkLevel = sdkLevel
    }

    /// Reads the spec with a single shell round trip.
    public static func query(_ shell: any DeviceShell) async throws -> DeviceSpec {
        let marker = "@@EMUU@@"
        let script = [
            "getprop ro.product.cpu.abilist", "echo \(marker)",
            "wm density", "echo \(marker)",
            "getprop ro.sf.lcd_density", "echo \(marker)",
            "getprop persist.sys.locale", "echo \(marker)",
            "getprop ro.product.locale", "echo \(marker)",
            "getprop ro.build.version.sdk",
        ].joined(separator: "; ")
        let text = try await shell.shell(script, timeout: .seconds(15)).stdoutString.replacingOccurrences(of: "\r", with: "")
        return parse(text.components(separatedBy: marker).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
    }

    static func parse(_ parts: [String]) -> DeviceSpec {
        func part(_ i: Int) -> String { i < parts.count ? parts[i] : "" }
        let abis = part(0).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // `wm density` prints "Physical density: 320" and optionally "Override density: 280".
        var density = Int(part(2)) ?? 0
        for line in part(1).split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("Override density:"), let v = Int(l.dropFirst("Override density:".count).trimmingCharacters(in: .whitespaces)) {
                density = v
                break
            }
            if l.hasPrefix("Physical density:"), let v = Int(l.dropFirst("Physical density:".count).trimmingCharacters(in: .whitespaces)) {
                density = v
            }
        }
        var languages: [String] = []
        for locale in [part(3), part(4)] where !locale.isEmpty {
            let lang = String(locale.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "").lowercased()
            if !lang.isEmpty, !languages.contains(lang) { languages.append(lang) }
        }
        if languages.isEmpty { languages = ["en"] }
        return DeviceSpec(abis: abis.isEmpty ? ["arm64-v8a"] : abis, density: density == 0 ? 320 : density,
                          languages: languages, sdkLevel: Int(part(5)) ?? 0)
    }
}

/// Classification of an APK inside a split bundle, derived from its file name
/// (`config.arm64_v8a.apk`, `split_config.xxhdpi.apk`, `base-en.apk`, `base-master.apk`, …).
public enum SplitKind: Sendable, Hashable {
    case abi(String)        // normalized with "-" (e.g. "arm64-v8a")
    case density(String)    // bucket name ("xhdpi")
    case language(String)   // "en"
    case other              // base, feature modules, master splits: always installed
}

public enum SplitSelector {
    static let knownABIs = ["arm64_v8a", "armeabi_v7a", "armeabi", "x86_64", "x86", "mips64", "mips", "riscv64"]
    static let densityBuckets: [(String, Int)] = [
        ("ldpi", 120), ("mdpi", 160), ("tvdpi", 213), ("hdpi", 240), ("xhdpi", 320), ("xxhdpi", 480), ("xxxhdpi", 640),
    ]

    public static func classify(fileName: String) -> SplitKind {
        var stem = (fileName as NSString).lastPathComponent
        if stem.lowercased().hasSuffix(".apk") { stem = String(stem.dropLast(4)) }
        let lower = stem.lowercased()
        // Qualifier = text after the last "." (config.xx / split_config.xx) or "-" (bundletool base-xx).
        let isConfig = lower.hasPrefix("config.") || lower.hasPrefix("split_config.") || lower.contains(".config.")
        let qualifier: String
        if let dot = lower.lastIndex(of: "."), isConfig {
            qualifier = String(lower[lower.index(after: dot)...])
        } else if let dash = lower.lastIndex(of: "-") {
            qualifier = String(lower[lower.index(after: dash)...])
        } else {
            return .other
        }
        if knownABIs.contains(qualifier) { return .abi(qualifier.replacingOccurrences(of: "_", with: "-")) }
        if densityBuckets.contains(where: { $0.0 == qualifier }) { return .density(qualifier) }
        // Language: 2–3 letters (optionally with a region), only in config/bundletool positions.
        let langPart = qualifier.split(whereSeparator: { $0 == "_" || $0 == "-" }).first.map(String.init) ?? ""
        if (2...3).contains(langPart.count), langPart.allSatisfy({ $0.isLetter && $0.isASCII }),
           qualifier.count <= 7, langPart != "apk" {
            return .language(langPart)
        }
        return .other
    }

    public struct Selection: Sendable, Hashable {
        public var selected: [String]
        public var skipped: [String]
    }

    /// Picks the splits to install for `device` (returned base-first):
    /// - every "other" split (base, features, master);
    /// - the best ABI split (first match in the device's abilist order);
    /// - the density split closest at-or-above the device density (else the largest below);
    /// - language splits matching the device languages (all of them if none match).
    /// Throws `EmuuError.install(INSTALL_FAILED_NO_MATCHING_ABIS)` if ABI splits exist and none fits.
    public static func select(_ names: [String], for device: DeviceSpec) throws -> Selection {
        var others: [String] = [], abis: [(String, String)] = [], densities: [(String, String)] = [], langs: [(String, String)] = []
        for n in names {
            switch classify(fileName: n) {
            case .other: others.append(n)
            case .abi(let a): abis.append((n, a))
            case .density(let d): densities.append((n, d))
            case .language(let l): langs.append((n, l))
            }
        }
        var selected = others
        if !abis.isEmpty {
            guard let pick = device.abis.lazy.compactMap({ want in abis.first(where: { $0.1 == want }) }).first else {
                let available = abis.map(\.1)
                throw EmuuError.install(code: "INSTALL_FAILED_NO_MATCHING_ABIS",
                                        message: InstallFailureCatalog.noMatchingABIsText(appABIs: available, deviceABIs: device.abis))
            }
            selected.append(pick.0)
        }
        if !densities.isEmpty {
            let valued = densities.compactMap { d in densityBuckets.first(where: { $0.0 == d.1 }).map { (d.0, $0.1) } }
            let above = valued.filter { $0.1 >= device.density }.min(by: { $0.1 < $1.1 })
            let below = valued.max(by: { $0.1 < $1.1 })
            if let pick = above ?? below { selected.append(pick.0) }
        }
        if !langs.isEmpty {
            let matching = langs.filter { device.languages.contains($0.1) }
            selected += (matching.isEmpty ? langs : matching).map(\.0)
        }
        // Order: base/feature splits first (archive order), then ABI, density, language.
        let chosen = Set(selected)
        return Selection(selected: selected, skipped: names.filter { !chosen.contains($0) })
    }

    /// Native-code ABIs present in an APK, from its `lib/<abi>/…` entries.
    public static func nativeABIs(inAPKEntries entries: [String]) -> [String] {
        var seen: [String] = []
        for e in entries where e.hasPrefix("lib/") {
            let parts = e.split(separator: "/")
            if parts.count >= 3 {
                let abi = String(parts[1])
                if !seen.contains(abi) { seen.append(abi) }
            }
        }
        return seen
    }
}
