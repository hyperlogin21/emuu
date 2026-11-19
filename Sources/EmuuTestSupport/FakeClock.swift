import Foundation
import EmuuBase

/// Manually advanced clock. `sleep(for:)` suspends until `advance(by:)` moves time past the deadline.
///
/// Typical pattern:
/// ```swift
/// let clock = FakeClock()
/// let task = Task { try await scheduler.runLoop(clock: clock) }
/// await clock.waitForSleepers(1)    // loop is parked in sleep
/// clock.advance(by: .seconds(30))   // wakes it
/// ```
public final class FakeClock: EmuuClock, @unchecked Sendable {
    private struct Sleeper {
        let id: UInt64
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct State {
        var wall: Date
        var mono: Duration
        var sleepers: [Sleeper] = []
        var nextID: UInt64 = 0
    }

    private let state: Locked<State>

    public init(start: Date = Date(timeIntervalSince1970: 1_800_000_000), monotonic: Duration = .seconds(1000)) {
        state = Locked(State(wall: start, mono: monotonic))
    }

    public func now() -> Date { state.withLock { $0.wall } }
    public func monotonicNow() -> Duration { state.withLock { $0.mono } }

    /// Number of tasks currently suspended in `sleep`.
    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    public func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        if duration <= .zero { return }
        let id: UInt64 = state.withLock { s in
            s.nextID += 1
            return s.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let cancelledAlready = state.withLock { s -> Bool in
                    if Task.isCancelled { return true }
                    s.sleepers.append(Sleeper(id: id, deadline: s.mono + duration, continuation: cont))
                    return false
                }
                if cancelledAlready { cont.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let removed: Sleeper? = state.withLock { s in
                guard let idx = s.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return s.sleepers.remove(at: idx)
            }
            removed?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves both clocks forward and wakes every sleeper whose deadline has passed (earliest first).
    public func advance(by duration: Duration) {
        let due: [Sleeper] = state.withLock { s in
            s.mono += duration
            s.wall = s.wall.addingTimeInterval(duration.timeInterval)
            let ready = s.sleepers.filter { $0.deadline <= s.mono }.sorted { $0.deadline < $1.deadline }
            s.sleepers.removeAll { $0.deadline <= s.mono }
            return ready
        }
        due.forEach { $0.continuation.resume() }
    }

    /// Changes only the wall clock (simulate NTP jumps / sleep-wake); monotonic time is unaffected.
    public func setWallClock(_ date: Date) {
        state.withLock { $0.wall = date }
    }

    /// Waits (yielding, bounded by real time) until at least `count` tasks are sleeping.
    /// Returns false if that did not happen within `timeout`.
    @discardableResult
    public func waitForSleepers(_ count: Int = 1, timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if sleeperCount >= count { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        return sleeperCount >= count
    }
}
