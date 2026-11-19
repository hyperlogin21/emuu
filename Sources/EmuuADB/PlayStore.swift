import Foundation
import EmuuBase

/// Play Store helpers for the Google-certified `google_apis_playstore` image.
///
/// What Emuu can and cannot do:
/// - It can detect the Play Store and Google Play services, open the Store, open an app's listing
///   (`market://details?id=…`), open search, and open Android's "Add account" screen for Google.
/// - It cannot sign in for the user. Sign-in happens inside the emulator, in Google's own UI;
///   Emuu never sees or handles credentials.
/// - Account detection is a heuristic over `dumpsys account` that runs on the device and only
///   counts Google accounts. Account names are redacted on the device before the output reaches
///   the host, so they never enter Emuu's memory or logs.
public struct PlayStore: Sendable {
    public static let storePackage = PackageInfo.playStorePackage   // com.android.vending
    public static let servicesPackage = "com.google.android.gms"
    public static let googleAccountType = "com.google"

    public struct Status: Sendable, Hashable, Codable {
        public var storeInstalled: Bool
        public var storeVersionName: String?
        public var storeVersionCode: Int64?
        public var storeEnabled: Bool
        public var servicesInstalled: Bool
        public var servicesVersionName: String?
    }

    public enum AccountState: Sendable, Hashable, Codable {
        case signedIn(googleAccounts: Int)
        case signedOut
        /// The heuristic could not decide (e.g. `dumpsys account` refused).
        case unknown(reason: String)

        public var isSignedIn: Bool {
            if case .signedIn = self { return true }
            return false
        }
    }

    public let shell: any DeviceShell

    public init(shell: any DeviceShell) {
        self.shell = shell
    }

    /// Presence and versions of the Play Store and Play services (one shell round trip).
    public func status() async throws -> Status {
        let marker = "@@EMUU@@"
        let store = DeviceShellQuoting.quote(Self.storePackage)
        let gms = DeviceShellQuoting.quote(Self.servicesPackage)
        let script = "pm list packages -e \(store); echo \(marker); dumpsys package \(store) | grep -m2 -E 'versionName=|versionCode='; echo \(marker); pm list packages \(store); echo \(marker); dumpsys package \(gms) | grep -m1 'versionName='"
        let text = try await shell.shell(script, timeout: .seconds(30)).stdoutString.replacingOccurrences(of: "\r", with: "")
        return Self.parseStatus(text.components(separatedBy: marker))
    }

    static func parseStatus(_ parts: [String]) -> Status {
        func part(_ i: Int) -> String { i < parts.count ? parts[i] : "" }
        let enabled = part(0).contains("package:\(storePackage)")
        let installed = part(2).split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces) == "package:\(storePackage)" }
        var versionName: String?
        var versionCode: Int64?
        for raw in part(1).split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("versionName=") { versionName = String(line.dropFirst("versionName=".count)) }
            if line.hasPrefix("versionCode=") { versionCode = Int64(line.dropFirst("versionCode=".count).prefix(while: { $0.isNumber })) }
        }
        let gmsLine = part(3).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.hasPrefix("versionName=") }
        return Status(storeInstalled: installed, storeVersionName: installed ? versionName : nil, storeVersionCode: installed ? versionCode : nil,
                      storeEnabled: installed && enabled, servicesInstalled: gmsLine != nil,
                      servicesVersionName: gmsLine.map { String($0.dropFirst("versionName=".count)) })
    }

    /// Heuristic: counts accounts of type `com.google` in `dumpsys account` (account names are
    /// replaced with `*` on the device before output is returned).
    public func accountState() async throws -> AccountState {
        let script = "dumpsys account 2>&1 | grep -E 'Accounts:|type=|Permission Denial' | sed -E 's/name=[^,]*,/name=*,/'"
        let r = try await shell.shell(script, timeout: .seconds(20))
        return Self.parseAccounts(r.stdoutString)
    }

    static func parseAccounts(_ text: String) -> AccountState {
        if text.contains("Permission Denial") { return .unknown(reason: "dumpsys account is not permitted on this device") }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.contains(where: { $0.hasPrefix("Accounts:") }) else {
            return .unknown(reason: "dumpsys account produced no account list")
        }
        let google = lines.filter { $0.hasPrefix("Account {") && $0.contains("type=\(googleAccountType)}") }.count
        return google > 0 ? .signedIn(googleAccounts: google) : .signedOut
    }

    /// Opens the Play Store home screen.
    public func open() async throws {
        try await requireStore()
        try await PackageManager(shell: shell).launch(Self.storePackage)
    }

    /// Opens the Store listing for `packageName` (`market://details?id=…`). The user installs from there.
    public func openListing(packageName: String) async throws {
        guard Self.isValidPackageName(packageName) else { throw EmuuError.invalidConfiguration("'\(packageName)' is not a valid Android package name") }
        try await requireStore()
        try await view(uri: "market://details?id=\(packageName)", what: "open Play Store listing for \(packageName)")
    }

    /// Opens Play Store search results for `query`.
    public func openSearch(_ query: String) async throws {
        try await requireStore()
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
        try await view(uri: "market://search?q=\(encoded)&c=apps", what: "open Play Store search")
    }

    /// Opens Android's "Add account" flow filtered to Google accounts. The user signs in inside the emulator.
    public func openAddGoogleAccount() async throws {
        let r = try await shell.shell("am start -a android.settings.ADD_ACCOUNT_SETTINGS --esa account_types \(Self.googleAccountType)", timeout: .seconds(30))
        try PackageManager.checkAmStart(r, what: "open the add-account screen")
    }

    private func view(uri: String, what: String) async throws {
        let cmd = "am start -a android.intent.action.VIEW -d \(DeviceShellQuoting.quote(uri)) -p \(Self.storePackage)"
        try PackageManager.checkAmStart(try await shell.shell(cmd, timeout: .seconds(30)), what: what)
    }

    private func requireStore() async throws {
        guard try await PackageManager(shell: shell).isInstalled(Self.storePackage) else {
            throw EmuuError.unsupported("The Play Store is not installed on this device. Use a google_apis_playstore system image.")
        }
    }

    /// Java package name rules: dot-separated segments of [A-Za-z_][A-Za-z0-9_]*, at least two segments.
    public static func isValidPackageName(_ name: String) -> Bool {
        let segments = name.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return false }
        return segments.allSatisfy { seg in
            guard let first = seg.first, first.isASCII, first.isLetter || first == "_" else { return false }
            return seg.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
        }
    }
}
