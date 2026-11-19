import Foundation

/// Decides from two cheap guest counters whether something other than Emuu is driving the instance over adb
/// (test runners, Appium/Maestro, scripts), so the governor treats it as "not idle".
///
/// * `adbShellSessions` > 0: another `adb shell`/`exec-out` session runs right now (long-lived ones such as
///   `logcat`, `am instrument`, `uiautomator` are always caught).
/// * Pid allocation rate: every short adb command forks a few guest processes, so bursts of commands between
///   two samples show up as a pid rate well above the idle rate. Measured on android-36.1: idle ≈ 14
///   pids/min with 30 s sampling, ≈ 37/min at 10 s sampling with trims running (the governor's own work, which
///   is subtracted / re-baselined), ten `adb shell input tap` ≈ 50 pids.
///
/// It is a heuristic (a busy app forking processes also counts); automation mode is the guarantee.
public struct ADBActivityDetector: Sendable {
    /// Pids per minute above which the guest counts as driven over adb.
    public var pidRateThreshold: Double
    /// Processes one guest sample forks itself (the adb shell, `pidof`, the probe's subshell): subtracted so
    /// a faster sampling cadence under pressure is not mistaken for activity.
    public var ownProcessesPerSample: Int
    private var previous: (pid: Int, at: Duration)?

    public init(pidRateThreshold: Double = 60, ownProcessesPerSample: Int = 4) {
        self.pidRateThreshold = pidRateThreshold
        self.ownProcessesPerSample = ownProcessesPerSample
    }

    /// Forget the pid baseline: call after the governor's own actions (a trim runs one `cmd` per process,
    /// maintenance more), so its own forks are never counted as someone else's adb traffic.
    public mutating func rebaseline() { previous = nil }

    /// Feeds one sample; returns true when adb activity is detected.
    public mutating func update(shellSessions: Int?, lastPID: Int?, at now: Duration) -> Bool {
        var active = (shellSessions ?? 0) > 0
        if let pid = lastPID {
            if let prev = previous, pid >= prev.pid, now > prev.at {
                let minutes = (now - prev.at).timeInterval / 60
                // Very short intervals amplify noise; require at least 5 s between the two readings.
                let foreign = max(0, pid - prev.pid - ownProcessesPerSample)
                if minutes >= 5.0 / 60, Double(foreign) / minutes > pidRateThreshold { active = true }
            }
            // pid wrap-around or a guest reboot: start over.
            previous = (pid, now)
        }
        return active
    }
}
