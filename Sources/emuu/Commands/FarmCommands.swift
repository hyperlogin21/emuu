import Darwin
import Foundation
import ArgumentParser
import EmuuBase
import EmuuEngine
import EmuuFarm

/// Exit codes of `emuu farm acquire` and `emuu run` besides the command's own.
enum FarmExit {
    /// No device could be acquired (none ready within --timeout, pool down, capacity).
    static let unavailable: Int32 = 69
    /// The leased device was lost during the run (hung/dead; the farm replaced it).
    static let deviceLost: Int32 = 75
    /// `emuu run --timeout` expired.
    static let timeout: Int32 = 124
}

/// Per-invocation farm wiring.
struct FarmContext: Sendable {
    let ctx: CLIContext
    let farm: FarmPaths

    static func live() throws -> FarmContext {
        let ctx = try CLIContext.live()
        let farm = FarmPaths(paths: ctx.paths)
        try farm.ensure()
        return FarmContext(ctx: ctx, farm: farm)
    }

    func golden(_ name: String?) throws -> GoldenRecord {
        let all = GoldenStore.list(farm: farm)
        if let name {
            guard let g = GoldenStore.load(name, farm: farm) else {
                throw CLIError("No sealed golden image '\(name)'. Known: \(all.map(\.name).joined(separator: ", ").ifEmpty("none")). Create one with `emuu golden create \(name) --seal`.")
            }
            return g
        }
        if all.count == 1 { return all[0] }
        if all.isEmpty { throw CLIError("No golden image yet. Create one with `emuu golden create base --seal`.") }
        throw CLIError("Several golden images (\(all.map(\.name).joined(separator: ", "))); pick one with --golden.")
    }

    func store(_ pool: String) -> FarmStateStore { FarmStateStore(farm: farm, pool: pool) }

    func daemonAlive(_ pool: String) -> Bool { FarmFileLock.isHeld(url: farm.daemonLock(pool)) }

    /// Explicit pool, else "default" when it exists, else the only pool.
    func pool(_ explicit: String?) throws -> String {
        if let explicit { return explicit }
        let pools = farm.poolNames()
        if pools.contains("default") || pools.isEmpty { return "default" }
        if pools.count == 1 { return pools[0] }
        throw CLIError("Several pools (\(pools.joined(separator: ", "))); pick one with --pool.")
    }

    func cost(_ golden: GoldenRecord) -> DeviceCost { DeviceCost.estimate(guestRAMMB: golden.guestRAMMB, cores: golden.cores) }

    func driver() throws -> LiveFarmDriver {
        LiveFarmDriver(engines: try EngineEnvironment(paths: ctx.paths, sdk: ctx.sdk, timings: LiveFarmDriver.farmTimings))
    }

    /// Ports planned for any pool device or ephemeral clone (so allocations never collide before engines bind).
    func reservedPorts() -> Set<Int> {
        var out = Set<Int>()
        for p in farm.poolNames() { (try? store(p).read())?.devices.forEach { out.insert($0.consolePort) } }
        for owner in ephemeralOwners() { if let port = owner.consolePort { out.insert(port) } }
        return out
    }

    func ephemeralOwners() -> [EphemeralOwner] {
        ((try? FileManager.default.contentsOfDirectory(at: farm.ephemeral, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .compactMap { try? FarmJSON.decoder.decode(EphemeralOwner.self, from: Data(contentsOf: $0)) }
    }

    /// Health check used before a device is handed out: thaws a frozen device first.
    func preLeaseCheck(_ d: FarmDevice, golden: GoldenRecord) async -> HealthSummary {
        if d.state == .frozen, let pid = d.enginePID {
            kill(pid, SIGCONT)
            if let id = InstanceID(rawValue: d.instance) { FreezeMarker.clear(for: id, paths: ctx.paths) }
        }
        let prober = HealthProber(runner: SystemProcessRunner(), adb: ctx.sdk.adb)
        let report = await prober.check(.init(instance: d.instance, enginePID: d.enginePID, consolePort: d.consolePort,
                                              expectedBootID: golden.bootID), farmDevice: true)
        return report.summary
    }
}

/// Spawns `emuu <args>` detached (own session), stdout/stderr appended to `log`.
enum SelfSpawn {
    static func detached(_ args: [String], log: URL) throws -> Int32 {
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        let exe = Start.selfExecutable().path
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fa, 1, log.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        posix_spawn_file_actions_adddup2(&fa, 1, 2)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        // Not the spawning Swift thread's (possibly blocked) signal mask, nor the dispositions this process ignores.
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attr, &none)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for sig in [SIGINT, SIGTERM, SIGHUP, SIGPIPE] { sigaddset(&defaults, sig) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        let argv = ([exe] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe, &fa, &attr, argv, environ)
        guard rc == 0 else { throw CLIError("could not start \(exe): \(String(cString: strerror(rc)))") }
        return pid
    }
}

// MARK: golden

struct Golden: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Golden images: prepared, sealed instances that farm devices are cloned from (APFS copy-on-write).",
        subcommands: [GoldenCreate.self, GoldenSeal.self, GoldenList.self, GoldenDelete.self])
}

struct GoldenCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a golden instance (farm profile), boot it and prepare it; seal it now (--seal) or after you set it up.",
        discussion: """
        Without --seal the instance keeps running headless: install APKs (`emuu install -i <name> app.apk`), change \
        settings or sign in (`emuu start <name> --window` after `emuu stop <name>`), then `emuu golden seal <name>`.
        --from copies an existing, stopped instance (its disks, not its snapshot) instead of creating a fresh one; the \
        source is only read.
        """)

    @Argument(help: "Golden name (an instance of that name is created).") var name: String
    @Option(help: "Copy this stopped instance's disks instead of starting from a fresh image.") var from: String?
    @Option(help: "Guest RAM in MB (below 2048 is enforced with -qemu -m).") var ram: Int = FarmProfile.guestRAMMB
    @Option(help: "vCPUs per device.") var cores: Int = FarmProfile.cores
    @Option(help: "GPU mode (host, swiftshader_indirect, …).") var gpu: GPUMode = FarmProfile.gpu
    @Option(help: "System image tag: google_apis_playstore (default), google_apis or default, if installed.") var image: String?
    @Flag(help: "Disable preinstalled apps tests do not need (see `emuu golden seal --help`).") var lean = false
    @Flag(help: "Seal right away (after the minimum uptime) instead of leaving it running for manual setup.") var seal = false
    @Flag(help: "JSON output (with --seal: the golden record).") var json = false

    func run() async throws {
        let fc = try FarmContext.live()
        let ctx = fc.ctx
        guard let id = InstanceID(rawValue: name) else { throw CLIError(describe(EmuuError.invalidInstanceID(name))) }
        guard !ctx.store.exists(id) else { throw CLIError("An instance named \(name) exists already; seal it with `emuu golden seal \(name)`.") }
        if let from {
            let src = try ctx.resolveInstance(from)
            try ctx.store.clone(src.id, to: id, includeSnapshots: false) { c in
                c.automationMode = true
                c.audioOutput = false
            }
        } else {
            let images = ctx.engines.installedImages.filter { $0.ref.abi == "arm64-v8a" }
            let wanted = image ?? "google_apis_playstore"
            guard let img = images.first(where: { $0.ref.tag == wanted }) else {
                throw CLIError("No arm64 \(wanted) image installed (installed: \(images.map(\.description).joined(separator: ", ").ifEmpty("none"))).")
            }
            var config = InstancePreset.lite.makeConfig(id: id, systemImage: img.ref, gpu: gpu, audioOutput: false)
            config.ramMB = ram
            config.cores = cores
            // The engine raises userdata to 6 GiB for android-36.1 on first boot anyway (and rewrites config.ini).
            config.dataPartitionMB = 6144
            config.guestRAMEnforced = ram < 2048 ? true : nil
            config.automationMode = true
            if config.vmHeapMB >= ram { config.vmHeapMB = 192 }
            do { try config.validate() } catch { throw ValidationError(describe(error)) }
            try ctx.store.create(config)
        }
        Out.err("Booting \(name) (cold boot)…")
        let child = try await SystemProcessRunner().run(ProcessRequest(
            executable: Start.selfExecutable(),
            arguments: ["start", name, "--detach", "--no-governor", "--automation", "--cold-boot"], timeout: .seconds(900)))
        guard child.succeeded else { throw CLIError("could not boot \(name): \(child.stderrString)\(child.stdoutString)") }
        let config = try ctx.store.load(id)
        let serial = try await ctx.ensureRunning(config)
        _ = try await GoldenPrep.prepare(ctx: ctx, serial: serial, lean: lean)
        if seal {
            let record = try await GoldenPrep.seal(fc: fc, config: config, lean: lean, prep: false, echo: !json)
            if json { try Out.json(record) } else { Out.line("Golden \(name) sealed (boot id \(record.bootID ?? "?")). Start a pool: `emuu farm up --golden \(name)`.") }
        } else {
            Out.line("\(name) is running on \(serial) (animations off, adb-install verification off\(lean ? ", lean" : "")).")
            Out.line("Set it up now (adb -s \(serial) …, `emuu install -i \(name) app.apk`), then seal it: `emuu golden seal \(name)`.")
        }
    }
}

struct GoldenSeal: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "seal",
        abstract: "Prepare a running instance for farming and save its quick-boot snapshot as the golden state.",
        discussion: """
        Applies the farm settings (animations off, no adb-install verification prompt, stay awake), with --lean also \
        `pm disable-user` for preinstalled apps tests rarely need (Play Store, Play services, Chrome, WebView, \
        launcher and Settings stay enabled), waits until the guest has been up \(Int(FarmProfile.minimumUptimeBeforeSeal)) s, \
        records the guest boot id, and stops the engine with a quick-boot save. Clones resume from exactly this state.
        """)

    @Argument(help: "Instance to seal.") var name: String
    @Flag(help: "Also disable the lean package list.") var lean = false
    @Flag(help: "Do not apply the farm settings (seal as is).") var noPrep = false
    @Flag(help: "JSON output.") var json = false

    func run() async throws {
        let fc = try FarmContext.live()
        let config = try fc.ctx.resolveInstance(name)
        let record = try await GoldenPrep.seal(fc: fc, config: config, lean: lean, prep: !noPrep, echo: !json)
        if json { try Out.json(record) } else {
            Out.line("Golden \(record.name) sealed: snapshot \(ByteCount.format(record.snapshotBytes)), boot id \(record.bootID ?? "?"), guest \(record.guestRAMMB) MB / \(record.cores) cores.")
        }
    }
}

struct GoldenList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List sealed golden images.")
    @Flag(help: "JSON output.") var json = false

    func run() async throws {
        let fc = try FarmContext.live()
        let all = GoldenStore.list(farm: fc.farm)
        if json { return try Out.json(all) }
        if all.isEmpty { return Out.line("No golden images. Create one with `emuu golden create base --seal`.") }
        Out.line(Fmt.table(["NAME", "SEALED", "RAM", "CORES", "GPU", "LEAN", "SNAPSHOT", "IMAGE"], all.map {
            [$0.name, ISO8601DateFormatter().string(from: $0.sealedAt), "\($0.guestRAMMB) MB", "\($0.cores)", $0.gpu, $0.lean ? "yes" : "no",
             ByteCount.format($0.snapshotBytes), $0.image]
        }))
    }
}

struct GoldenDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a golden image and its instance.")
    @Argument var name: String
    @Flag(name: [.short, .long], help: "Do not ask.") var yes = false

    func run() async throws {
        let fc = try FarmContext.live()
        for p in fc.farm.poolNames() where (try? fc.store(p).read())?.golden == name {
            throw CLIError("Pool '\(p)' uses \(name); `emuu farm down --pool \(p)` first.")
        }
        guard yes else { throw CLIError("Refusing to delete golden \(name) without --yes.") }
        if let id = InstanceID(rawValue: name), fc.ctx.store.exists(id) { try await fc.ctx.engines.deleteInstance(id) }
        GoldenStore.remove(name, farm: fc.farm)
        Out.line("Deleted golden \(name).")
    }
}

enum GoldenPrep {
    static func adbShell(_ ctx: CLIContext, _ serial: DeviceSerial, _ command: String, timeout: Duration = .seconds(30)) async throws -> String {
        let r = try await SystemProcessRunner().run(ProcessRequest(executable: ctx.sdk.adb, arguments: ["-s", serial.rawValue, "shell", command], timeout: timeout))
        return r.trimmedStdout
    }

    /// Farm settings, plus the lean package list. Returns the packages actually disabled.
    static func prepare(ctx: CLIContext, serial: DeviceSerial, lean: Bool) async throws -> [String] {
        _ = try await adbShell(ctx, serial, FarmProfile.prepCommands.joined(separator: "; "))
        guard lean else { return [] }
        var disabled: [String] = []
        for p in FarmProfile.leanPackages {
            let out = (try? await adbShell(ctx, serial, "pm disable-user --user 0 \(p) 2>&1")) ?? ""
            if out.contains("disabled") { disabled.append(p) }
        }
        return disabled
    }

    static func seal(fc: FarmContext, config: InstanceConfig, lean: Bool, prep: Bool, echo: Bool) async throws -> GoldenRecord {
        let ctx = fc.ctx
        let id = config.id
        let serial = try await ctx.ensureRunning(config)
        var disabled: [String] = []
        if prep { disabled = try await prepare(ctx: ctx, serial: serial, lean: lean) } else if lean {
            disabled = try await prepare(ctx: ctx, serial: serial, lean: true)
        }
        if !lean {
            disabled = (try? await adbShell(ctx, serial, "pm list packages -d"))?.split(separator: "\n")
                .map { $0.replacingOccurrences(of: "package:", with: "") }.filter { FarmProfile.leanPackages.contains($0) } ?? []
        }
        while true {
            let up = Double((try? await adbShell(ctx, serial, "cut -d' ' -f1 /proc/uptime")) ?? "") ?? 0
            if up >= FarmProfile.minimumUptimeBeforeSeal { break }
            if echo { Out.progress("Waiting for first-boot work to settle (uptime \(Int(up)) of \(Int(FarmProfile.minimumUptimeBeforeSeal)) s)…") }
            try await Task.sleep(for: .seconds(5))
        }
        Out.endProgress()
        let bootID = try? await adbShell(ctx, serial, "cat /proc/sys/kernel/random/boot_id")
        let uptime = Double((try? await adbShell(ctx, serial, "cut -d' ' -f1 /proc/uptime")) ?? "")
        if echo { Out.err("Saving the golden snapshot…") }
        if let sup = SupervisorRegistry(paths: ctx.paths).liveSupervisor(for: id) {
            let reply = try await ControlClient(socketPath: sup.socketPath).send(ControlRequest(command: .stop, save: true), timeout: .seconds(240))
            guard reply.ok else { throw CLIError("seal: stop failed: \(reply.message ?? "?")") }
            let registry = SupervisorRegistry(paths: ctx.paths)
            for _ in 0..<150 where registry.liveSupervisor(for: id) != nil { try await Task.sleep(for: .milliseconds(100)) }
        } else {
            let engine = try await ctx.engines.engine(for: id)
            try await engine.stop(.graceful(saveQuickBoot: true))
        }
        let snap = ctx.paths.avdDirectory(for: id).appendingPathComponent("snapshots/default_boot")
        let ram = (try? FileManager.default.attributesOfItem(atPath: snap.appendingPathComponent("ram.bin").path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard ram >= EngineInstance.minimumRAMSnapshotBytes,
              FileManager.default.fileExists(atPath: snap.appendingPathComponent("hardware.ini").path) else {
            throw CLIError("seal: the engine did not write a complete quick-boot snapshot (ram.bin \(ram) bytes); start \(id) and seal again")
        }
        let total = ((try? FileManager.default.contentsOfDirectory(at: snap, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .reduce(UInt64(0)) { $0 + UInt64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        let record = GoldenRecord(name: id.rawValue, sealedAt: Date(), bootID: bootID?.isEmpty == false ? bootID : nil,
                                  guestUptimeAtSeal: uptime, guestRAMMB: EffectiveRAM.megabytes(for: config, paths: ctx.paths),
                                  cores: config.cores, gpu: config.gpu.rawValue, image: config.systemImage.description,
                                  lean: lean || !disabled.isEmpty, snapshotBytes: total, disabledPackages: disabled)
        try GoldenStore.save(record, farm: fc.farm)
        return record
    }
}

// MARK: clone

struct Clone: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Make a persistent instance from a golden image (APFS clone incl. its snapshot; resumes in ~2 s).")
    @Argument(help: "Golden image.") var golden: String
    @Argument(help: "New instance name.") var name: String

    func run() async throws {
        let fc = try FarmContext.live()
        let g = try fc.golden(golden)
        guard let id = InstanceID(rawValue: name) else { throw CLIError(describe(EmuuError.invalidInstanceID(name))) }
        let t0 = ContinuousClock.now
        try fc.ctx.store.clone(try InstanceID(validating: g.name), to: id, includeSnapshots: true) { c in c.goldenSource = g.name }
        Out.line("Cloned \(g.name) → \(name) in \(Fmt.seconds(ContinuousClock.now - t0)). Start it with `emuu start \(name)`.")
    }
}

// MARK: farm

struct Farm: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Device pool for automated tests: warm devices from a golden image, leased over adb.",
        discussion: """
        emuu golden create base --seal       # once: prepared, sealed golden image
        emuu farm up --size auto             # daemon keeps N warm devices (N from host RAM/CPU)
        emuu farm acquire --wait --json      # lease one: {"serial": "emulator-5554", "leaseID": …}
        emuu farm release <lease>            # back to the golden state (snapshot load, ~1.5 s)
        emuu farm status --json / farm down / farm gc
        """,
        subcommands: [FarmUp.self, FarmDown.self, FarmAcquire.self, FarmRelease.self, FarmHeartbeat.self, FarmStatus.self,
                      FarmGC.self, FarmCapacity.self, FarmDaemon.self])
}

struct PoolOption: ParsableArguments {
    @Option(help: "Pool name (default: \"default\", or the only pool).") var pool: String?
}

/// `--size N|auto`.
enum PoolSize: ExpressibleByArgument, Equatable {
    case auto
    case fixed(Int)
    init?(argument: String) {
        if argument == "auto" { self = .auto } else if let n = Int(argument), n >= 1 { self = .fixed(n) } else { return nil }
    }
}

struct FarmUp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "up",
        abstract: "Start (or resize) a pool: a background daemon keeps N warm, health-checked devices.")

    @OptionGroup var poolOption: PoolOption
    @Option(help: "Golden image (default: the only one).") var golden: String?
    @Option(help: "Devices to keep warm: a number or `auto` (the capacity guard's ceiling for this host).") var size: PoolSize = .auto
    @Flag(help: "Allow more devices than the capacity guard computes (warns).") var overrideCapacity = false
    @Option(help: "After release: reset (snapshot load in the running engine) or recycle (fresh clone).") var releaseMode: ReleaseModeArgument = .reset
    @Option(help: "Leased device turns unhealthy: replace (default), restart (heal in place) or report.") var healLeased: HealLeasedArgument = .replace
    @Option(help: "Lease time-to-live without heartbeat, seconds.") var ttl: Int = 1800
    @Option(help: "SIGSTOP idle ready devices after this many seconds (0% CPU; thawed on acquire in ~0.1 s); 0 = never.") var freezeIdle: Int = 60
    @Flag(help: "No health checks / automatic recovery.") var noSelfHeal = false
    @Flag(help: "Return immediately instead of waiting for the devices.") var noWait = false
    @Option(help: "Seconds to wait for the devices.") var timeout: Int = 600
    @Flag(help: "JSON output (the pool status).") var json = false

    func run() async throws {
        let fc = try FarmContext.live()
        let pool = try fc.pool(poolOption.pool)
        let g = try fc.golden(golden)
        guard let gid = InstanceID(rawValue: g.name), fc.ctx.store.exists(gid) else { throw CLIError("golden instance \(g.name) is missing") }
        guard !fc.ctx.store.isRunning(gid) else { throw CLIError("golden \(g.name) is running; stop it (or seal it) first") }
        let cost = fc.cost(g)
        let report = CapacityGuard.evaluate(host: .current(), cost: cost, running: 0)
        let n: Int
        switch size {
        case .auto: n = max(1, report.ceiling)
        case .fixed(let k): n = k
        }
        if n > CapacityGuard.maxDevicesByPorts {
            throw CLIError("--size \(n): at most \(CapacityGuard.maxDevicesByPorts) devices per host (console ports 5554–5584, adb's emulator scan range)")
        }
        if n > report.ceiling {
            let msg = "\(n) devices exceed this host's capacity of \(report.ceiling) (limited by \(report.limitedBy): \(ByteCount.format(report.physicalMemoryBytes)) RAM, \(ByteCount.format(report.reserveBytes)) reserved for macOS and apps, ~\(ByteCount.format(cost.perDeviceBytes)) per device; \(report.cpuCores) cores / \(cost.cores) per device)"
            guard overrideCapacity else { throw CLIError(msg + ". Use --override-capacity to try anyway.") }
            Out.err("Warning: \(msg).")
        }
        var policy = FarmPolicy()
        policy.releaseMode = releaseMode.mode
        policy.healLeased = healLeased.policy
        policy.defaultTTL = TimeInterval(ttl)
        policy.freezeIdleAfter = freezeIdle > 0 ? TimeInterval(freezeIdle) : nil
        policy.overrideCapacity = overrideCapacity
        policy.selfHeal = !noSelfHeal
        let store = fc.store(pool)
        if fc.daemonAlive(pool) {
            let s = try store.read()
            guard s.golden == g.name else { throw CLIError("pool '\(pool)' runs golden \(s.golden); `emuu farm down --pool \(pool)` first") }
            try store.update { s in s.size = n; s.policy = policy; s.log("resize", "size \(n)", at: Date()) }
            Out.err("Pool '\(pool)' is up; size set to \(n).")
        } else {
            if store.exists { try await FarmGC.reclaimPool(fc: fc, pool: pool, echo: !json) }
            try store.create(FarmState(pool: pool, golden: g.name, size: n, policy: policy, now: Date()), replace: true)
            let pid = try SelfSpawn.detached(["farm", "daemon", "--pool", pool], log: fc.farm.daemonLog(pool))
            Out.err("Pool '\(pool)': daemon pid \(pid) starting \(n) device(s) from \(g.name) (log: \(fc.farm.daemonLog(pool).path))…")
        }
        if !noWait { try await waitReady(fc: fc, pool: pool, size: n) }
        try FarmStatus.show(fc: fc, pools: [pool], json: json)
    }

    private func waitReady(fc: FarmContext, pool: String, size: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(timeout)
        let t0 = ContinuousClock.now
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(500))
            guard let s = try? fc.store(pool).read() else { continue }
            let ready = s.devices.filter { [.ready, .leased, .frozen].contains($0.state) }.count
            Out.progress("\(ready)/\(size) ready\(s.capacityNote.map { " (\($0))" } ?? "")")
            if ready >= size { Out.endProgress(); Out.err("\(ready) device(s) ready in \(Fmt.seconds(ContinuousClock.now - t0))."); return }
            if !fc.daemonAlive(pool) && ContinuousClock.now - t0 > .seconds(5) {
                Out.endProgress()
                throw CLIError("the pool daemon exited; see \(fc.farm.daemonLog(pool).path)")
            }
            if s.devices.allSatisfy({ $0.state == .failed }) && !s.devices.isEmpty {
                Out.endProgress()
                throw CLIError("every device failed to start: \(s.devices.compactMap(\.note).first ?? "?")")
            }
        }
        Out.endProgress()
        Out.err("Not all devices were ready within \(timeout) s; the daemon keeps trying (`emuu farm status`).")
    }
}

enum ReleaseModeArgument: String, ExpressibleByArgument, CaseIterable {
    case reset, recycle
    var mode: ReleaseMode { self == .reset ? .reset : .recycle }
}

enum HealLeasedArgument: String, ExpressibleByArgument, CaseIterable {
    case restart, replace, report
    var policy: HealLeasedPolicy { HealLeasedPolicy(rawValue: rawValue)! }
}

struct FarmDaemon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "daemon", abstract: "Run a pool's daemon (started by `farm up`).",
                                                    shouldDisplay: false)
    @OptionGroup var poolOption: PoolOption

    func run() async throws {
        let fc = try FarmContext.live()
        let pool = try fc.pool(poolOption.pool)
        guard let lock = FarmFileLock.tryLock(url: fc.farm.daemonLock(pool)) else {
            Out.err("pool '\(pool)' already has a daemon"); return
        }
        defer { lock.release() }
        let store = fc.store(pool)
        let state = try store.read()
        guard let golden = GoldenStore.load(state.golden, farm: fc.farm) else { throw CLIError("golden \(state.golden) is gone") }
        try store.update { $0.daemonPID = getpid(); $0.log("daemon", "pid \(getpid()) started", at: Date()) }
        let driver = try fc.driver()
        let controller = PoolController(store: store, driver: FarmDriverWithReservations(base: driver, fc: fc, pool: pool),
                                        golden: golden, cost: fc.cost(golden))
        let signals = SignalWatcher(signals: [SIGINT, SIGTERM, SIGHUP]) { _ in
            try? store.update { $0.stopRequested = true }
        }
        defer { signals.cancel() }
        Out.line("[\(Fmt.time(Date()))] pool '\(pool)' daemon pid \(getpid()): golden \(golden.name), size \(state.size)")
        while await controller.tick() {
            try? await Task.sleep(for: .milliseconds(500))
        }
        Out.line("[\(Fmt.time(Date()))] pool '\(pool)' down")
    }
}

/// Adds the ports of other pools and of ephemeral `emuu run` clones to the pool's port check.
struct FarmDriverWithReservations: FarmDeviceDriver {
    let base: LiveFarmDriver
    let fc: FarmContext
    let pool: String

    func provision(instance: String, consolePort: Int, golden: GoldenRecord) async throws -> Int32 {
        try await base.provision(instance: instance, consolePort: consolePort, golden: golden)
    }
    func reset(instance: String) async throws { try await base.reset(instance: instance) }
    func destroy(instance: String) async { await base.destroy(instance: instance) }
    func health(_ device: FarmDevice, golden: GoldenRecord, deep: Bool) async -> HealthReport {
        await base.health(device, golden: golden, deep: deep)
    }
    func freeze(instance: String) async throws { try await base.freeze(instance: instance) }
    func thaw(instance: String) async throws { try await base.thaw(instance: instance) }
    func reconnectADB(serial: String) async { await base.reconnectADB(serial: serial) }
    func isPortFree(_ port: Int) -> Bool {
        // Ports planned by other pools or ephemeral runs count as taken (they may not be bound yet).
        var others = Set<Int>()
        for p in fc.farm.poolNames() where p != pool { (try? fc.store(p).read())?.devices.forEach { others.insert($0.consolePort) } }
        for o in fc.ephemeralOwners() { if let port = o.consolePort { others.insert(port) } }
        return !others.contains(port) && !others.contains(port - 1) && base.isPortFree(port)
    }
    func isAlive(_ pid: Int32) -> Bool { base.isAlive(pid) }
    func hostFacts() -> HostFacts { base.hostFacts() }
}

struct FarmDown: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "down", abstract: "Stop a pool: every device is destroyed.")
    @OptionGroup var poolOption: PoolOption
    @Flag(help: "JSON output.") var json = false

    func run() async throws {
        let fc = try FarmContext.live()
        let pool = try fc.pool(poolOption.pool)
        let store = fc.store(pool)
        guard store.exists else { throw CLIError("no pool '\(pool)'") }
        let n = (try? store.read().devices.count) ?? 0
        if fc.daemonAlive(pool) {
            try store.update { $0.stopRequested = true }
            let deadline = ContinuousClock.now + .seconds(180)
            while fc.daemonAlive(pool), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(250)) }
            if fc.daemonAlive(pool) { throw CLIError("the daemon did not stop within 180 s; `emuu farm gc` after killing it") }
        }
        if store.exists { try await FarmGC.reclaimPool(fc: fc, pool: pool, echo: !json) }
        if json { try Out.json(["pool": pool, "devicesDestroyed": "\(n)"]) } else { Out.line("Pool '\(pool)' is down (\(n) device(s) destroyed).") }
    }
}

struct LeaseOutput: Codable, Sendable {
    var leaseID: String
    var pool: String
    var instance: String
    var serial: String
    var consolePort: Int
    var adbPort: Int
    var holderPID: Int32?
    var acquiredAt: Date
    var expiresAt: Date
    var ttlSeconds: Double
}

struct FarmAcquire: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "acquire",
        abstract: "Lease a ready, freshly health-checked device. Prints `<lease> <serial> <instance>` (or JSON).",
        discussion: "Exit status 69 when no device is ready (without --wait) or none became ready within --timeout.")

    @OptionGroup var poolOption: PoolOption
    @Flag(help: "Wait for a device.") var wait = false
    @Option(help: "Seconds to wait with --wait.") var timeout: Int = 300
    @Option(help: "Lease TTL in seconds (default: the pool's, 1800). Extend with `farm heartbeat`.") var ttl: Int?
    @Option(help: "End the lease automatically when this process exits.") var holderPid: Int32?
    @Flag(help: "JSON output.") var json = false

    func run() async throws {
        let fc = try FarmContext.live()
        let pool = try fc.pool(poolOption.pool)
        let lease = try await Self.acquire(fc: fc, pool: pool, wait: wait, timeout: timeout, ttl: ttl.map(TimeInterval.init), holder: holderPid)
        if json { try Out.json(lease) } else { Out.line("\(lease.leaseID) \(lease.serial) \(lease.instance)") }
    }

    static func acquire(fc: FarmContext, pool: String, wait: Bool, timeout: Int, ttl: TimeInterval?, holder: Int32?,
                        lostCheck: (() -> Bool)? = nil) async throws -> LeaseOutput {
        let store = fc.store(pool)
        guard store.exists else { throw CLIError("no pool '\(pool)'; start one with `emuu farm up`", code: FarmExit.unavailable) }
        guard let golden = GoldenStore.load(try store.read().golden, farm: fc.farm) else { throw CLIError("pool golden is missing", code: FarmExit.unavailable) }
        let deadline = ContinuousClock.now + .seconds(wait ? timeout : 0)
        while true {
            guard fc.daemonAlive(pool) else { throw CLIError("pool '\(pool)' has no running daemon (`emuu farm up`)", code: FarmExit.unavailable) }
            do {
                let lease = try await store.updateAsync { s in
                    try await LeaseBook.acquire(&s, holderPID: holder, ttl: ttl, now: Date()) { d in
                        await fc.preLeaseCheck(d, golden: golden)
                    }
                }
                guard let d = try store.read().device(lease.device) else { throw CLIError("leased device vanished") }
                return LeaseOutput(leaseID: lease.id, pool: pool, instance: lease.device, serial: lease.serial, consolePort: d.consolePort,
                                   adbPort: d.consolePort + 1, holderPID: lease.holderPID, acquiredAt: lease.acquiredAt,
                                   expiresAt: lease.expiresAt, ttlSeconds: lease.ttlSeconds)
            } catch LeaseBook.AcquireError.noReadyDevice {
                if ContinuousClock.now >= deadline {
                    let s = try? store.read()
                    let busy = s.map { "\($0.devices.count) device(s): " + Dictionary(grouping: $0.devices, by: \.state.rawValue).map { "\($0.value.count) \($0.key)" }.sorted().joined(separator: ", ") } ?? ""
                    throw CLIError("no ready device in pool '\(pool)'\(wait ? " within \(timeout) s" : "") (\(busy))", code: FarmExit.unavailable)
                }
                try await Task.sleep(for: .milliseconds(300))
            }
        }
    }
}

struct FarmRelease: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "release",
        abstract: "End a lease. The device is reset to the golden state (default) or recycled (fresh clone).")

    @Argument(help: "Lease id from `farm acquire`.") var lease: String
    @OptionGroup var poolOption: PoolOption
    @Flag(help: "Reset to the golden state with a snapshot load (default).") var reset = false
    @Flag(help: "Destroy the device and resume a fresh clone instead.") var recycle = false
    @Flag(help: "Wait until the device is ready again.") var wait = false
    @Flag(help: "JSON output.") var json = false

    func run() async throws {
        let fc = try FarmContext.live()
        let pool = try fc.pool(poolOption.pool)
        let store = fc.store(pool)
        var device: String?
        let ok = try store.update { s -> Bool in
            device = s.lease(lease)?.device
            return LeaseBook.release(&s, leaseID: lease, recycle: recycle, now: Date())
        }
        guard ok, let device else { throw CLIError("no active lease \(lease) in pool '\(pool)'") }
        if wait {
            let deadline = ContinuousClock.now + .seconds(180)
            while ContinuousClock.now < deadline {
                if let d = try? store.read().device(device), d.state == .ready || d.state == .leased || d.state == .frozen { break }
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        let state = (try? store.read().device(device)?.state.rawValue) ?? "gone"
        if json { try Out.json(["lease": lease, "device": device, "mode": recycle ? "recycle" : "reset", "deviceState": state]) }
        else { Out.line("Released \(lease) (\(device): \(state)).") }
    }
}

struct FarmHeartbeat: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "heartbeat", abstract: "Extend a lease by its TTL.")
    @Argument var lease: String
    @OptionGroup var poolOption: PoolOption
    @Option(help: "New TTL in seconds.") var ttl: Int?
    @Flag(help: "JSON output.") var json = false

    func run() async throws {
        let fc = try FarmContext.live()
        let pool = try fc.pool(poolOption.pool)
        guard let l = try fc.store(pool).update({ s in LeaseBook.heartbeat(&s, leaseID: lease, ttl: ttl.map(TimeInterval.init), now: Date()) }) else {
            throw CLIError("no active lease \(lease)")
        }
        if json { try Out.json(l) } else { Out.line("\(l.id): \(l.state.rawValue), expires \(ISO8601DateFormatter().string(from: l.expiresAt))") }
        if l.state == .deviceLost { throw ExitCode(FarmExit.deviceLost) }
    }
}

/// `emuu farm status --json` document (format version 1; README "Automation farm" documents it).
struct FarmStatusDocument: Codable, Sendable {
    struct Pool: Codable, Sendable {
        var daemonAlive: Bool
        var capacity: CapacityReport?
        var state: FarmState
    }
    var formatVersion = 1
    var pools: [Pool]
}

struct FarmStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Devices, leases, counters and recent events of the pools.")
    @OptionGroup var poolOption: PoolOption
    @Flag(help: "JSON output (FarmStatusDocument).") var json = false
    @Option(help: "Recent events to show (text output).") var events: Int = 10

    func run() async throws {
        let fc = try FarmContext.live()
        let pools = poolOption.pool.map { [$0] } ?? fc.farm.poolNames()
        try Self.show(fc: fc, pools: pools, json: json, events: events)
    }

    static func show(fc: FarmContext, pools: [String], json: Bool, events: Int = 10) throws {
        var doc = FarmStatusDocument(pools: [])
        for p in pools {
            guard let s = try? fc.store(p).read() else { continue }
            let running = s.devices.filter { $0.state != .failed }.count
            let cap = GoldenStore.load(s.golden, farm: fc.farm).map {
                CapacityGuard.evaluate(host: .current(), cost: fc.cost($0), running: running)
            }
            doc.pools.append(.init(daemonAlive: fc.daemonAlive(p), capacity: cap, state: s))
        }
        if json { return try Out.json(doc) }
        if doc.pools.isEmpty { return Out.line("No pools. Start one with `emuu farm up`.") }
        for p in doc.pools {
            let s = p.state
            Out.line("pool \(s.pool): golden \(s.golden), size \(s.size), daemon \(p.daemonAlive ? "pid \(s.daemonPID.map(String.init) ?? "?")" : "NOT RUNNING")"
                     + (p.capacity.map { ", host capacity \($0.ceiling) (\($0.limitedBy))" } ?? ""))
            if let note = s.capacityNote { Out.line("  capacity: \(note)") }
            Out.line(Fmt.table(["DEVICE", "SERIAL", "STATE", "LEASE", "RESETS", "HEALTH"], s.devices.map { d in
                [d.instance, d.serial, d.state.rawValue, d.leaseID ?? "-", "\(d.resets)",
                 d.lastHealth.map { "\($0.verdict.rawValue)" + ($0.verdict == .healthy ? "" : ": \($0.reason)") } ?? "-"]
            }).split(separator: "\n").map { "  " + $0 }.joined(separator: "\n"))
            for l in s.leases {
                Out.line("  lease \(l.id): \(l.serial) \(l.state.rawValue)\(l.lostReason.map { " (\($0))" } ?? ""), holder \(l.holderPID.map(String.init) ?? "-"), expires \(Fmt.time(l.expiresAt))")
            }
            let c = s.counters
            Out.line("  counters: acquires \(c.acquires), releases \(c.releases), resets \(c.resets) (failed \(c.resetFailures)), replacements \(c.replacements), expired leases \(c.leasesExpired), hangs detected \(c.hangsDetected), recoveries \(c.recoveries), guest reboots \(c.rebootsDetected)")
            for e in s.history.suffix(events) {
                Out.line("  \(Fmt.time(e.at)) \(e.kind) \(e.device ?? "")\(e.lease.map { " [\($0)]" } ?? ""): \(e.detail)")
            }
        }
    }
}

struct FarmCapacity: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "capacity", abstract: "How many farm devices this host can run (and why).")
    @Option(help: "Golden image whose guest size to use (default: the farm profile).") var golden: String?
    @Flag(help: "JSON output (CapacityReport).") var json = false

    func run() async throws {
        let fc = try FarmContext.live()
        let cost = try golden.map { fc.cost(try fc.golden($0)) } ?? FarmProfile.measuredCost
        let report = CapacityGuard.evaluate(host: .current(), cost: cost, running: 0)
        if json { return try Out.json(report) }
        Out.line(CapacityText.describe(report, cost: cost))
    }
}

enum CapacityText {
    static func describe(_ r: CapacityReport, cost: DeviceCost) -> String {
        """
        \(r.ceiling) device(s) (limited by \(r.limitedBy)): memory allows \(r.byMemory), CPU \(r.byCPU), ports \(r.byPorts).
          memory: (\(ByteCount.format(r.physicalMemoryBytes)) − \(ByteCount.format(r.reserveBytes)) reserved for macOS and apps) ÷ \(ByteCount.format(cost.perDeviceBytes)) per device (\(cost.guestRAMMB) MB guest)
          cpu:    \(r.cpuCores) cores ÷ \(cost.cores) vCPUs per device
          now:    \(r.admitNow ? "a new device can start" : "would wait: \(r.admitReason)") (macOS pressure \(r.pressure), \(r.availableBytes.map(ByteCount.format) ?? "?") available)
        """
    }
}

// MARK: gc

struct FarmGC: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gc",
        abstract: "Reclaim farm leftovers: pools without a daemon, `emuu run` clones whose runner died, orphaned farm engines.")
    @Flag(help: "JSON output.") var json = false

    struct Report: Codable, Sendable {
        var poolsRemoved: [String] = []
        var instancesDestroyed: [String] = []
    }

    func run() async throws {
        let fc = try FarmContext.live()
        var report = Report()
        for p in fc.farm.poolNames() where !fc.daemonAlive(p) {
            report.instancesDestroyed += (try? fc.store(p).read().devices.map(\.instance)) ?? []
            try await Self.reclaimPool(fc: fc, pool: p, echo: !json)
            report.poolsRemoved.append(p)
        }
        let driver = try fc.driver()
        for owner in fc.ephemeralOwners() where !SystemHostProcesses().isAlive(owner.ownerPID) && !owner.keep {
            await driver.destroy(instance: owner.instance)
            try? FileManager.default.removeItem(at: fc.farm.ephemeralOwner(owner.instance))
            report.instancesDestroyed.append(owner.instance)
        }
        // Farm-made instances (never-save clones named farm-*/run-*) that nothing owns any more.
        let owned = Set(fc.farm.poolNames().flatMap { (try? fc.store($0).read().devices.map(\.instance)) ?? [] }
                        + fc.ephemeralOwners().map(\.instance))
        for config in fc.ctx.store.list() where config.discardStateOnExit == true && !owned.contains(config.id.rawValue)
            && (config.id.rawValue.hasPrefix("farm-") || config.id.rawValue.hasPrefix("run-")) {
            await driver.destroy(instance: config.id.rawValue)
            report.instancesDestroyed.append(config.id.rawValue)
        }
        if json { try Out.json(report) } else {
            Out.line("gc: \(report.poolsRemoved.count) stale pool(s), \(report.instancesDestroyed.count) instance(s) destroyed\(report.instancesDestroyed.isEmpty ? "" : ": " + report.instancesDestroyed.joined(separator: ", ")).")
        }
    }

    /// Destroys a pool's devices (engines killed, clones deleted) and removes its state. Daemon must be gone.
    static func reclaimPool(fc: FarmContext, pool: String, echo: Bool) async throws {
        let store = fc.store(pool)
        let devices = (try? store.read().devices) ?? []
        let driver = try fc.driver()
        await withTaskGroup(of: Void.self) { group in
            for d in devices { group.addTask { await driver.destroy(instance: d.instance) } }
        }
        store.remove()
        if echo && !devices.isEmpty { Out.err("Reclaimed pool '\(pool)': \(devices.count) device(s).") }
    }
}
