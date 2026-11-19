import Foundation
import EmuuBase

/// What the display should be doing for a given window situation.
public enum DisplayStreamDirective: Sendable, Hashable {
    /// Frame stream open (the engine only sends frames when the screen changes; no frame-rate cap needed).
    case stream
    /// Frame stream closed: no frames, no copies, no rendering.
    case pause
}

/// Pure policy mapping window visibility to a stream directive, with a short grace period before pausing
/// so brief occlusions (Mission Control, Space switches) don't close and reopen the stream.
public struct DisplayActivityPolicy: Sendable, Hashable {
    /// How long the window must stay hidden before the stream is paused.
    public var pauseAfterHidden: Duration
    /// When false, a hidden window keeps streaming.
    public var pauseWhenHidden: Bool

    public init(pauseAfterHidden: Duration = .seconds(1), pauseWhenHidden: Bool = true) {
        self.pauseAfterHidden = pauseAfterHidden
        self.pauseWhenHidden = pauseWhenHidden
    }

    /// - Parameters:
    ///   - visible: the view is in a window that is on screen and not fully occluded/minimised.
    ///   - hiddenFor: how long the view has been continuously hidden (nil when visible).
    public func directive(visible: Bool, hiddenFor: Duration?) -> DisplayStreamDirective {
        if !visible, pauseWhenHidden, let hiddenFor, hiddenFor >= pauseAfterHidden { return .pause }
        return .stream
    }
}

/// Tracks per-instance display visibility and last user input for the memory governor
/// (`GovernorActivitySource`). Updated by the display view; read by EmuuMemory. Thread-safe.
public final class DisplayActivityTracker: GovernorActivitySource, @unchecked Sendable {
    private struct Entry {
        var visible = false
        var recording = false
        var lastInteraction: Duration?
    }

    private let entries = Locked<[InstanceID: Entry]>([:])
    private let clock: any EmuuClock

    public init(clock: any EmuuClock = SystemClock()) {
        self.clock = clock
    }

    public func setVisible(_ visible: Bool, for id: InstanceID) {
        entries.withLock { $0[id, default: Entry()].visible = visible }
    }

    /// While recording, the instance counts as visible: the governor must not freeze or hibernate it.
    public func setRecording(_ recording: Bool, for id: InstanceID) {
        entries.withLock { $0[id, default: Entry()].recording = recording }
    }

    public func isRecording(_ id: InstanceID) -> Bool {
        entries.withLock { $0[id]?.recording ?? false }
    }

    public func noteInteraction(for id: InstanceID) {
        let now = clock.monotonicNow()
        entries.withLock { $0[id, default: Entry()].lastInteraction = now }
    }

    public func remove(_ id: InstanceID) {
        _ = entries.withLock { $0.removeValue(forKey: id) }
    }

    public func isDisplayVisible(_ id: InstanceID) async -> Bool {
        entries.withLock { e in e[id].map { $0.visible || $0.recording } ?? false }
    }

    public func lastUserInteraction(_ id: InstanceID) async -> Duration? {
        entries.withLock { $0[id]?.lastInteraction }
    }
}
