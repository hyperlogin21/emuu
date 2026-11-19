import Foundation

/// On-disk layout of Emuu state. Everything Emuu owns lives under `root` (default `~/.emuu`).
///
/// ```
/// ~/.emuu/
///   avd/                 ANDROID_AVD_HOME for the engine (Emuu instances only — never ~/.android/avd)
///     <id>.ini           AVD pointer file
///     <id>.avd/          AVD content (config.ini, userdata, snapshots/ …)
///   instances/<id>.json  Emuu InstanceConfig records (source of truth for config generation)
///   run/                 runtime files (pid files, locks, sockets)
///   logs/                emuu.log (+ rotated emuu.1.log …) and per-instance engine logs
///   cache/               scratch/derived data (e.g. extracted XAPK/APKS bundles), safe to delete
///   tools/               helper binaries (currently unused; the display needs nothing in the guest)
///   config.json          global user settings
/// ```
///
/// The root can be overridden with the `EMUU_HOME` environment variable or explicitly (tests).
public struct EmuuPaths: Sendable, Hashable {
    public static let rootEnvironmentKey = "EMUU_HOME"

    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// Default layout: `$EMUU_HOME` if set and non-empty, else `<home>/.emuu`.
    public static func `default`(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> EmuuPaths {
        if let override = environment[rootEnvironmentKey], !override.isEmpty {
            return EmuuPaths(root: URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true))
        }
        return EmuuPaths(root: home.appendingPathComponent(".emuu", isDirectory: true))
    }

    /// Value for the engine's `ANDROID_AVD_HOME` environment variable.
    public var avdHome: URL { root.appendingPathComponent("avd", isDirectory: true) }
    public var instancesDirectory: URL { root.appendingPathComponent("instances", isDirectory: true) }
    public var runDirectory: URL { root.appendingPathComponent("run", isDirectory: true) }
    public var logsDirectory: URL { root.appendingPathComponent("logs", isDirectory: true) }
    public var cacheDirectory: URL { root.appendingPathComponent("cache", isDirectory: true) }
    public var toolsDirectory: URL { root.appendingPathComponent("tools", isDirectory: true) }
    public var configFile: URL { root.appendingPathComponent("config.json", isDirectory: false) }
    public var mainLogFile: URL { logsDirectory.appendingPathComponent("emuu.log", isDirectory: false) }

    /// `avd/<id>.avd/` — the AVD content directory.
    public func avdDirectory(for id: InstanceID) -> URL {
        avdHome.appendingPathComponent("\(id.rawValue).avd", isDirectory: true)
    }

    /// `avd/<id>.ini` — the AVD pointer file the engine looks up by name.
    public func avdIniFile(for id: InstanceID) -> URL {
        avdHome.appendingPathComponent("\(id.rawValue).ini", isDirectory: false)
    }

    /// `instances/<id>.json` — persisted `InstanceConfig`.
    public func instanceConfigFile(for id: InstanceID) -> URL {
        instancesDirectory.appendingPathComponent("\(id.rawValue).json", isDirectory: false)
    }

    /// `logs/engine-<id>.log` — engine stdout/stderr for one instance.
    public func engineLogFile(for id: InstanceID) -> URL {
        logsDirectory.appendingPathComponent("engine-\(id.rawValue).log", isDirectory: false)
    }

    /// `run/<id>.pid` — pid of the engine process launched by Emuu for one instance.
    public func pidFile(for id: InstanceID) -> URL {
        runDirectory.appendingPathComponent("\(id.rawValue).pid", isDirectory: false)
    }

    /// All directories Emuu expects to exist.
    public var allDirectories: [URL] {
        [root, avdHome, instancesDirectory, runDirectory, logsDirectory, cacheDirectory, toolsDirectory]
    }

    /// Creates every directory in the layout (idempotent).
    public func ensureDirectories(fileManager: FileManager = .default) throws {
        for dir in allDirectories {
            do {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                throw EmuuError.io(path: dir.path, message: error.localizedDescription)
            }
        }
    }
}

/// Inputs for Android SDK discovery. Validation (checking that `emulator/emulator` etc. exist and
/// that versions are acceptable) is the job of `EmuuEngine`'s SDK locator; this type only defines
/// the search order so every module agrees on it.
public enum SDKDiscovery {
    public static let environmentKeys = ["ANDROID_HOME", "ANDROID_SDK_ROOT"]

    /// Candidate SDK roots in priority order, de-duplicated:
    /// `$ANDROID_HOME`, `$ANDROID_SDK_ROOT`, `<home>/Library/Android/sdk`.
    public static func candidateRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            let std = url.standardizedFileURL
            if seen.insert(std.path).inserted { result.append(std) }
        }
        for key in environmentKeys {
            if let value = environment[key], !value.isEmpty {
                add(URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true))
            }
        }
        add(home.appendingPathComponent("Library/Android/sdk", isDirectory: true))
        return result
    }

    /// Well-known locations of tools inside an SDK root.
    public static func emulatorBinary(in sdkRoot: URL) -> URL {
        sdkRoot.appendingPathComponent("emulator/emulator", isDirectory: false)
    }

    public static func adbBinary(in sdkRoot: URL) -> URL {
        sdkRoot.appendingPathComponent("platform-tools/adb", isDirectory: false)
    }

    /// Additional adb locations outside the SDK, tried after the SDK copy.
    public static let fallbackADBPaths = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
}
