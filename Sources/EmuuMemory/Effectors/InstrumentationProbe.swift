import Foundation
import EmuuBase

/// Finds packages that take part in a running instrumentation (`am instrument`: Espresso/UiAutomator tests,
/// Appium's UiAutomator2 server, Maestro's driver), so the governor never trims or kills them.
///
/// Three sources in one shell round trip, because none is complete on its own:
/// 1. `dumpsys activity processes` → the "Active instrumentation" section (test component, target package,
///    running processes),
/// 2. `ps -A -o ARGS` → `am instrument …`/`cmd activity instrument …` client processes (the component after
///    the options),
/// 3. `cmd package list instrumentation` → maps a test package to its `target=` package.
/// Only run when an action is about to target processes (rare), never per sample.
public enum InstrumentationProbe {
    public static let command =
        "echo @@dumpsys; dumpsys activity processes 2>/dev/null | grep -A80 'Active instrumentation'; " +
        "echo @@ps; ps -A -o ARGS 2>/dev/null | grep -E '(^| )instrument( |$)' | grep -v grep; " +
        "echo @@list; cmd package list instrumentation 2>/dev/null; echo @@end"

    /// Packages to protect, parsed from `command`'s output.
    public static func packages(fromProbeOutput output: String) -> Set<String> {
        let s = GuestParsers.sections(output)
        var result = activeInstrumentationPackages(s["dumpsys"] ?? "")
        let running = instrumentClientComponents(s["ps"] ?? "")
        let targets = instrumentationTargets(s["list"] ?? "")
        for pkg in running {
            result.insert(pkg)
            if let t = targets[pkg] { result.insert(t) }
        }
        // Instrumentations dumpsys reports also pull in their declared target.
        for pkg in result { if let t = targets[pkg] { result.insert(t) } }
        return result
    }

    /// Parses the "Active instrumentation:" section of `dumpsys activity processes`:
    /// `ActiveInstrumentation{<hash> <pkg>/<class>}`, `ComponentInfo{<pkg>/<class>}`, `packageName=<pkg>`,
    /// `targetPackage=<pkg>` and `ProcessRecord{<hash> <pid>:<process>/<uid>}` lines.
    public static func activeInstrumentationPackages(_ text: String) -> Set<String> {
        var out = Set<String>()
        var inSection = false
        var sectionIndent = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let indent = line.prefix { $0 == " " }.count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Active instrumentation") {
                inSection = true
                sectionIndent = indent
                continue
            }
            guard inSection else { continue }
            if trimmed.isEmpty { continue }
            if indent <= sectionIndent || trimmed.hasPrefix("--") { inSection = false; continue }
            for pkg in componentPackages(in: trimmed) { out.insert(pkg) }
            for key in ["packageName=", "targetPackage=", "mTargetPackage="] {
                if let r = trimmed.range(of: key) {
                    let v = trimmed[r.upperBound...].prefix { !$0.isWhitespace && $0 != "}" && $0 != "," }
                    if isPackageName(v) { out.insert(String(v)) }
                }
            }
            if let r = trimmed.range(of: "ProcessRecord{") {
                // ProcessRecord{a1b2c3 1234:com.example.app:remote/u0a123}
                let body = trimmed[r.upperBound...]
                if let colon = body.firstIndex(of: ":") {
                    let proc = body[body.index(after: colon)...].prefix { $0 != "/" && $0 != "}" && !$0.isWhitespace }
                    if let pkg = GuestParsers.packageName(fromProcessName: String(proc)), isPackageName(pkg[...]) { out.insert(pkg) }
                }
            }
        }
        return out
    }

    /// Package of the instrumentation component given to `am instrument` / `cmd activity instrument`.
    public static func instrumentClientComponents(_ text: String) -> Set<String> {
        var out = Set<String>()
        for raw in text.split(whereSeparator: \.isNewline) {
            let tokens = raw.split(separator: " ", omittingEmptySubsequences: true)
            guard let i = tokens.firstIndex(of: "instrument") else { continue }
            // The component is the last argument that looks like pkg/class (options take values, e.g. -e k v).
            if let comp = tokens[(i + 1)...].last(where: { $0.contains("/") && !$0.hasPrefix("-") }) {
                let pkg = comp.split(separator: "/").first ?? ""
                if isPackageName(pkg) { out.insert(String(pkg)) }
            }
        }
        return out
    }

    /// `instrumentation:<pkg>/<runner> (target=<target>)` → [pkg: target].
    public static func instrumentationTargets(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("instrumentation:"), let slash = line.firstIndex(of: "/") else { continue }
            let pkg = line[line.index(line.startIndex, offsetBy: "instrumentation:".count)..<slash]
            guard let r = line.range(of: "(target=") else { continue }
            let target = line[r.upperBound...].prefix { $0 != ")" }
            if isPackageName(pkg), isPackageName(target) { out[String(pkg)] = String(target) }
        }
        return out
    }

    private static func componentPackages(in line: String) -> [String] {
        var out: [String] = []
        for marker in ["ComponentInfo{", "ActiveInstrumentation{"] {
            var rest = line[...]
            while let r = rest.range(of: marker) {
                let body = rest[r.upperBound...]
                // ActiveInstrumentation{hash pkg/class} – skip the hash token.
                let tokens = body.prefix { $0 != "}" }.split(separator: " ")
                if let comp = tokens.first(where: { $0.contains("/") }), let pkg = comp.split(separator: "/").first,
                   isPackageName(pkg) {
                    out.append(String(pkg))
                }
                rest = body
            }
        }
        return out
    }

    static func isPackageName(_ s: Substring) -> Bool {
        guard s.contains("."), let first = s.first, first.isLetter else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }
    }
}
