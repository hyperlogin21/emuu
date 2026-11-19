import Foundation

/// The single error type that crosses module boundaries. Modules may define private errors
/// internally but should map them to `EmuuError` at their public API.
public enum EmuuError: Error, Sendable, Hashable {
    // Environment / SDK
    case sdkNotFound(searched: [String])
    case toolNotFound(name: String, searched: [String])
    case systemImageMissing(path: String)

    // Instances
    case invalidInstanceID(String)
    case invalidConfiguration(String)
    case instanceNotFound(InstanceID)
    case instanceAlreadyExists(InstanceID)
    case invalidStateTransition(from: InstanceState, action: String)

    // Processes
    case processLaunchFailed(command: String, message: String)
    case processFailed(command: String, exitCode: Int32, stderr: String)
    case processTimedOut(command: String, timeout: Duration)

    // Device / engine
    case deviceNotReady(DeviceSerial)
    case adb(String)
    case console(String)
    case engine(String)
    case install(code: String, message: String)

    // Generic
    case unsupported(String)
    case parse(String)
    case io(path: String, message: String)
    case cancelled
}

extension EmuuError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .sdkNotFound(let searched):
            return "Android SDK not found. Searched: \(searched.joined(separator: ", ")). Set ANDROID_HOME."
        case .toolNotFound(let name, let searched):
            return "\(name) not found. Searched: \(searched.joined(separator: ", "))."
        case .systemImageMissing(let path):
            return "System image missing at \(path)."
        case .invalidInstanceID(let raw):
            return "Invalid instance name '\(raw)'. Use letters, digits, '.', '_' or '-' (max 64 chars)."
        case .invalidConfiguration(let message):
            return "Invalid configuration: \(message)"
        case .instanceNotFound(let id):
            return "Instance '\(id)' not found."
        case .instanceAlreadyExists(let id):
            return "Instance '\(id)' already exists."
        case .invalidStateTransition(let from, let action):
            return "Cannot \(action) while instance is \(from)."
        case .processLaunchFailed(let command, let message):
            return "Failed to launch \(command): \(message)"
        case .processFailed(let command, let exitCode, let stderr):
            let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(command) exited with status \(exitCode)\(tail.isEmpty ? "" : ": \(tail)")"
        case .processTimedOut(let command, let timeout):
            return "\(command) timed out after \(timeout)."
        case .deviceNotReady(let serial):
            return "Device \(serial) is not ready."
        case .adb(let message):
            return "adb: \(message)"
        case .console(let message):
            return "Emulator console: \(message)"
        case .engine(let message):
            return "Engine: \(message)"
        case .install(let code, let message):
            return "Install failed (\(code)): \(message)"
        case .unsupported(let message):
            return "Unsupported: \(message)"
        case .parse(let message):
            return "Parse error: \(message)"
        case .io(let path, let message):
            return "I/O error at \(path): \(message)"
        case .cancelled:
            return "Cancelled."
        }
    }
}
