import Foundation

/// Time abstraction so policies, samplers and schedulers are deterministic in tests.
///
/// - `now()` is wall-clock time, used only for timestamps on records/events.
/// - `monotonicNow()` is a monotonic reading (arbitrary epoch) for intervals, cooldowns and hysteresis.
///   Never compute cooldowns from `now()`: the wall clock can jump (sleep/NTP).
/// - `sleep(for:)` suspends the caller; throws `CancellationError` when the task is cancelled.
public protocol EmuuClock: Sendable {
    func now() -> Date
    func monotonicNow() -> Duration
    func sleep(for duration: Duration) async throws
}

/// Real clock backed by `Date` and `ContinuousClock` (which keeps counting while the Mac sleeps,
/// so "idle for 30 minutes" includes sleep time).
public struct SystemClock: EmuuClock {
    private static let epoch = ContinuousClock.now

    public init() {}

    public func now() -> Date { Date() }

    public func monotonicNow() -> Duration {
        ContinuousClock.now - Self.epoch
    }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration, clock: .continuous)
    }
}
