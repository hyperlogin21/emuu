import Foundation

/// Runs adb commands against one device. Implemented by `EmuuADB`; consumed by `EmuuMemory`
/// (guest sampling, trim/kill effectors), the app/CLI (keyboard toggle, screenshots fallback)
/// and `EmuuEngine` (boot-completed polling).
///
/// Semantics:
/// - `shell` runs `adb -s <serial> shell <command>`; the command string is interpreted by the
///   device's `sh`, so the caller is responsible for quoting (see `DeviceShellQuoting`).
///   Exit status of the remote command is propagated (adb shell protocol v2).
/// - `adb` runs `adb -s <serial> <arguments…>` (push, pull, install, forward, reverse, …).
/// - A non-zero exit is returned, not thrown; device-level failures (offline, unauthorized, adb
///   missing) and timeouts throw `EmuuError`.
public protocol DeviceShell: Sendable {
    var serial: DeviceSerial { get }
    func shell(_ command: String, timeout: Duration?) async throws -> ProcessResult
    func adb(_ arguments: [String], timeout: Duration?) async throws -> ProcessResult
}

extension DeviceShell {
    /// Default timeout for quick shell commands.
    public static var defaultShellTimeout: Duration { .seconds(30) }

    public func shell(_ command: String) async throws -> ProcessResult {
        try await shell(command, timeout: Self.defaultShellTimeout)
    }

    /// Runs a shell command, requires exit 0, returns trimmed stdout.
    public func shellOutput(_ command: String, timeout: Duration? = Self.defaultShellTimeout) async throws -> String {
        try await shell(command, timeout: timeout).checked().trimmedStdout
    }

    /// `getprop <name>`; empty string if unset.
    public func getprop(_ name: String) async throws -> String {
        try await shellOutput("getprop \(DeviceShellQuoting.quote(name))")
    }
}

/// POSIX single-quote quoting for strings embedded in `adb shell` command lines.
public enum DeviceShellQuoting {
    public static func quote(_ s: String) -> String {
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || "@%+=:,./-_".unicodeScalars.contains($0) }) {
            return s
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func join(_ args: [String]) -> String {
        args.map(quote).joined(separator: " ")
    }
}
