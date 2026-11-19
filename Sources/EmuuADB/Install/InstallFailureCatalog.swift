import Foundation
import EmuuBase

/// Parses PackageManager install output and turns `INSTALL_FAILED_*` / `INSTALL_PARSE_FAILED_*`
/// codes into text a user can act on.
public enum InstallFailureCatalog {
    public enum Outcome: Sendable, Hashable {
        case success
        case failure(code: String, detail: String)
    }

    /// Parses output of `pm install`, `cmd package install-commit`, `adb install`, …
    /// - `Success` (on its own line) → success.
    /// - `Failure [CODE: detail]` / `Failure [CODE]` → failure.
    /// - `Error: …` / `Exception occurred …` / anything else → failure `INSTALL_ERROR` with the text.
    public static func parse(_ output: String) -> Outcome {
        let text = output.replacingOccurrences(of: "\r", with: "")
        if let range = text.range(of: "Failure [") {
            let rest = text[range.upperBound...]
            let inner = rest.prefix(while: { $0 != "]" && $0 != "\n" })
            let (code, detail) = splitCodeDetail(String(inner))
            return .failure(code: code, detail: detail)
        }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains(where: { $0 == "Success" || $0.hasPrefix("Success:") }) { return .success }
        // Some failures are printed without brackets, e.g. "adb: failed to install x.apk: INSTALL_FAILED_…: msg".
        if let codeRange = text.range(of: #"INSTALL_(PARSE_)?FAILED_[A-Z0-9_]+"#, options: .regularExpression) {
            let code = String(text[codeRange])
            let after = text[codeRange.upperBound...].drop(while: { $0 == ":" || $0 == " " })
            return .failure(code: code, detail: String(after.prefix(while: { $0 != "\n" })))
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(code: "INSTALL_ERROR", detail: trimmed.isEmpty ? "PackageManager returned no output" : String(trimmed.suffix(1000)))
    }

    private static func splitCodeDetail(_ inner: String) -> (String, String) {
        if let colon = inner.firstIndex(of: ":") {
            return (String(inner[..<colon]).trimmingCharacters(in: .whitespaces),
                    String(inner[inner.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }
        return (inner.trimmingCharacters(in: .whitespaces), "")
    }

    /// Human explanation for a failure code. `detail` is PackageManager's own text, appended for context.
    public static func explain(code: String, detail: String = "", appABIs: [String] = [], deviceABIs: [String] = []) -> String {
        let base: String
        switch code {
        case "INSTALL_FAILED_NO_MATCHING_ABIS", "INSTALL_FAILED_CPU_ABI_INCOMPATIBLE":
            return noMatchingABIsText(appABIs: appABIs, deviceABIs: deviceABIs) + (detail.isEmpty ? "" : " (\(detail))")
        case "INSTALL_FAILED_UPDATE_INCOMPATIBLE", "INSTALL_FAILED_SHARED_USER_INCOMPATIBLE":
            base = "A version of this app signed with a different key is already installed. Uninstall it first (this deletes its data), then install again."
        case "INSTALL_FAILED_VERSION_DOWNGRADE":
            base = "A newer version of this app is already installed. Uninstall it first, or enable 'allow downgrade'."
        case "INSTALL_FAILED_ALREADY_EXISTS":
            base = "The app is already installed and replacing it was not allowed."
        case "INSTALL_FAILED_INSUFFICIENT_STORAGE":
            base = "Not enough free space on the emulator. Uninstall apps, clear caches, or create the instance with a larger data partition."
        case "INSTALL_FAILED_OLDER_SDK":
            base = "This app needs a newer Android version than this emulator runs."
        case "INSTALL_FAILED_DEPRECATED_SDK_VERSION":
            base = "This app targets a very old Android SDK, which this Android version refuses to install (it can be forced with `adb install --bypass-low-target-sdk-block`)."
        case "INSTALL_FAILED_NEWER_SDK":
            base = "This app only supports older Android versions than this emulator runs."
        case "INSTALL_FAILED_TEST_ONLY":
            base = "This is a test-only build; it can only be installed with test packages allowed."
        case "INSTALL_FAILED_MISSING_SPLIT":
            base = "The app is split into several APKs and a required part is missing. Install the full bundle (XAPK/APKS/APKM) instead of a single APK."
        case "INSTALL_FAILED_MISSING_FEATURE":
            base = "The app requires a hardware or software feature this emulator does not provide."
        case "INSTALL_FAILED_MISSING_SHARED_LIBRARY":
            base = "The app needs a shared library this system image does not include."
        case "INSTALL_FAILED_DUPLICATE_PERMISSION", "INSTALL_FAILED_DUPLICATE_PERMISSION_GROUP":
            base = "The app defines a permission that another installed app already defines (often a different build of the same app). Uninstall the other app first."
        case "INSTALL_FAILED_CONFLICTING_PROVIDER":
            base = "The app's content provider conflicts with an installed app (often another build of the same app)."
        case "INSTALL_FAILED_INVALID_APK", "INSTALL_PARSE_FAILED_NOT_APK", "INSTALL_PARSE_FAILED_BAD_MANIFEST",
             "INSTALL_PARSE_FAILED_MANIFEST_MALFORMED", "INSTALL_PARSE_FAILED_MANIFEST_EMPTY", "INSTALL_PARSE_FAILED_UNEXPECTED_EXCEPTION":
            base = "The file is not a valid APK (it may be corrupt, incomplete, or not an Android app)."
        case "INSTALL_PARSE_FAILED_NO_CERTIFICATES", "INSTALL_PARSE_FAILED_INCONSISTENT_CERTIFICATES", "INSTALL_PARSE_FAILED_CERTIFICATE_ENCODING":
            base = "The APK is unsigned or its signature is broken. Android only installs signed apps."
        case "INSTALL_FAILED_INVALID_INSTALL_LOCATION", "INSTALL_FAILED_MEDIA_UNAVAILABLE":
            base = "The app asked to be installed in a storage location that is not available."
        case "INSTALL_FAILED_VERIFICATION_FAILURE", "INSTALL_FAILED_VERIFICATION_TIMEOUT":
            base = "Package verification (Google Play Protect) rejected or timed out on this app."
        case "INSTALL_FAILED_USER_RESTRICTED":
            base = "Installing apps is restricted for the current user on this device."
        case "INSTALL_FAILED_ABORTED":
            base = "The installation was cancelled on the device."
        case "INSTALL_FAILED_INTERNAL_ERROR":
            base = "PackageManager hit an internal error."
        case "INSTALL_FAILED_DEXOPT":
            base = "The app's code could not be optimized on this device."
        case "INSTALL_FAILED_UID_CHANGED", "INSTALL_FAILED_PACKAGE_CHANGED":
            base = "Leftover data from a previous install conflicts with this app. Uninstall it fully and try again."
        case "INSTALL_FAILED_SESSION_INVALID":
            base = "The install session became invalid (the split APKs may not belong to the same app or version)."
        case "INSTALL_FAILED_HYPERVISOR_INCOMPATIBLE":
            base = "This system image does not support the app's requirements."
        case "INSTALL_FAILED_MULTIPACKAGE_INCONSISTENCY", "INSTALL_FAILED_INVALID_URI":
            base = "The APK set is inconsistent (the parts do not belong together)."
        case "INSTALL_ERROR":
            base = "PackageManager reported an error."
        default:
            base = "Android rejected the app (\(code))."
        }
        return detail.isEmpty ? base : "\(base) (\(detail))"
    }

    /// Message for apps that carry no native code for the device's CPU.
    public static func noMatchingABIsText(appABIs: [String], deviceABIs: [String]) -> String {
        let device = deviceABIs.isEmpty ? "64-bit ARM (arm64-v8a)" : deviceABIs.joined(separator: ", ")
        guard !appABIs.isEmpty else {
            return "This app has no native code for this emulator's CPU (\(device))."
        }
        let app = appABIs.joined(separator: ", ")
        let x86Only = appABIs.allSatisfy { $0.hasPrefix("x86") }
        let arm32Only = appABIs.allSatisfy { $0.hasPrefix("armeabi") }
        var hint = ""
        if x86Only {
            hint = " It is an x86-only build, which cannot run on an Apple Silicon (ARM) emulator. Download the ARM (arm64-v8a) variant instead."
        } else if arm32Only {
            hint = " It is a 32-bit ARM-only (armv7) build, and this 64-bit-only system image cannot run 32-bit code. Look for an arm64-v8a or universal variant."
        }
        return "This app only includes native code for \(app), but this emulator runs \(device).\(hint)"
    }
}
