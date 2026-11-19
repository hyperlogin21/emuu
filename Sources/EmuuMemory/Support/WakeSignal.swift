import Foundation
import EmuuBase

/// One-shot-per-wait wake-up flag. `signal()` before `wait()` makes the next `wait()` return at
/// once (signals coalesce). `wait()` returns early on task cancellation.
final class WakeSignal: @unchecked Sendable {
    private struct State {
        var pending = false
        var waiter: CheckedContinuation<Void, Never>?
        var waiterID: UInt64 = 0
    }

    private let state = Locked(State())

    func signal() {
        let c: CheckedContinuation<Void, Never>? = state.withLock { s in
            if let w = s.waiter {
                s.waiter = nil
                return w
            }
            s.pending = true
            return nil
        }
        c?.resume()
    }

    func wait() async {
        let id: UInt64 = state.withLock { s in
            s.waiterID += 1
            return s.waiterID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = state.withLock { s in
                    if s.pending || Task.isCancelled {
                        s.pending = false
                        return true
                    }
                    s.waiter = cont
                    s.waiterID = id
                    return false
                }
                if resumeNow { cont.resume() }
            }
        } onCancel: {
            let c: CheckedContinuation<Void, Never>? = state.withLock { s in
                guard s.waiterID == id, let w = s.waiter else { return nil }
                s.waiter = nil
                return w
            }
            c?.resume()
        }
    }
}
