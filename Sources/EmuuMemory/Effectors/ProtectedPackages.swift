import Foundation

/// Packages the governor never trims-by-kill or kills: system UI, Google Play services/Store,
/// providers, input methods, launchers and other platform plumbing. Matching is on the package
/// part of the process name (`com.google.android.gms:snet` → `com.google.android.gms`).
public struct ProtectedPackages: Sendable, Hashable {
    /// Exact package names, also matched as a dotted prefix (`com.google.android.gms` protects
    /// `com.google.android.gms.persistent`).
    public var names: Set<String>

    public init(names: Set<String>) {
        self.names = names
    }

    public static let `default` = ProtectedPackages(names: [
        "android", "system", "system_server",
        "com.android.systemui", "com.android.phone", "com.android.shell", "com.android.se",
        "com.android.bluetooth", "com.android.nfc", "com.android.networkstack", "com.google.android.networkstack",
        "com.android.providers", "com.google.android.providers",
        "com.android.permissioncontroller", "com.google.android.permissioncontroller",
        "com.android.externalstorage", "com.android.externalstorage",
        "com.android.inputmethod", "com.google.android.inputmethod",
        "com.android.launcher", "com.android.launcher3", "com.google.android.apps.nexuslauncher",
        "com.android.vending",                       // Play Store
        "com.google.android.gms",                    // Play services
        "com.google.android.gsf",                    // Google services framework
        "com.google.android.ext.services", "com.android.ext.services",
        "com.google.android.webview", "com.google.android.trichromelibrary",
        "com.android.emulator", "com.google.android.apps.wellbeing",
        "com.android.server.telecom", "com.android.dynsystem",
    ])

    /// True if the process/package must not be targeted.
    public func contains(_ processOrPackage: String) -> Bool {
        let pkg = processOrPackage.split(separator: ":", maxSplits: 1).first.map(String.init) ?? processOrPackage
        if names.contains(pkg) { return true }
        var candidate = pkg
        while let dot = candidate.lastIndex(of: ".") {
            candidate = String(candidate[..<dot])
            if names.contains(candidate) { return true }
        }
        return false
    }

    public func adding(_ more: [String]) -> ProtectedPackages {
        ProtectedPackages(names: names.union(more))
    }
}
