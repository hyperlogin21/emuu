import Darwin
import Foundation
import ArgumentParser
import EmuuBase
import EmuuEngine
import EmuuFarm

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a command against a fresh device, then give the device back: `emuu run [--golden g] -- ./gradlew connectedCheck`.",
        discussion: """
        The device comes from a running pool (`emuu farm up`) when one serves the golden image (lease, then reset on \
        release), otherwise from a new APFS clone of the golden that is destroyed afterwards (--ephemeral forces this). \
        The command sees ANDROID_SERIAL, EMUU_SERIAL, EMUU_INSTANCE (and EMUU_LEASE for pool devices); its exit status \
        is returned. Exit 69: no device; 75: the device was lost (hung/dead) during the run; 124: --timeout. \
        SIGINT/SIGTERM are forwarded to the command and the device is still cleaned up; if the runner itself is \
        killed, the lease ends with it (holder pid) and `emuu farm gc` reclaims an ephemeral clone.
        """)

    @Option(help: "Golden image (default: the only one).") var golden: String?
    @Option(help: "Pool to lease from (default: a running pool of this golden).") var pool: String?
    @Flag(help: "Always use a new clone, even when a pool is running.") var ephemeral = false
    @Option(help: "Kill the command after this many seconds (exit 124).") var timeout: Int?
    @Option(name: .customLong("apk"), help: "Install this APK before the command (repeatable).") var apks: [String] = []
    @Flag(help: "On failure keep the device (lease or clone) for debugging and print how to reach it.") var keepOnFailure = false
    @Option(help: "On failure write logcat, a screenshot, health and (with --record) the screen recording here.") var artifacts: String?
    @Flag(help: "Record the screen during the run (adb screenrecord, max 180 s); kept only on failure.") var record = false
    @Option(help: "Seconds to wait for a pool device.") var acquireTimeout: Int = 600
    @Argument(parsing: .captureForPassthrough, help: "Command and arguments (after --).") var command: [String] = []

    func validate() throws {
        if command.drop(while: { $0 == "--" }).isEmpty { throw ValidationError("give the command after --, e.g. emuu run -- adb shell getprop") }
    }

    func run() async throws {
        let fc = try FarmContext.live()
        let argv = Array(command.drop(while: { $0 == "--" }))
        let interrupted = Locked<Int32?>(nil)
        let child = Locked<pid_t?>(nil)
        let signals = SignalWatcher(signals: [SIGINT, SIGTERM, SIGHUP]) { sig in
            interrupted.set(sig)
            if let pid = child.current { kill(-pid, sig) }
        }
        defer { signals.cancel() }

        // 1. Device
        let device: RunDevice
        do {
            device = try await RunDevice.acquire(fc: fc, golden: golden, pool: pool, ephemeral: ephemeral, acquireTimeout: acquireTimeout)
        } catch let e as CLIError {
            throw CLIError(e.message, code: e.code == 1 ? FarmExit.unavailable : e.code)
        }
        if let sig = interrupted.current { await device.finish(fc: fc, failed: true, keep: false); throw ExitCode(128 + sig) }
        Out.err("emuu run: \(device.serial) (\(device.instance)\(device.leaseID.map { ", lease \($0)" } ?? ", ephemeral clone")) ready in \(Fmt.seconds(device.readyIn))")

        // 2. APKs, recording
        let adb = fc.ctx.sdk.adb
        for apk in apks {
            let r = try? await SystemProcessRunner().run(ProcessRequest(executable: adb, arguments: ["-s", device.serial, "install", "-r", "-g", apk], timeout: .seconds(300)))
            guard r?.succeeded == true else {
                Out.err("emuu run: install \(apk) failed: \(r.map { $0.stderrString + $0.stdoutString } ?? "timeout")")
                await device.finish(fc: fc, failed: true, keep: keepOnFailure)
                throw ExitCode(1)
            }
        }
        var recorder: (any SpawnedProcess)?
        if record {
            recorder = try? await SystemProcessRunner().spawn(ProcessRequest(executable: adb, arguments: [
                "-s", device.serial, "shell", "screenrecord", "--time-limit", "180", "/sdcard/emuu-run.mp4"]))
        }

        // 3. Command
        var env = ProcessInfo.processInfo.environment
        env["ANDROID_SERIAL"] = device.serial
        env["EMUU_SERIAL"] = device.serial
        env["EMUU_INSTANCE"] = device.instance
        if let l = device.leaseID { env["EMUU_LEASE"] = l }
        let pid = try ChildCommand.spawn(argv, environment: env)
        child.set(pid)
        let outcome = await ChildCommand.wait(pid: pid, timeout: timeout.map { .seconds($0) }) {
            await device.isLost(fc: fc)
        }
        child.set(nil)
        recorder?.send(signal: SIGINT)
        if recorder != nil { try? await Task.sleep(for: .seconds(1)) }

        var code: Int32
        var failed: Bool
        switch outcome {
        case .exited(let c): code = c; failed = c != 0
        case .signaled(let s): code = 128 + s; failed = true
        case .timedOut: code = FarmExit.timeout; failed = true; Out.err("emuu run: --timeout \(timeout ?? 0) s expired; command killed")
        case .deviceLost(let why): code = FarmExit.deviceLost; failed = true; Out.err("emuu run: device lost during the run: \(why)")
        }
        if let sig = interrupted.current { code = 128 + sig; failed = true }

        // 4. Artifacts, cleanup
        if failed, let dir = artifacts {
            var lost: String?
            if case .deviceLost(let why) = outcome { lost = why }
            await RunArtifacts.collect(fc: fc, device: device, to: URL(fileURLWithPath: dir), recorded: record, lostReason: lost)
        }
        await device.finish(fc: fc, failed: failed, keep: keepOnFailure && interrupted.current == nil)
        if code != 0 { throw ExitCode(code) }
    }
}

/// The device a `run` uses: a pool lease or an ephemeral clone.
struct RunDevice: Sendable {
    var instance: String
    var serial: String
    var leaseID: String?
    var pool: String?
    var readyIn: Duration

    static func acquire(fc: FarmContext, golden: String?, pool explicitPool: String?, ephemeral: Bool, acquireTimeout: Int) async throws -> RunDevice {
        let t0 = ContinuousClock.now
        if !ephemeral {
            let wanted = try? fc.golden(golden)
            let candidates = explicitPool.map { [$0] } ?? fc.farm.poolNames()
            if let p = candidates.first(where: { name in
                fc.daemonAlive(name) && (wanted == nil || (try? fc.store(name).read().golden) == wanted?.name)
            }) {
                let lease = try await FarmAcquire.acquire(fc: fc, pool: p, wait: true, timeout: acquireTimeout, ttl: nil, holder: getpid())
                return RunDevice(instance: lease.instance, serial: lease.serial, leaseID: lease.leaseID, pool: p, readyIn: ContinuousClock.now - t0)
            }
            if explicitPool != nil { throw CLIError("pool '\(explicitPool!)' has no running daemon", code: FarmExit.unavailable) }
        }
        let g = try fc.golden(golden)
        let cost = fc.cost(g)
        let running = fc.ctx.store.list().filter { fc.ctx.store.isRunning($0.id) }.count
        let cap = CapacityGuard.evaluate(host: .current(), cost: cost, running: running)
        if !cap.admitNow { Out.err("emuu run: warning: \(cap.admitReason); starting anyway (one ephemeral device)") }
        let instance = "run-\(getpid())-\(UUID().uuidString.prefix(4).lowercased())"
        // Port choice + engine start under one lock so concurrent `emuu run`s never pick the same port.
        let portLock = try FarmFileLock(url: fc.farm.root.appendingPathComponent("ports.lock"))
        defer { portLock.release() }
        guard let port = FarmPorts.allocate(count: 1, reserved: fc.reservedPorts(), isFree: PortAllocator.isPortFree).first else {
            throw CLIError("no free console port in 5554–5584", code: FarmExit.unavailable)
        }
        let owner = EphemeralOwner(instance: instance, ownerPID: getpid(), golden: g.name, createdAt: Date(), consolePort: port)
        try FarmJSON.encoder.encode(owner).write(to: fc.farm.ephemeralOwner(instance), options: .atomic)
        let driver = try fc.driver()
        do {
            let pid = try await driver.provision(instance: instance, consolePort: port, golden: g)
            // Same rule as the pool: still the golden's boot id a moment after the resume (a guest restart right
            // after a snapshot load would otherwise reach the test as a flaky device).
            var probe = FarmDevice(instance: instance, consolePort: port, state: .starting, since: Date())
            probe.enginePID = pid
            try await Task.sleep(for: .seconds(2))
            let h = await driver.health(probe, golden: g, deep: false)
            guard h.verdict == .healthy else { throw EmuuError.engine("clone not healthy after resume: \(h.reason)") }
        } catch {
            await driver.destroy(instance: instance)
            try? FileManager.default.removeItem(at: fc.farm.ephemeralOwner(instance))
            throw CLIError("could not start a clone of \(g.name): \(describe(error))", code: FarmExit.unavailable)
        }
        return RunDevice(instance: instance, serial: "emulator-\(port)", leaseID: nil, pool: nil, readyIn: ContinuousClock.now - t0)
    }

    /// Lease marked lost by the pool, or the ephemeral engine died.
    func isLost(fc: FarmContext) async -> String? {
        if let leaseID, let pool {
            guard let s = try? fc.store(pool).read() else { return "pool state is gone" }
            guard let l = s.lease(leaseID) else { return "lease \(leaseID) ended (expired or released elsewhere)" }
            return l.state == .deviceLost ? (l.lostReason ?? "device lost") : nil
        }
        guard let id = InstanceID(rawValue: instance) else { return nil }
        return AVDLockProbe.isHeld(avdDirectory: fc.ctx.paths.avdDirectory(for: id)) ? nil : "the engine exited"
    }

    func finish(fc: FarmContext, failed: Bool, keep: Bool) async {
        if keep && failed {
            if let leaseID, let pool {
                Out.err("emuu run: kept lease \(leaseID) on \(serial) (pool \(pool)); release it with `emuu farm release \(leaseID)` (it expires with its TTL; the runner's pid no longer holds it).")
                try? fc.store(pool).update { s in
                    if let i = s.leases.firstIndex(where: { $0.id == leaseID }) { s.leases[i].holderPID = nil }
                }
            } else {
                var owner = (try? FarmJSON.decoder.decode(EphemeralOwner.self, from: Data(contentsOf: fc.farm.ephemeralOwner(instance))))
                owner?.keep = true
                if let owner { try? FarmJSON.encoder.encode(owner).write(to: fc.farm.ephemeralOwner(instance), options: .atomic) }
                Out.err("emuu run: kept \(instance) on \(serial) for debugging; delete it with `emuu stop \(instance) --force && emuu delete \(instance) -y`.")
            }
            return
        }
        if let leaseID, let pool {
            _ = try? fc.store(pool).update { s in LeaseBook.release(&s, leaseID: leaseID, recycle: false, now: Date(), reason: "emuu run finished") }
        } else if let driver = try? fc.driver() {
            await driver.destroy(instance: instance)
            try? FileManager.default.removeItem(at: fc.farm.ephemeralOwner(instance))
        }
    }
}

enum RunArtifacts {
    /// logcat, screenshot, (recording), health. A lost device is hung or gone: guest-side collection is skipped
    /// (it would only run into timeouts) and the health report says why.
    static func collect(fc: FarmContext, device: RunDevice, to dir: URL, recorded: Bool, lostReason: String? = nil) async {
        let deviceLost = lostReason != nil
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let adb = fc.ctx.sdk.adb
        let runner = SystemProcessRunner()
        if deviceLost {
            // The pool may already have destroyed the engine (heal-leased replace), so there may be no health.json.
            try? Data("device \(device.serial) (\(device.instance)) was lost during the run: \(lostReason ?? "")\nNo guest-side artifacts were collected (the device was hung or gone).\n".utf8)
                .write(to: dir.appendingPathComponent("device-lost.txt"))
        } else {
            if let r = try? await runner.run(ProcessRequest(executable: adb, arguments: ["-s", device.serial, "logcat", "-d", "-v", "threadtime"], timeout: .seconds(20))) {
                try? r.stdout.write(to: dir.appendingPathComponent("logcat.txt"))
            }
            if let r = try? await runner.run(ProcessRequest(executable: adb, arguments: ["-s", device.serial, "exec-out", "screencap", "-p"], timeout: .seconds(10))), r.succeeded {
                try? r.stdout.write(to: dir.appendingPathComponent("screenshot.png"))
            }
        }
        if recorded && !deviceLost {
            _ = try? await runner.run(ProcessRequest(executable: adb, arguments: ["-s", device.serial, "pull", "/sdcard/emuu-run.mp4", dir.appendingPathComponent("screenrecord.mp4").path], timeout: .seconds(60)))
        }
        if let id = InstanceID(rawValue: device.instance), let config = try? fc.ctx.store.load(id), let engine = try? await fc.ctx.engines.engine(for: id) {
            let report = await HealthService.check(ctx: fc.ctx, config: config, engine: engine, deep: true)
            try? Data(JSONText.encode(report, pretty: true).utf8).write(to: dir.appendingPathComponent("health.json"))
        }
        Out.err("emuu run: artifacts in \(dir.path)")
    }
}

/// The user's command: its own process group (so a timeout or signal reaches its children too).
enum ChildCommand {
    enum Outcome: Equatable { case exited(Int32), signaled(Int32), timedOut, deviceLost(String) }

    static func spawn(_ argv: [String], environment: [String: String]) throws -> pid_t {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        // emuu itself ignores these while it forwards them (SignalWatcher); the command must start with the defaults,
        // or a shell could not even trap them. (A sigfillset() here — SIGKILL/SIGSTOP included — was not applied.)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGPIPE, SIGUSR1, SIGUSR2, SIGALRM] { sigaddset(&defaults, sig) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        // The spawning thread (a Swift concurrency worker) may have signals blocked; the mask is inherited and a
        // blocked SIGTERM would never reach the command (measured: forwarded SIGTERM stayed pending).
        var noMask = sigset_t()
        sigemptyset(&noMask)
        posix_spawnattr_setsigmask(&attr, &noMask)
        let cargs = argv.map { strdup($0) } + [nil]
        let cenv = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { cargs.forEach { free($0) }; cenv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawnp(&pid, argv[0], nil, &attr, cargs, cenv)
        guard rc == 0 else { throw CLIError("cannot run \(argv[0]): \(String(cString: strerror(rc)))", code: 127) }
        return pid
    }

    /// Polls the child (WNOHANG) every 200 ms; checks `lost` every 2 s.
    static func wait(pid: pid_t, timeout: Duration?, lost: () async -> String?) async -> Outcome {
        let start = ContinuousClock.now
        var lastLostCheck = start
        while true {
            var status: Int32 = 0
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid {
                let sig = status & 0x7f
                return sig == 0 ? .exited((status >> 8) & 0xff) : .signaled(sig)
            }
            if r < 0 && errno != EINTR { return .exited(127) }
            if let timeout, ContinuousClock.now - start > timeout {
                terminate(pid)
                return .timedOut
            }
            if ContinuousClock.now - lastLostCheck > .seconds(2) {
                lastLostCheck = ContinuousClock.now
                if let why = await lost() {
                    terminate(pid)
                    return .deviceLost(why)
                }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    static func terminate(_ pid: pid_t) {
        kill(-pid, SIGTERM)
        for _ in 0..<25 {
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid { return }
            usleep(200_000)
        }
        kill(-pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }
}
