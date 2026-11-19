import Foundation
import CoreVideo
import EmuuBase
import EmuuGRPC

/// A frame or display size in pixels.
public struct VideoSize: Sendable, Hashable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var description: String { "\(width)x\(height)" }
    public var swapped: VideoSize { VideoSize(width: height, height: width) }
}

/// Device buttons Emuu exposes (control strip, menu shortcuts, mouse buttons).
public enum DeviceKey: String, Sendable, CaseIterable {
    case back, home, appSwitch, power, volumeUp, volumeDown, menu

    /// W3C `KeyboardEvent.key` value the emulator's `sendKey` translates (emulator_controller.proto: "GoBack",
    /// "GoHome", "AppSwitch", "Power" are documented Android-specific keys).
    public var w3cKey: String {
        switch self {
        case .back: return "GoBack"
        case .home: return "GoHome"
        case .appSwitch: return "AppSwitch"
        case .power: return "Power"
        case .volumeUp: return "AudioVolumeUp"
        case .volumeDown: return "AudioVolumeDown"
        case .menu: return "ContextMenu"
        }
    }
}

/// Lifecycle state of a display session.
public enum DisplaySessionState: Sendable, Hashable, CustomStringConvertible {
    case idle
    /// Connecting to the engine's gRPC endpoint / starting the frame stream.
    case starting
    /// Frame stream open. Frames arrive only when the guest screen changes, so a static screen costs nothing.
    case streaming
    /// Frame stream closed (window hidden); input and clipboard keep working. The last frame stays on screen.
    case paused
    case stopped
    case failed(reason: String)

    public var description: String {
        switch self {
        case .idle: return "idle"
        case .starting: return "starting"
        case .streaming: return "streaming"
        case .paused: return "paused"
        case .stopped: return "stopped"
        case .failed(let r): return "failed(\(r))"
        }
    }

    public var isActive: Bool { self == .starting || self == .streaming }
    public var isFailed: Bool { if case .failed = self { return true } else { return false } }
}

/// Notifications from a session. Delivered on arbitrary threads; hop to the main actor for UI.
public enum DisplaySessionEvent: Sendable, Hashable {
    case stateChanged(DisplaySessionState)
    /// The frame size or device orientation changed (first frame, rotation).
    case frameGeometryChanged(VideoSize, SkinRotation)
    /// The guest clipboard changed.
    case clipboardChanged(String)
}

/// One displayed frame: a BGRA, IOSurface-backed pixel buffer from a small recycled pool.
public struct DisplayFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let size: VideoSize
    public let rotation: SkinRotation
    /// Emulator's estimate of when the guest produced it (Unix µs).
    public let deviceTimestampUs: UInt64
    /// Monotonic host time the frame was received.
    public let receivedAt: ContinuousClock.Instant
    public let seq: UInt32
    /// When the pixels were in the pooled buffer (receivedAt → convertedAt = Emuu's read/convert time).
    public let convertedAt: ContinuousClock.Instant

    public init(pixelBuffer: CVPixelBuffer, size: VideoSize, rotation: SkinRotation, deviceTimestampUs: UInt64,
                receivedAt: ContinuousClock.Instant, seq: UInt32, convertedAt: ContinuousClock.Instant? = nil) {
        self.pixelBuffer = pixelBuffer
        self.size = size
        self.rotation = rotation
        self.deviceTimestampUs = deviceTimestampUs
        self.receivedAt = receivedAt
        self.seq = seq
        self.convertedAt = convertedAt ?? receivedAt
    }
}

/// Receives frames on the session's reader thread, in order. Must return quickly.
public protocol DisplayFrameSink: AnyObject, Sendable {
    func consume(_ frame: DisplayFrame)
}

/// Fans frames out to several sinks (display + recorder).
public final class TeeFrameSink: DisplayFrameSink, @unchecked Sendable {
    public let sinks: [any DisplayFrameSink]
    public init(_ sinks: [any DisplayFrameSink]) { self.sinks = sinks }
    public func consume(_ frame: DisplayFrame) { for s in sinks { s.consume(frame) } }
}

/// A point-in-time view of display statistics.
public struct DisplayStats: Sendable, Hashable {
    /// Frames received per second over the trailing window (0 while the guest screen is static).
    public var framesPerSecond: Double
    public var totalFrames: UInt64
    /// Frames not delivered: the renderer/recorder still held every pooled buffer, or (MMAP) the engine kept
    /// overwriting the region while it was read (`unstableFrames`).
    public var droppedFrames: UInt64
    /// MMAP: frames whose shared-memory region changed while Emuu was copying it (the engine was already
    /// writing the next frame). With validation these were re-read or dropped, never shown torn.
    public var racedFrames: UInt64 = 0
    /// MMAP: raced frames dropped because the region did not settle within the retry budget.
    public var unstableFrames: UInt64 = 0
    /// Frame streams opened (start + every resume).
    public var streamsOpened: UInt64
    public var videoSize: VideoSize?
    public var rotation: SkinRotation
    /// Emulator frame timestamp → host receipt, last frame (ms).
    public var lastTransportLatencyMs: Double?

    public static let zero = DisplayStats(framesPerSecond: 0, totalFrames: 0, droppedFrames: 0, streamsOpened: 0,
                                          videoSize: nil, rotation: .portrait, lastTransportLatencyMs: nil)
}

/// Rates over a trailing window with a fixed-size ring (bounded memory whatever the session length).
public struct FrameRateCounter: Sendable {
    public let window: Duration
    private var times: [ContinuousClock.Instant]
    private var head = 0
    private var count = 0

    public init(window: Duration = .seconds(2), capacity: Int = 256) {
        self.window = window
        self.times = Array(repeating: ContinuousClock.now, count: capacity)
    }

    public mutating func record(_ t: ContinuousClock.Instant) {
        times[head] = t
        head = (head + 1) % times.count
        count = min(count + 1, times.count)
    }

    public func rate(now: ContinuousClock.Instant) -> Double {
        var n = 0
        var oldest = now
        for i in 0..<count {
            let t = times[(head - 1 - i + times.count) % times.count]
            if now - t > window { break }
            n += 1
            oldest = t
        }
        guard n > 1 else { return 0 }
        let span = now - oldest
        let secs = Double(span.components.seconds) + Double(span.components.attoseconds) / 1e18
        return secs > 0 ? Double(n) / max(secs, 0.25) : 0
    }
}
