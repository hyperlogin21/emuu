import Foundation
import Observation
import EmuuBase
import EmuuMemory

/// What to do with running instances when the app quits or an emulator window is closed.
enum ShutdownChoice: String, CaseIterable, Identifiable, Sendable {
    /// Save the quick-boot snapshot and quit the engine (resume in ~2 s). Releases all host memory.
    case hibernate
    /// Clean shutdown; next start cold-boots.
    case shutDown
    /// Leave the engine running headless (the CLI or a later app launch can attach to it).
    case keepRunning

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hibernate: return "Hibernate"
        case .shutDown: return "Shut Down"
        case .keepRunning: return "Keep Running"
        }
    }
}

/// User preferences, persisted in UserDefaults. Small and flat on purpose.
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    /// Freeze (SIGSTOP) an instance after its window has been hidden for the profile's delay.
    var autoFreezeWhenHidden: Bool { didSet { defaults.set(autoFreezeWhenHidden, forKey: Keys.autoFreeze) } }
    /// Hibernate after being frozen this many minutes. 0 = never on a timer.
    var hibernateAfterIdleMinutes: Int { didSet { defaults.set(hibernateAfterIdleMinutes, forKey: Keys.hibernateMinutes) } }
    /// Action when an emulator window is closed.
    var onWindowClose: ShutdownChoice { didSet { defaults.set(onWindowClose.rawValue, forKey: Keys.onClose) } }
    /// Default action offered when quitting with running instances.
    var onQuit: ShutdownChoice { didSet { defaults.set(onQuit.rawValue, forKey: Keys.onQuit) } }

    /// `EMUU_APP_NO_ENGINE_ACTIONS=1`: the governor never freezes/hibernates (used by the self-test so a
    /// shared development instance is not paused under other tools).
    nonisolated static let engineActionsDisabled = ProcessInfo.processInfo.environment["EMUU_APP_NO_ENGINE_ACTIONS"] == "1"

    /// Choices for the hibernate-after-idle picker (minutes, 0 = never).
    static let hibernateChoices = [0, 10, 30, 60, 120, 240, 480]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoFreezeWhenHidden = defaults.object(forKey: Keys.autoFreeze) as? Bool ?? true
        hibernateAfterIdleMinutes = defaults.object(forKey: Keys.hibernateMinutes) as? Int ?? 30
        onWindowClose = defaults.string(forKey: Keys.onClose).flatMap(ShutdownChoice.init(rawValue:)) ?? .hibernate
        onQuit = defaults.string(forKey: Keys.onQuit).flatMap(ShutdownChoice.init(rawValue:)) ?? .hibernate
    }

    /// Per-instance governor profile override (falls back to the instance config's profile).
    func profile(for id: InstanceID, default fallback: MemoryProfile) -> MemoryProfile {
        defaults.string(forKey: Keys.profile(id)).flatMap(MemoryProfile.init(rawValue:)) ?? fallback
    }

    func setProfile(_ profile: MemoryProfile, for id: InstanceID) {
        defaults.set(profile.rawValue, forKey: Keys.profile(id))
    }

    func clearInstance(_ id: InstanceID) {
        defaults.removeObject(forKey: Keys.profile(id))
    }

    /// Governor configuration for an instance: the profile preset, adjusted by the user's settings.
    /// `autoResume` is off because the app itself resumes a hibernated instance when its window is shown
    /// (it must re-create the display session afterwards, and two concurrent resumes would race).
    func governorConfig(profile: MemoryProfile, guestRAMMB: Int, automation: Bool = false) -> GovernorConfig {
        var config = GovernorConfig.preset(profile, guestRAMMB: guestRAMMB)
        config.automationMode = automation
        if !autoFreezeWhenHidden { config.freezeWhenHiddenAfter = nil }
        config.hibernateWhenFrozenAfter = hibernateAfterIdleMinutes > 0 ? .seconds(hibernateAfterIdleMinutes * 60) : nil
        config.autoResume = false
        if Self.engineActionsDisabled {
            // Diagnostics / shared dev device: guest trims only, never freeze or hibernate the engine.
            config.freezeWhenHiddenAfter = nil
            config.hibernateWhenFrozenAfter = nil
            config.hibernateWhenFrozenUnderCreepAfter = nil
            config.hibernateOnHostCritical = false
        }
        return config
    }

    private enum Keys {
        static let autoFreeze = "autoFreezeWhenHidden"
        static let hibernateMinutes = "hibernateAfterIdleMinutes"
        static let onClose = "onWindowClose"
        static let onQuit = "onQuit"
        static func profile(_ id: InstanceID) -> String { "profile.\(id.rawValue)" }
    }
}

extension MemoryProfile {
    var title: String {
        switch self {
        case .frugal: return "Lite"
        case .balanced: return "Balanced"
        case .performance: return "Gaming"
        }
    }
}

extension VideoDecoderMode {
    var title: String {
        switch self {
        case .auto: return "Auto (\(VideoDecoderMode.resolvedDefault.title))"
        case .hardware: return "Hardware (Mac)"
        case .hostSoftware: return "Mac software (ffmpeg)"
        case .software: return "Software (Android)"
        }
    }
}
