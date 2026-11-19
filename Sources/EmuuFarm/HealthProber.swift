import Darwin
import Foundation
import EmuuBase
import EmuuEngine

/// Runs the layered health probes against one engine/device. Each probe has its own timeout and is reported
/// separately; expensive probes run only when asked (`deep`) or when a cheap one looks off.
///
/// Probes (cheap → expensive):
/// 1. `process`   engine pid alive; ps state T (SIGSTOP) and whether Emuu froze it (freeze marker);
/// 2. `console`   the engine's console answers `ping` within 3 s (QEMU main loop alive);
/// 3. `adb`       `adb -s S get-state` is `device` (not offline/unauthorized/missing);
/// 4. `shell`     one `adb shell` round trip: echo, `sys.boot_completed`, `boot_id`, uptime, /data free;
/// 5. `framework` a system_server binder call (`cmd package resolve-activity` for the launcher home intent) answers;
/// 6. `ui`        (deep) `dumpsys window` focus: no "isn't responding"/"keeps stopping" system dialog in front.
public struct HealthProber: Sendable {
    public var runner: any ProcessRunner
    public var adb: URL
    public var host: any HostProcessInspecting
    public var consoleConnector: any ConsoleConnector
    public var shellTimeout: Duration = .seconds(10)
    public var frameworkTimeout: Duration = .seconds(15)

    public init(runner: any ProcessRunner, adb: URL, host: any HostProcessInspecting = SystemHostProcesses(),
                consoleConnector: any ConsoleConnector = TCPConsoleConnector()) {
        self.runner = runner
        self.adb = adb
        self.host = host
        self.consoleConnector = consoleConnector
    }

    public struct Target: Sendable {
        public var instance: String
        public var enginePID: Int32?
        public var consolePort: Int?
        public var frozenByEmuu: Bool
        public var expectedBootID: String?
        public var withinBootGrace: Bool

        public init(instance: String, enginePID: Int32?, consolePort: Int?, frozenByEmuu: Bool = false,
                    expectedBootID: String? = nil, withinBootGrace: Bool = false) {
            self.instance = instance
            self.enginePID = enginePID
            self.consolePort = consolePort
            self.frozenByEmuu = frozenByEmuu
            self.expectedBootID = expectedBootID
            self.withinBootGrace = withinBootGrace
        }

        public var serial: String? { consolePort.map { "emulator-\($0)" } }
    }

    public func check(_ t: Target, deep: Bool = false, farmDevice: Bool = false) async -> HealthReport {
        var probes: [ProbeResult] = []
        var f = HealthFacts(engineAlive: false)
        f.frozenByEmuu = t.frozenByEmuu
        f.expectedBootID = t.expectedBootID
        f.withinBootGrace = t.withinBootGrace
        let now = Date()

        // 1. process
        if let pid = t.enginePID, host.isAlive(pid) {
            f.engineAlive = true
            f.engineStopped = host.isStopped(pid)
            probes.append(ProbeResult(name: "process", status: f.engineStopped && !t.frozenByEmuu ? .fail : .ok,
                                      detail: "pid \(pid)" + (f.engineStopped ? (t.frozenByEmuu ? ", frozen by Emuu" : ", SIGSTOPped (not by Emuu)") : ", running")))
        } else {
            probes.append(ProbeResult(name: "process", status: .fail, detail: t.enginePID.map { "pid \($0) is gone" } ?? "no engine process"))
        }
        func finish() -> HealthReport {
            let e = HealthEvaluator.evaluate(f)
            return HealthReport(instance: t.instance, serial: t.serial, verdict: e.verdict, reason: e.reason, fault: e.fault,
                                checkedAt: now, probes: probes, bootID: f.bootID,
                                suggestedStep: HealLadder.steps(for: e.fault, farmDevice: farmDevice).first)
        }
        guard f.engineAlive, !f.engineStopped, let port = t.consolePort, let serial = t.serial else {
            for name in ["console", "adb", "shell", "framework"] { probes.append(ProbeResult(name: name, status: .skip, detail: "engine not running")) }
            return finish()
        }

        // 2. console greeting
        let c0 = ContinuousClock.now
        let consoleOK = await Self.consoleGreets(port: port, connector: consoleConnector, timeout: .seconds(3))
        f.consoleOK = consoleOK
        probes.append(ProbeResult(name: "console", status: consoleOK ? .ok : .fail,
                                  detail: consoleOK ? "port \(port) answered" : "port \(port) did not greet within 3 s", millis: ms(since: c0)))

        // 3. adb transport
        let a0 = ContinuousClock.now
        let state = await adbState(serial)
        f.adbState = state
        probes.append(ProbeResult(name: "adb", status: state == "device" ? .ok : .fail, detail: "transport \(state)", millis: ms(since: a0)))
        guard state == "device" else {
            probes.append(ProbeResult(name: "shell", status: .skip, detail: "no adb transport"))
            probes.append(ProbeResult(name: "framework", status: .skip, detail: "no adb transport"))
            return finish()
        }

        // 4. shell round trip with the cheap guest facts
        let s0 = ContinuousClock.now
        let cmd = "echo emuu-ok; getprop sys.boot_completed; cat /proc/sys/kernel/random/boot_id; cut -d' ' -f1 /proc/uptime; df -k /data | tail -1"
        if let r = try? await runner.run(ProcessRequest(executable: adb, arguments: ["-s", serial, "shell", cmd], timeout: shellTimeout)),
           r.succeeded, r.stdoutString.contains("emuu-ok") {
            let lines = r.stdoutString.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let parsed = Self.parseShellFacts(lines)
            f.shellOK = true
            f.bootCompleted = parsed.bootCompleted
            f.bootID = parsed.bootID
            f.uptimeSeconds = parsed.uptime
            f.dataFreeBytes = parsed.dataFree
            probes.append(ProbeResult(name: "shell", status: parsed.bootCompleted ? .ok : .fail,
                                      detail: "boot_completed=\(parsed.bootCompleted ? 1 : 0) uptime=\(Int(parsed.uptime ?? -1))s data_free=\(parsed.dataFree.map(ByteCount.format) ?? "?")",
                                      millis: ms(since: s0)))
        } else {
            f.shellOK = false
            probes.append(ProbeResult(name: "shell", status: .fail, detail: "no answer within \(shellTimeout)", millis: ms(since: s0)))
            probes.append(ProbeResult(name: "framework", status: .skip, detail: "shell failed"))
            return finish()
        }

        // 5. framework (binder into system_server's package manager and activity resolution)
        if f.bootCompleted == true {
            let fw0 = ContinuousClock.now
            let fwCmd = "cmd package resolve-activity -a android.intent.action.MAIN -c android.intent.category.HOME"
            let r = try? await runner.run(ProcessRequest(executable: adb, arguments: ["-s", serial, "shell", fwCmd], timeout: frameworkTimeout))
            let ok = r?.succeeded == true && (r?.stdoutString.contains("packageName=") ?? false)
            f.frameworkOK = ok
            probes.append(ProbeResult(name: "framework", status: ok ? .ok : .fail,
                                      detail: ok ? "system_server answered" : (r == nil ? "no answer within \(frameworkTimeout)" : "unexpected reply"),
                                      millis: ms(since: fw0)))
        } else {
            probes.append(ProbeResult(name: "framework", status: .skip, detail: "not booted"))
        }

        // 6. UI (deep only, or when something already looks wrong)
        if deep {
            let u0 = ContinuousClock.now
            if let r = try? await runner.run(ProcessRequest(executable: adb, arguments: ["-s", serial, "shell", "dumpsys window | grep -E 'mCurrentFocus|mFocusedApp'"],
                                                            timeout: frameworkTimeout)), r.succeeded {
                f.systemDialog = Self.systemDialog(inFocus: r.stdoutString)
                probes.append(ProbeResult(name: "ui", status: f.systemDialog == nil ? .ok : .fail,
                                          detail: f.systemDialog ?? (r.stdoutString.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "focus unknown"),
                                          millis: ms(since: u0)))
            } else {
                probes.append(ProbeResult(name: "ui", status: .fail, detail: "dumpsys window did not answer", millis: ms(since: u0)))
                f.frameworkOK = false
            }
        }
        return finish()
    }

    func adbState(_ serial: String) async -> String {
        guard let r = try? await runner.run(ProcessRequest(executable: adb, arguments: ["-s", serial, "get-state"], timeout: .seconds(5))) else {
            return "timeout"
        }
        return Self.parseADBState(stdout: r.stdoutString, stderr: String(decoding: r.stderr, as: UTF8.self))
    }

    /// `adb get-state` → device | offline | unauthorized | missing | <other>.
    public static func parseADBState(stdout: String, stderr: String) -> String {
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { return out }
        let err = stderr.lowercased()
        if err.contains("not found") { return "missing" }
        if err.contains("offline") { return "offline" }
        if err.contains("unauthorized") { return "unauthorized" }
        return err.isEmpty ? "missing" : "error"
    }

    public struct ShellFacts: Equatable {
        public var bootCompleted: Bool
        public var bootID: String?
        public var uptime: Double?
        public var dataFree: UInt64?
    }

    /// Lines of the shell probe: `emuu-ok`, boot_completed, boot_id, uptime, `df -k /data | tail -1`.
    public static func parseShellFacts(_ lines: [String]) -> ShellFacts {
        guard let start = lines.firstIndex(of: "emuu-ok") else { return ShellFacts(bootCompleted: false) }
        let rest = Array(lines[(start + 1)...])
        func at(_ i: Int) -> String? { i < rest.count ? rest[i] : nil }
        let df = at(3)?.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) ?? []
        // Filesystem 1K-blocks Used Available Use% Mounted
        let free = df.count >= 4 ? UInt64(df[3]).map { $0 * 1024 } : nil
        let bootID = at(1).flatMap { $0.count == 36 ? $0 : nil }
        return ShellFacts(bootCompleted: at(0) == "1", bootID: bootID, uptime: at(2).flatMap(Double.init), dataFree: free)
    }

    /// Android's ANR / crash dialogs are system windows titled "Application Not Responding: <pkg>" or
    /// "Application Error: <pkg>" in `mCurrentFocus`.
    public static func systemDialog(inFocus text: String) -> String? {
        for line in text.split(separator: "\n") where line.contains("mCurrentFocus") {
            for marker in ["Application Not Responding", "Application Error", "isn't responding", "keeps stopping"] where line.contains(marker) {
                if let r = line.range(of: marker) {
                    return String(line[r.lowerBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " }"))
                }
            }
        }
        return nil
    }

    /// Console `ping` → "I am alive!" (connect + auth + command), served by the engine's main loop.
    static func consoleGreets(port: Int, connector: any ConsoleConnector, timeout: Duration) async -> Bool {
        let client = ConsoleClient(port: port, connector: connector)
        defer { Task { await client.disconnect() } }
        return await client.ping(timeout: timeout)
    }

    private func ms(since t: ContinuousClock.Instant) -> Int {
        Int(((ContinuousClock.now - t).timeInterval * 1000).rounded())
    }
}
