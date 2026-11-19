import Foundation

/// A tiny lock-protected box for mutable state shared across concurrency domains.
///
/// Works on macOS 14 (unlike `Synchronization.Mutex`, which needs macOS 15) and does not
/// force `@Sendable` closures the way `OSAllocatedUnfairLock.withLock` does.
/// Keep critical sections short and never `await` inside `withLock`.
public final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    /// Snapshot of the current value (copy for value types).
    public var current: Value {
        withLock { $0 }
    }

    public func set(_ newValue: Value) {
        withLock { $0 = newValue }
    }
}
