import Foundation
import EmuuBase

/// Which activity-manager / package-manager subcommands this guest offers to the shell user.
/// Probed once from `cmd activity help` and `cmd package help`.
public struct GuestCapabilities: Sendable, Hashable {
    public var sendTrimMemory: Bool
    public var kill: Bool
    public var compact: Bool
    public var trimCaches: Bool

    public init(sendTrimMemory: Bool, kill: Bool, compact: Bool, trimCaches: Bool) {
        self.sendTrimMemory = sendTrimMemory
        self.kill = kill
        self.compact = compact
        self.trimCaches = trimCaches
    }

    /// Parses the help texts. Subcommands are listed as indented `  name ...` lines.
    public static func parse(activityHelp: String, packageHelp: String) -> GuestCapabilities {
        func has(_ text: String, _ cmd: String) -> Bool {
            text.split(whereSeparator: \.isNewline).contains { line in
                let t = line.drop { $0 == " " || $0 == "\t" }
                return t.hasPrefix(cmd + " ") || t == cmd[...] || t.hasPrefix(cmd + "\t")
            }
        }
        return GuestCapabilities(
            sendTrimMemory: has(activityHelp, "send-trim-memory"),
            kill: has(activityHelp, "kill"),
            compact: has(activityHelp, "compact"),
            trimCaches: has(packageHelp, "trim-caches")
        )
    }
}

/// Builds the exact device-side command strings (pure; unit-tested).
///
/// All commands go through `cmd activity` / `cmd package` (a native binder client) rather than
/// `am`/`pm`, which start a Java VM per invocation (~0.2 s CPU each) — important when targeting
/// dozens of processes.
public enum GuestCommands {
    /// Lists `<oom_score_adj> <process name>` for processes at or above `minAdj`, using shell builtins
    /// only. Kernel threads (empty cmdline) are skipped.
    public static func processList(minAdj: Int) -> String {
        "for d in /proc/[0-9]*; do read -r a < $d/oom_score_adj || continue; " +
        "if [ \"$a\" -ge \(minAdj) ] || [ \"$a\" -eq 0 ]; then read -r n < $d/cmdline; [ -n \"$n\" ] && echo \"$a $n\"; fi; done 2>/dev/null; true"
    }

    /// Prints MemAvailable (kB) as `avail <kB>`.
    public static let availableProbe = "while read -r k v u; do [ \"$k\" = MemAvailable: ] && echo \"avail $v\"; done < /proc/meminfo"

    public static func trim(processes: [String], level: TrimMemoryLevel) -> String {
        processes.map { "cmd activity send-trim-memory \(DeviceShellQuoting.quote($0)) \(level.rawValue)" }.joined(separator: "; ")
    }

    public static func kill(packages: [String]) -> String {
        packages.map { "cmd activity kill \(DeviceShellQuoting.quote($0))" }.joined(separator: "; ")
    }

    public static func trimCaches(desiredFreeBytes: UInt64) -> String {
        "cmd package trim-caches \(desiredFreeBytes)"
    }

    public static let compactSystem = "cmd activity compact system"

    /// Wraps `body` so the output contains MemAvailable before and after (`avail` lines), with a
    /// short settle delay so freed pages are accounted.
    public static func measured(_ body: String, settleSeconds: Int = 1) -> String {
        "\(availableProbe); echo @@run; \(body); echo @@done; sleep \(settleSeconds); \(availableProbe)"
    }

    /// Parses the before/after MemAvailable lines; returns freed bytes (0 if it went down).
    public static func freedBytes(fromMeasured output: String) -> UInt64? {
        let vals = output.split(whereSeparator: \.isNewline).compactMap { line -> UInt64? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("avail ") else { return nil }
            return UInt64(t.dropFirst(6).trimmingCharacters(in: .whitespaces))
        }
        guard vals.count >= 2, let a = vals.first, let b = vals.last else { return nil }
        return b > a ? (b - a) * 1024 : 0
    }

    /// The command's own output (between the markers).
    public static func body(fromMeasured output: String) -> String {
        GuestParsers.sections(output)["run"] ?? ""
    }
}

/// Guest-side effector (T1 trim, T2 kill) via `DeviceShell`, plus maintenance helpers.
///
/// Safety rules:
/// - the foreground process(es) (oom_score_adj 0) are never targeted;
/// - `ProtectedPackages` (system UI, Play services, Play Store, providers, IMEs, launchers…) are never targeted;
/// - T2 kills only cached processes (oom_score_adj ≥ 900) with `cmd activity kill <pkg>`, which itself
///   only kills background processes of the package. `am kill-all` is not used because it would also
///   kill cached Play services processes.
public final class GuestEffector: MemoryEffector, @unchecked Sendable {
    /// Processes at or above this adj receive trim requests (BACKUP_APP_ADJ and less important).
    public static let trimMinAdj = 300
    /// CACHED_APP_MIN_ADJ.
    public static let cachedMinAdj = 900

    public let shell: any DeviceShell
    public let protected: ProtectedPackages
    /// Upper bound of processes targeted per action (keeps one action cheap).
    public let maxTargets: Int
    private let caps = Locked<GuestCapabilities?>(nil)
    private let log = EmuuLogger(category: "memory.effector")

    /// Also protect packages with running instrumentation (tests, Appium, Maestro) before every trim/kill.
    public let protectInstrumentation: Bool

    public init(shell: any DeviceShell, protected: ProtectedPackages = .default, maxTargets: Int = 40,
                protectInstrumentation: Bool = true) {
        self.shell = shell
        self.protected = protected
        self.maxTargets = max(1, maxTargets)
        self.protectInstrumentation = protectInstrumentation
    }

    /// Packages taking part in a running instrumentation right now (empty when the probe fails: the
    /// foreground and `ProtectedPackages` rules still apply).
    public func instrumentationPackages() async -> Set<String> {
        guard protectInstrumentation else { return [] }
        do {
            let r = try await shell.shell(InstrumentationProbe.command, timeout: .seconds(20))
            return InstrumentationProbe.packages(fromProbeOutput: r.stdoutString)
        } catch {
            log.warning("instrumentation probe failed: \(error.localizedDescription)")
            return []
        }
    }

    /// `protected` plus the packages of running instrumentations.
    private func currentProtection() async -> ProtectedPackages {
        let busy = await instrumentationPackages()
        if !busy.isEmpty { log.info("protecting instrumented packages: \(busy.sorted().joined(separator: ", "))") }
        return busy.isEmpty ? protected : protected.adding(Array(busy))
    }

    public func handles(_ action: GovernorAction) -> Bool {
        switch action {
        case .trimMemory, .trimCaches, .killBackground: return true
        default: return false
        }
    }

    public func apply(_ action: GovernorAction) async throws -> EffectorOutcome {
        switch action {
        case .trimMemory(let level, let packages): return try await trim(level: level, packages: packages)
        case .trimCaches(let bytes): return try await trimCaches(desiredFreeBytes: bytes)
        case .killBackground(let packages): return try await killBackground(packages: packages)
        default: return .unsupported("GuestEffector does not handle \(action)")
        }
    }

    // MARK: capabilities

    public func capabilities() async throws -> GuestCapabilities {
        if let c = caps.current { return c }
        // adb/transport failures must throw (never read as "unsupported", which would permanently
        // disable a tier). `cmd … help` exits 0 when the service exists.
        let a = try await shell.shell("cmd activity help 2>&1", timeout: .seconds(30)).checked()
        let p = try await shell.shell("cmd package help 2>&1", timeout: .seconds(30)).checked()
        guard a.stdoutString.contains("Activity manager") || a.stdoutString.contains("send-trim-memory") else {
            throw EmuuError.deviceNotReady(shell.serial)
        }
        let c = GuestCapabilities.parse(activityHelp: a.stdoutString, packageHelp: p.stdoutString)
        caps.set(c)
        return c
    }

    // MARK: targets

    public struct Targets: Sendable, Hashable {
        public var foreground: [String]
        public var candidates: [GuestParsers.ProcessEntry]
    }

    /// Background processes (adj ≥ `minAdj`) that may be targeted, least important first, plus the
    /// foreground process names that were excluded.
    public func targets(minAdj: Int, protected shield: ProtectedPackages? = nil) async throws -> Targets {
        let r = try await shell.shell(GuestCommands.processList(minAdj: minAdj), timeout: .seconds(15)).checked()
        return Self.selectTargets(GuestParsers.processEntries(r.stdoutString), minAdj: minAdj, protected: shield ?? protected, limit: maxTargets)
    }

    /// Pure target selection (unit-tested).
    public static func selectTargets(_ entries: [GuestParsers.ProcessEntry], minAdj: Int, protected: ProtectedPackages, limit: Int) -> Targets {
        let fgNames = entries.filter { $0.adj == 0 }.map(\.name)
        let fgPackages = Set(fgNames.compactMap(GuestParsers.packageName(fromProcessName:)))
        var seen = Set<String>()
        let picked = entries
            .filter { $0.adj >= minAdj }
            .filter { e in
                guard let pkg = GuestParsers.packageName(fromProcessName: e.name) else { return false }
                return !fgPackages.contains(pkg) && !protected.contains(pkg)
            }
            .sorted { $0.adj > $1.adj }
            .filter { seen.insert($0.name).inserted }
        return Targets(foreground: fgNames, candidates: Array(picked.prefix(limit)))
    }

    // MARK: actions

    public func trim(level: TrimMemoryLevel, packages: [String]) async throws -> EffectorOutcome {
        guard try await capabilities().sendTrimMemory else { return .unsupported("cmd activity send-trim-memory not available") }
        let shield = await currentProtection()
        let t = try await targets(minAdj: Self.trimMinAdj, protected: shield)
        var procs: [String]
        if packages.isEmpty {
            procs = t.candidates.map(\.name)
        } else {
            let fg = Set(t.foreground.compactMap(GuestParsers.packageName(fromProcessName:)))
            procs = packages.filter { !fg.contains($0) && !shield.contains($0) }
        }
        procs = Array(procs.prefix(maxTargets))
        guard !procs.isEmpty else { return .noop("no background processes to trim") }
        log.info("T1 trim \(level.rawValue): \(procs.joined(separator: " "))")
        let out = try await shell.shell(GuestCommands.measured(GuestCommands.trim(processes: procs, level: level)), timeout: .seconds(60))
        let errors = Self.errorLines(GuestCommands.body(fromMeasured: out.stdoutString) + "\n" + out.stderrString)
        let freed = GuestCommands.freedBytes(fromMeasured: out.stdoutString)
        if errors.count == procs.count {
            return .noop("send-trim-memory rejected for all \(procs.count) processes: \(errors.first ?? "")")
        }
        return .applied("trim \(level.rawValue) → \(procs.count - errors.count)/\(procs.count) processes", reclaimedBytes: freed)
    }

    public func killBackground(packages: [String]) async throws -> EffectorOutcome {
        guard try await capabilities().kill else { return .unsupported("cmd activity kill not available") }
        let shield = await currentProtection()
        let t = try await targets(minAdj: Self.cachedMinAdj, protected: shield)
        let fg = Set(t.foreground.compactMap(GuestParsers.packageName(fromProcessName:)))
        var pkgs: [String] = []
        let source = packages.isEmpty ? t.candidates.compactMap { GuestParsers.packageName(fromProcessName: $0.name) } : packages
        for p in source where !fg.contains(p) && !shield.contains(p) && !pkgs.contains(p) { pkgs.append(p) }
        pkgs = Array(pkgs.prefix(maxTargets))
        guard !pkgs.isEmpty else { return .noop("no cached app processes to kill") }
        let out = try await shell.shell(GuestCommands.measured(GuestCommands.kill(packages: pkgs)), timeout: .seconds(60))
        let freed = GuestCommands.freedBytes(fromMeasured: out.stdoutString)
        log.notice("T2 kill: cmd activity kill \(pkgs.joined(separator: " "))")
        return .applied("killed background processes of \(pkgs.count) packages: \(pkgs.joined(separator: ", "))", reclaimedBytes: freed)
    }

    public func trimCaches(desiredFreeBytes: UInt64) async throws -> EffectorOutcome {
        guard try await capabilities().trimCaches else { return .unsupported("cmd package trim-caches not available") }
        let r = try await shell.shell(GuestCommands.trimCaches(desiredFreeBytes: desiredFreeBytes) + " 2>&1", timeout: .seconds(120))
        let text = r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !r.succeeded || !Self.errorLines(text).isEmpty {
            if text.contains("SecurityException") { return .unsupported("trim-caches denied: \(text.prefix(200))") }
            throw EmuuError.processFailed(command: "cmd package trim-caches", exitCode: r.exitCode, stderr: String(text.prefix(500)))
        }
        return .applied("trim-caches \(ByteCount.format(desiredFreeBytes))")
    }

    /// `cmd activity compact system` (compacts system_server's memory into zram).
    public func compactSystem() async throws -> EffectorOutcome {
        guard try await capabilities().compact else { return .unsupported("cmd activity compact not available") }
        let out = try await shell.shell(GuestCommands.measured(GuestCommands.compactSystem + " 2>&1"), timeout: .seconds(60))
        let body = GuestCommands.body(fromMeasured: out.stdoutString)
        let errs = Self.errorLines(body)
        if !errs.isEmpty {
            if body.contains("SecurityException") || body.contains("not permitted") { return .unsupported("compact denied: \(errs[0])") }
            return .noop("compact: \(errs[0])")
        }
        return .applied("compact system", reclaimedBytes: GuestCommands.freedBytes(fromMeasured: out.stdoutString))
    }

    /// One entry per failed `cmd` invocation. Verified format on API 36: a failing shell command
    /// prints `Exception occurred while executing '<cmd>':` followed by the Java exception and stack
    /// (exit 255); unknown subcommands print `Unknown command: …`.
    static func errorLines(_ text: String) -> [String] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        var out: [String] = []
        for (i, line) in lines.enumerated() {
            if line.hasPrefix("Exception occurred while executing") {
                // Report the exception line that follows (e.g. "java.lang.IllegalArgumentException: Unknown process: x").
                out.append(i + 1 < lines.count ? lines[i + 1] : line)
            } else if line.hasPrefix("Unknown command") || line.hasPrefix("Error:") {
                out.append(line)
            }
        }
        return out
    }
}
