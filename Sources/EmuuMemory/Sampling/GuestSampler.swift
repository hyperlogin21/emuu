import Foundation
import EmuuBase

/// Rates derived from `/proc/vmstat` counters between two consecutive samples (per second).
public struct GuestVMRates: Codable, Sendable, Hashable {
    public var majorFaultsPerSec: Double
    public var swapInPagesPerSec: Double
    public var swapOutPagesPerSec: Double
    /// Page-cache refaults (thrashing indicator).
    public var refaultsPerSec: Double
    /// Direct-reclaim stalls (allocstall_*).
    public var allocStallsPerSec: Double

    public init(majorFaultsPerSec: Double = 0, swapInPagesPerSec: Double = 0, swapOutPagesPerSec: Double = 0, refaultsPerSec: Double = 0, allocStallsPerSec: Double = 0) {
        self.majorFaultsPerSec = majorFaultsPerSec
        self.swapInPagesPerSec = swapInPagesPerSec
        self.swapOutPagesPerSec = swapOutPagesPerSec
        self.refaultsPerSec = refaultsPerSec
        self.allocStallsPerSec = allocStallsPerSec
    }
}

/// One guest observation from a single adb round trip.
public struct GuestSnapshot: Sendable, Hashable {
    public var memory: GuestMemory
    /// Process names in the foreground (oom_score_adj 0). Usually one app (or the launcher).
    public var foregroundProcesses: [String]
    /// Raw selected vmstat counters.
    public var vmCounters: [String: UInt64]
    /// Rates since the previous sample (nil on the first sample or after a counter reset).
    public var vmRates: GuestVMRates?
    /// How long the adb round trip took (sampling cost).
    public var roundTrip: Duration
    /// adb shell sessions running in the guest besides the sampler's own (children of adbd), when probed.
    public var adbShellSessions: Int?
    /// Guest kernel boot id (`/proc/sys/kernel/random/boot_id`): changes when the guest reboots.
    public var bootID: String?
    /// Guest uptime (`/proc/uptime`), seconds.
    public var uptimeSeconds: Double?
    /// Last pid the guest kernel allocated (`/proc/loadavg` field 5); its growth rate reveals bursts of
    /// short adb commands between samples (`ADBActivityDetector`).
    public var lastPID: Int?

    public init(memory: GuestMemory, foregroundProcesses: [String] = [], vmCounters: [String: UInt64] = [:], vmRates: GuestVMRates? = nil, roundTrip: Duration = .zero) {
        self.memory = memory
        self.foregroundProcesses = foregroundProcesses
        self.vmCounters = vmCounters
        self.vmRates = vmRates
        self.roundTrip = roundTrip
    }

    /// Package names (deduplicated) of the foreground processes.
    public var foregroundPackages: [String] {
        var seen: [String] = []
        for p in foregroundProcesses.compactMap(GuestParsers.packageName(fromProcessName:)) where !seen.contains(p) { seen.append(p) }
        return seen
    }
}

/// Source of guest snapshots (real: `GuestSampler`; tests: a fake).
public protocol GuestMemorySampling: Sendable {
    /// One cheap sample (single adb shell round trip).
    func sample() async throws -> GuestSnapshot
    /// Expensive per-app breakdown (`dumpsys meminfo -c`). Call rarely / on demand.
    func appBreakdown() async throws -> [AppMemoryUsage]
}

/// Samples guest memory with one combined `adb shell` command per sample:
/// `/proc/meminfo`, `/proc/pressure/memory`, selected `/proc/vmstat` counters and an
/// oom_score_adj scan (foreground process names + cached-process count). No `dumpsys`.
public final class GuestSampler: GuestMemorySampling, @unchecked Sendable {
    /// vmstat counters we keep (others are filtered on the device by grep).
    public static let vmstatKeys = [
        "pgmajfault", "pswpin", "pswpout",
        "workingset_refault", "workingset_refault_anon", "workingset_refault_file",
        "allocstall_normal", "allocstall_movable", "allocstall_dma", "allocstall_dma32",
    ]

    /// Device-side scan over /proc using shell builtins only (no forks).
    /// Prints `fg <argv0>` for oom_score_adj == 0 and a final `cached <n>` for adj >= 900.
    /// mksh's `read` stops at the first NUL of `/proc/<pid>/cmdline`, yielding argv[0]; kernel
    /// threads (also adj 0, ~250 of them) have an empty cmdline and are skipped.
    /// Verified on API 36 (emulator-5580): output `fg com.google.android.apps.nexuslauncher`, `cached 30`.
    public static let processScanScript =
        "c=0; for d in /proc/[0-9]*; do read -r a < $d/oom_score_adj || continue; " +
        "if [ \"$a\" -ge 900 ]; then c=$((c+1)); elif [ \"$a\" -eq 0 ]; then " +
        "read -r n < $d/cmdline; [ -n \"$n\" ] && echo \"fg $n\"; fi; done 2>/dev/null; echo \"cached $c\""

    /// adb activity probe (shell builtins plus one `pidof`). Prints `adbd <children> <lastpid>`: the number
    /// of processes whose parent is adbd (this sampler's own shell is one of them) and the last pid the
    /// kernel handed out. adbd's long-lived `abb` helper (binder bridge, started by the first `adb install`
    /// and kept alive) is not a session and is skipped. Verified on API 36: idle `adbd 1 7554`; with a
    /// concurrent `adb shell` `adbd 2 …`. The shell user cannot read adbd's `/proc/<pid>/io`, and adbd's CPU
    /// ticks barely move for short commands, so these two counters are the cheap signals that work.
    public static let adbProbeScript =
        "a=$(pidof adbd); n=0; for d in /proc/[0-9]*; do read -r s < $d/stat 2>/dev/null || continue; " +
        "case \"$s\" in *'(abb)'*) continue;; esac; " +
        "s=${s#*) }; set -- $s; [ \"$2\" = \"$a\" ] && n=$((n+1)); done; " +
        "read -r l1 l2 l3 l4 l5 < /proc/loadavg; echo \"adbd $n $l5\""

    public static var combinedCommand: String {
        let keys = vmstatKeys.joined(separator: "|")
        return [
            "echo @@meminfo", "cat /proc/meminfo",
            "echo @@psi", "cat /proc/pressure/memory 2>/dev/null",
            "echo @@vmstat", "grep -E '^(\(keys)) ' /proc/vmstat 2>/dev/null",
            "echo @@procs", processScanScript,
            "echo @@adb", adbProbeScript,
            "echo @@boot", "cat /proc/sys/kernel/random/boot_id /proc/uptime 2>/dev/null",
            "echo @@end",
        ].joined(separator: "; ")
    }

    private struct Previous {
        var counters: [String: UInt64]
        var at: Duration
    }

    public let shell: any DeviceShell
    public let clock: any EmuuClock
    public let timeout: Duration
    private let previous = Locked<Previous?>(nil)

    public init(shell: any DeviceShell, clock: any EmuuClock = SystemClock(), timeout: Duration = .seconds(10)) {
        self.shell = shell
        self.clock = clock
        self.timeout = timeout
    }

    public func sample() async throws -> GuestSnapshot {
        let start = clock.monotonicNow()
        let result = try await shell.shell(Self.combinedCommand, timeout: timeout)
        let end = clock.monotonicNow()
        // The script itself always ends with "echo @@end" (exit 0); a non-zero exit means adb/shell trouble.
        let snap = try Self.parse(result.stdoutString, exitCode: result.exitCode, stderr: result.stderrString)
        var out = snap
        out.roundTrip = end - start
        out.vmRates = previous.withLock { prev -> GuestVMRates? in
            defer { prev = Previous(counters: snap.vmCounters, at: end) }
            guard let p = prev else { return nil }
            return Self.rates(from: p.counters, to: snap.vmCounters, seconds: (end - p.at).timeInterval)
        }
        return out
    }

    /// Parses the combined output. Throws `EmuuError.parse` when meminfo is unusable.
    public static func parse(_ stdout: String, exitCode: Int32 = 0, stderr: String = "") throws -> GuestSnapshot {
        let s = GuestParsers.sections(stdout)
        guard let memText = s["meminfo"], var mem = GuestParsers.guestMemory(meminfo: GuestParsers.meminfo(memText)) else {
            let tail = String((stderr.isEmpty ? stdout : stderr).suffix(300))
            if exitCode != 0 {
                throw EmuuError.processFailed(command: "adb shell <guest sample>", exitCode: exitCode, stderr: tail)
            }
            throw EmuuError.parse("guest sample: no usable /proc/meminfo (exit \(exitCode)): \(tail)")
        }
        mem.pressureStall = s["psi"].flatMap(GuestParsers.pressureStall)
        let scan = GuestParsers.processScan(s["procs"] ?? "")
        mem.cachedProcessCount = scan.cachedCount
        let counters = GuestParsers.vmstat(s["vmstat"] ?? "")
        var snap = GuestSnapshot(memory: mem, foregroundProcesses: scan.foreground, vmCounters: counters)
        if let boot = s["boot"] {
            let lines = boot.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            if let id = lines.first, id.count >= 32, id.contains("-") { snap.bootID = id }
            if lines.count > 1, let up = lines[1].split(separator: " ").first.flatMap({ Double($0) }) { snap.uptimeSeconds = up }
        }
        if let probe = s["adb"].flatMap(GuestParsers.adbProbe) {
            snap.adbShellSessions = max(0, probe.children - 1)
            snap.lastPID = probe.lastPID
        }
        return snap
    }

    /// Per-second rates; nil if the interval is non-positive or any counter went backwards (guest reboot).
    public static func rates(from a: [String: UInt64], to b: [String: UInt64], seconds: Double) -> GuestVMRates? {
        guard seconds > 0 else { return nil }
        func d(_ keys: [String]) -> Double?? {
            var total: UInt64 = 0
            var any = false
            for k in keys {
                guard let nb = b[k], let na = a[k] else { continue }
                if nb < na { return .some(nil) }
                total += nb - na
                any = true
            }
            return any ? .some(Double(total) / seconds) : .none
        }
        var r = GuestVMRates()
        let fields: [(WritableKeyPath<GuestVMRates, Double>, [String])] = [
            (\.majorFaultsPerSec, ["pgmajfault"]),
            (\.swapInPagesPerSec, ["pswpin"]),
            (\.swapOutPagesPerSec, ["pswpout"]),
            // Newer kernels split refaults into anon/file; older ones have one counter.
            (\.refaultsPerSec, b["workingset_refault_file"] != nil ? ["workingset_refault_anon", "workingset_refault_file"] : ["workingset_refault"]),
            (\.allocStallsPerSec, ["allocstall_normal", "allocstall_movable", "allocstall_dma", "allocstall_dma32"]),
        ]
        for (kp, keys) in fields {
            switch d(keys) {
            case .some(.none): return nil // counter reset
            case .some(.some(let v)): r[keyPath: kp] = v
            case .none: break
            }
        }
        return r
    }

    public func appBreakdown() async throws -> [AppMemoryUsage] {
        let r = try await shell.shell("dumpsys meminfo -c", timeout: .seconds(60)).checked()
        return GuestParsers.dumpsysMeminfoCompact(r.stdoutString)
    }
}
