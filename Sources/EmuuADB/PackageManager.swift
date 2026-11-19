import Foundation
import EmuuBase

/// An installed package plus cheap extras.
public struct InstalledPackage: Sendable, Hashable, Codable, Identifiable {
    public var info: PackageInfo
    public var uid: Int?
    /// On-disk size of the app's code directory (APKs, extracted libs, oat), from `du`. nil if unreadable.
    public var codeBytes: UInt64?

    public var id: String { info.packageName }

    public init(info: PackageInfo, uid: Int? = nil, codeBytes: UInt64? = nil) {
        self.info = info
        self.uid = uid
        self.codeBytes = codeBytes
    }
}

/// Package management over `DeviceShell` (`pm`, `cmd package`, `am`, `dumpsys package`).
///
/// Labels: Android exposes no cheap shell command that returns an app's label (it lives in the
/// APK's compiled resources), so `PackageInfo.label` is left nil here.
public struct PackageManager: Sendable {
    public let shell: any DeviceShell

    public init(shell: any DeviceShell) {
        self.shell = shell
    }

    // MARK: Listing

    /// Lists packages with one `pm list packages` call (plus one batched call when `details` is true for
    /// versionName and code size).
    /// - Parameter includeSystem: false = third-party (user-installed) packages only (`-3`).
    public func listPackages(includeSystem: Bool = false, details: Bool = true) async throws -> [InstalledPackage] {
        let marker = "@@EMUU@@"
        let filter = includeSystem ? "" : " -3"
        let script = "pm list packages -f -U -i --show-versioncode\(filter); echo \(marker); pm list packages -d\(filter); echo \(marker); pm list packages -3"
        let text = try await shell.shell(script, timeout: .seconds(60)).checked().stdoutString.replacingOccurrences(of: "\r", with: "")
        let parts = text.components(separatedBy: marker)
        var packages = Self.parseList(parts[0])
        let disabled = Set(Self.parseList(parts.count > 1 ? parts[1] : "").map(\.info.packageName))
        let thirdParty = Set(Self.parseList(parts.count > 2 ? parts[2] : "").map(\.info.packageName))
        for i in packages.indices {
            packages[i].info.isEnabled = !disabled.contains(packages[i].info.packageName)
            packages[i].info.isSystem = !thirdParty.contains(packages[i].info.packageName)
        }
        if details, !packages.isEmpty {
            let extras = try await fetchDetails(packages)
            for i in packages.indices {
                if let e = extras[packages[i].info.packageName] {
                    packages[i].info.versionName = e.versionName ?? packages[i].info.versionName
                    packages[i].codeBytes = e.codeBytes
                }
            }
        }
        return packages.sorted { $0.info.packageName < $1.info.packageName }
    }

    /// Parses `pm list packages [-f] [-U] [-i] [--show-versioncode]` lines, e.g.
    /// `package:/data/app/~~a==/com.x-b==/base.apk=com.x versionCode:12 uid:10150 installer=com.android.vending`.
    static func parseList(_ text: String) -> [InstalledPackage] {
        var out: [InstalledPackage] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("package:") else { continue }
            var tokens = line.dropFirst("package:".count).split(separator: " ").map(String.init)
            guard !tokens.isEmpty else { continue }
            let first = tokens.removeFirst()
            var path: String?
            var name = first
            if let r = first.range(of: ".apk=", options: .backwards) {
                path = String(first[..<r.lowerBound]) + ".apk"
                name = String(first[r.upperBound...])
            }
            var info = PackageInfo(packageName: name, apkPaths: path.map { [$0] } ?? [])
            var uid: Int?
            for t in tokens {
                if t.hasPrefix("versionCode:") { info.versionCode = Int64(t.dropFirst("versionCode:".count)) }
                else if t.hasPrefix("uid:") { uid = Int(t.dropFirst(4)) }
                else if t.hasPrefix("installer=") {
                    let inst = String(t.dropFirst("installer=".count))
                    info.installerPackage = inst == "null" || inst.isEmpty ? nil : inst
                }
            }
            out.append(InstalledPackage(info: info, uid: uid))
        }
        return out
    }

    private struct Extra { var versionName: String?; var codeBytes: UInt64? }

    /// One shell round trip: versionName from `dumpsys package` and `du -sk` of each code directory.
    /// Batched so each command stays well under the adb request limit (4 hex digits = 64 KiB).
    private func fetchDetails(_ packages: [InstalledPackage]) async throws -> [String: Extra] {
        var all: [String: Extra] = [:]
        var start = 0
        while start < packages.count {
            let batch = Array(packages[start..<min(packages.count, start + 40)])
            all.merge(try await fetchDetailsBatch(batch)) { _, new in new }
            start += 40
        }
        return all
    }

    private func fetchDetailsBatch(_ packages: [InstalledPackage]) async throws -> [String: Extra] {
        var script = ""
        for p in packages {
            let name = DeviceShellQuoting.quote(p.info.packageName)
            script += "echo '@@P' \(name); dumpsys package \(name) | grep -m1 'versionName='; "
            if let apk = p.info.apkPaths.first {
                let dir = (apk as NSString).deletingLastPathComponent
                script += "du -sk \(DeviceShellQuoting.quote(dir)) 2>/dev/null; "
            }
        }
        let text = try await shell.shell(script, timeout: .seconds(120)).stdoutString.replacingOccurrences(of: "\r", with: "")
        return Self.parseDetails(text).mapValues { Extra(versionName: $0.versionName, codeBytes: $0.codeBytes) }
    }

    static func parseDetails(_ text: String) -> [String: (versionName: String?, codeBytes: UInt64?)] {
        var result: [String: (versionName: String?, codeBytes: UInt64?)] = [:]
        var current: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("@@P ") {
                current = String(line.dropFirst(4))
                result[current!] = (nil, nil)
            } else if let c = current, line.hasPrefix("versionName=") {
                result[c]?.versionName = String(line.dropFirst("versionName=".count))
            } else if let c = current, let kb = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.flatMap({ UInt64($0) }) {
                result[c]?.codeBytes = kb * 1024
            }
        }
        return result
    }

    /// Full details for one package from `dumpsys package <name>`; nil if not installed.
    public func details(of packageName: String) async throws -> PackageInfo? {
        let text = try await shell.shell("dumpsys package \(DeviceShellQuoting.quote(packageName))", timeout: .seconds(30)).stdoutString
        return Self.parseDumpsysPackage(text, packageName: packageName)
    }

    static func parseDumpsysPackage(_ text: String, packageName: String) -> PackageInfo? {
        guard let start = text.range(of: "Package [\(packageName)]") else { return nil }
        let section = text[start.upperBound...]
        var info = PackageInfo(packageName: packageName)
        var sawFlags = false
        for raw in section.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Package [") { break }  // next package
            if line.hasPrefix("versionName="), info.versionName == nil {
                info.versionName = String(line.dropFirst("versionName=".count))
            } else if line.hasPrefix("versionCode="), info.versionCode == nil {
                let v = line.dropFirst("versionCode=".count).prefix(while: { $0.isNumber })
                info.versionCode = Int64(v)
            } else if line.hasPrefix("installerPackageName="), info.installerPackage == nil {
                let v = String(line.dropFirst("installerPackageName=".count))
                info.installerPackage = v == "null" ? nil : v
            } else if line.hasPrefix("codePath="), info.apkPaths.isEmpty {
                info.apkPaths = [String(line.dropFirst("codePath=".count))]
            } else if line.hasPrefix("pkgFlags=["), !sawFlags {
                sawFlags = true
                info.isSystem = line.contains(" SYSTEM ")
            } else if line.hasPrefix("User 0:"), let r = line.range(of: " enabled=") {
                // COMPONENT_ENABLED_STATE: 0 default, 1 enabled, 2 disabled, 3 disabled-user, 4 disabled-until-used.
                let v = line[r.upperBound...].prefix(while: { $0.isNumber })
                if let n = Int(v) { info.isEnabled = !(n == 2 || n == 3 || n == 4) }
            }
        }
        return info
    }

    /// True if installed for user 0 (`pm path` succeeds).
    public func isInstalled(_ packageName: String) async throws -> Bool {
        let r = try await shell.shell("pm path \(DeviceShellQuoting.quote(packageName))", timeout: .seconds(15))
        return r.succeeded && r.stdoutString.contains("package:")
    }

    /// APK paths (base + splits) via `pm path`.
    public func apkPaths(of packageName: String) async throws -> [String] {
        let r = try await shell.shell("pm path \(DeviceShellQuoting.quote(packageName))", timeout: .seconds(15))
        return r.stdoutString.split(whereSeparator: \.isNewline).compactMap {
            let l = $0.trimmingCharacters(in: .whitespaces)
            return l.hasPrefix("package:") ? String(l.dropFirst(8)) : nil
        }
    }

    // MARK: Actions

    /// The launcher activity component (`com.x/.Main`) resolved by PackageManager, or nil.
    public func launcherActivity(of packageName: String) async throws -> String? {
        let cmd = "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER \(DeviceShellQuoting.quote(packageName))"
        let r = try await shell.shell(cmd, timeout: .seconds(15))
        return Self.parseResolvedComponent(r.stdoutString)
    }

    static func parseResolvedComponent(_ text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = lines.last(where: { !$0.isEmpty }), last.contains("/"), !last.contains(" ") else { return nil }
        return last
    }

    /// Starts the app's launcher activity (`am start -n`), falling back to `monkey` if nothing resolves.
    public func launch(_ packageName: String) async throws {
        if let component = try await launcherActivity(of: packageName) {
            let r = try await shell.shell(
                "am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n \(DeviceShellQuoting.quote(component))",
                timeout: .seconds(30))
            try Self.checkAmStart(r, what: "launch \(packageName)")
            return
        }
        let r = try await shell.shell("monkey -p \(DeviceShellQuoting.quote(packageName)) -c android.intent.category.LAUNCHER 1", timeout: .seconds(30))
        let out = r.stdoutString + r.stderrString
        if !r.succeeded || out.contains("No activities found") || out.contains("monkey aborted") {
            throw EmuuError.adb("\(packageName) has no launchable activity (is it installed?)")
        }
    }

    /// `am start` exits 0 even when it fails; inspect its output.
    static func checkAmStart(_ r: ProcessResult, what: String) throws {
        let out = (r.stdoutString + "\n" + r.stderrString)
        if !r.succeeded || out.contains("Error:") || out.contains("Exception") {
            let line = out.split(whereSeparator: \.isNewline).first(where: { $0.contains("Error") || $0.contains("Exception") }).map(String.init) ?? out
            throw EmuuError.adb("\(what) failed: \(line.trimmingCharacters(in: .whitespaces))")
        }
    }

    public func forceStop(_ packageName: String) async throws {
        try await shell.shell("am force-stop \(DeviceShellQuoting.quote(packageName))", timeout: .seconds(15)).checked()
    }

    /// `pm uninstall [-k]`. Returns false if the package was not installed.
    @discardableResult
    public func uninstall(_ packageName: String, keepData: Bool = false) async throws -> Bool {
        let r = try await shell.shell("pm uninstall \(keepData ? "-k " : "")\(DeviceShellQuoting.quote(packageName))", timeout: .seconds(120))
        let out = r.stdoutString + r.stderrString
        if out.contains("Success") { return true }
        if out.contains("DELETE_FAILED_INTERNAL_ERROR") || out.contains("Unknown package") || out.contains("not installed") { return false }
        throw EmuuError.adb("uninstall \(packageName) failed: \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    /// `pm clear` (deletes all app data and cache).
    public func clearData(_ packageName: String) async throws {
        let r = try await shell.shell("pm clear \(DeviceShellQuoting.quote(packageName))", timeout: .seconds(60))
        guard r.stdoutString.contains("Success") else {
            throw EmuuError.adb("clear data for \(packageName) failed: \((r.stdoutString + r.stderrString).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// `pm grant` a runtime permission (e.g. `android.permission.CAMERA`).
    public func grant(_ permission: String, to packageName: String) async throws {
        try await shell.shell("pm grant \(DeviceShellQuoting.quote(packageName)) \(DeviceShellQuoting.quote(permission))", timeout: .seconds(15)).checked()
    }

    public func revoke(_ permission: String, from packageName: String) async throws {
        try await shell.shell("pm revoke \(DeviceShellQuoting.quote(packageName)) \(DeviceShellQuoting.quote(permission))", timeout: .seconds(15)).checked()
    }
}
