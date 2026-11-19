import Darwin
import Foundation
import EmuuBase

/// One Emuu instance's engine: launch, boot detection, freeze/thaw, snapshots, hibernate/resume, stop,
/// crash detection. Implements `EngineControl`.
///
/// It can drive an engine it spawned or *adopt* one started by another Emuu process (found through the
/// pid file or by scanning for `qemu-system-* -avd <id>` with Emuu's `ANDROID_AVD_HOME`). Call
/// `refresh()` (done by `EngineEnvironment.engine(for:)`) to pick up the real state.
///
/// Behaviour measured on engine 36.4.9 (see docs/engine-findings.md):
/// * `emulator -no-window` execs into `qemu-system-aarch64-headless`, so the spawned pid is the QEMU pid.
/// * Console `kill` and SIGTERM both save the quick-boot snapshot `default_boot` before exiting.
/// * Quick-boot resume from `default_boot` reaches `sys.boot_completed` in ~1.7 s vs ~10–23 s cold.
public actor EngineInstance: EngineControl {
    public nonisolated let instanceID: InstanceID
    public let config: InstanceConfig
    public let sdk: AndroidSDK
    public let paths: EmuuPaths
    public let timings: EngineTimings
    /// T4 mechanism. Default `.signal` (see `FreezeMechanism`).
    public var freezeMechanism: FreezeMechanism

    private let deps: EngineDependencies
    private let log: EmuuLogger

    private var current: InstanceState = .stopped
    private var process: (any SpawnedProcess)?
    private var pid: Int32?
    private var ports: InstancePorts?
    private var console: ConsoleClient?
    private var frozenBy: FreezeMechanism?
    private var watchTask: Task<Void, Never>?
    /// The pid Emuu itself is shutting down, so its exit is not reported as a crash. Cleared with the runtime.
    private var shuttingDownPID: Int32?
    /// When this process spawned or adopted the current engine. A quick-boot snapshot written after this
    /// instant was saved by the engine's own clean exit (console `kill`/SIGTERM from any Emuu process).
    private var engineSince: Date?
    /// Engine log size at that moment: save failures are looked for only in what the engine wrote since.
    private var engineLogOffset: UInt64 = 0
    /// The launch in flight, shared by concurrent `start()`/`resume()` callers.
    private var startTask: (id: UUID, task: Task<Void, Error>)?
    /// Periodic in-place cap of the engine log while the engine lives (it is only rotated at launch otherwise).
    private var logCapTask: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<InstanceState>.Continuation] = [:]

    public init(config: InstanceConfig, sdk: AndroidSDK, paths: EmuuPaths,
                dependencies: EngineDependencies = .live(), timings: EngineTimings = .default,
                freezeMechanism: FreezeMechanism = .signal) {
        self.instanceID = config.id
        self.config = config
        self.sdk = sdk
        self.paths = paths
        self.deps = dependencies
        self.timings = timings
        self.freezeMechanism = freezeMechanism
        self.log = EmuuLogger(category: "engine.\(config.id.rawValue)")
    }

    deinit {
        watchTask?.cancel()
        logCapTask?.cancel()
        for c in subscribers.values { c.finish() }
    }

    public func setFreezeMechanism(_ mechanism: FreezeMechanism) { freezeMechanism = mechanism }

    // MARK: EngineControl – queries

    public func state() async -> InstanceState { current }
    public func enginePID() async -> Int32? { current.isRunningEngine ? pid : nil }
    public func serial() async -> DeviceSerial? { current.isRunningEngine ? ports?.serial : nil }
    public func consolePorts() -> InstancePorts? { ports }

    /// The current state first, then every change. Ends when the instance object goes away.
    public func stateUpdates() -> AsyncStream<InstanceState> {
        let (stream, cont) = AsyncStream<InstanceState>.makeStream(bufferingPolicy: .bufferingNewest(32))
        let id = UUID()
        subscribers[id] = cont
        cont.yield(current)
        cont.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }

    private func setState(_ new: InstanceState) {
        guard new != current else { return }
        log.info("state \(current) -> \(new)")
        current = new
        for c in subscribers.values { c.yield(new) }
    }

    /// Re-derives the state from the OS: a live engine for this AVD (adopted if not ours), whether it is
    /// SIGSTOPped or console-stopped, whether Android finished booting; otherwise hibernated/stopped.
    @discardableResult
    public func refresh() async -> InstanceState {
        if let livePID = findEnginePID() {
            if pid != livePID { adopt(pid: livePID) }
            if deps.host.isStopped(livePID) {
                frozenBy = .signal
                setState(.frozen)
            } else if case .stopped? = try? await consoleClient().vmStatus() {
                frozenBy = .console
                setState(.frozen)
            } else if current == .stopping || current == .hibernating {
                // Our own shutdown is in progress; keep that state.
            } else {
                frozenBy = nil
                setState(await isBootCompleted() ? .running : .booting)
            }
        } else if pid == nil || !deps.host.isAlive(pid!) {
            if case .crashed = current { return current }
            clearRuntime()
            setState(HibernationMarker.isSet(for: instanceID, paths: paths) ? .hibernated : .stopped)
        }
        return current
    }

    // MARK: Start / boot

    /// Launches the engine and waits for `sys.boot_completed`. No-op when already booted; thaws when frozen.
    /// Uses the quick-boot snapshot when present unless `options.coldBoot`.
    ///
    /// Concurrent calls (governor auto-resume racing a `wake` request, two control clients) are coalesced:
    /// while a launch is in flight every caller awaits that same launch instead of spawning a second engine
    /// (the AVD lock and ports are not taken until QEMU is up, so they cannot catch the race).
    public func start(_ options: EngineLaunchOptions = EngineLaunchOptions()) async throws {
        if let inFlight = startTask { return try await inFlight.task.value }
        let token = UUID()
        let task = Task { try await self.performStart(options) }
        startTask = (token, task)
        defer { if startTask?.id == token { startTask = nil } }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performStart(_ options: EngineLaunchOptions) async throws {
        switch current {
        case .running: return
        case .booting: return try await waitForBoot(timeout: options.bootTimeout)
        case .frozen: return try await thaw()
        case .stopping, .hibernating: throw EmuuError.invalidStateTransition(from: current, action: "start")
        case .stopped, .hibernated, .crashed: break
        }
        if case .running = await refresh() { return }
        if current.isRunningEngine { return try await performStart(options) }

        let avdDir = paths.avdDirectory(for: instanceID)
        guard FileManager.default.fileExists(atPath: avdDir.appendingPathComponent("config.ini").path),
              FileManager.default.fileExists(atPath: paths.avdIniFile(for: instanceID).path) else {
            throw EmuuError.instanceNotFound(instanceID)
        }
        guard !deps.isAVDLocked(avdDir) else {
            throw EmuuError.engine("\(instanceID) is locked by an engine Emuu cannot see (another AVD home or user?)")
        }
        let removed = AVDLockProbe.staleLockArtifacts(in: avdDir).filter { (try? FileManager.default.removeItem(at: $0)) != nil }
        if !removed.isEmpty { log.notice("removed stale lock files: \(removed.map(\.lastPathComponent).joined(separator: ", "))") }

        let chosen = try choosePorts()
        try paths.ensureDirectories()
        let logURL = paths.engineLogFile(for: instanceID)
        Self.rotateLogIfLarge(logURL)
        let grpc = options.grpc ? PortAllocator.grpcPort(for: chosen, isFree: deps.isPortFree) : nil
        if options.grpc, grpc == nil { log.warning("no free gRPC port in 8554…8999: the display needs one (engine starts without it)") }
        // The stored setting may have changed since this controller was created (app picker, `emuu video-decoder`).
        var latest = config
        if let stored = try? InstanceStore.decode(paths.instanceConfigFile(for: instanceID)) { latest.videoDecoder = stored.videoDecoder }
        let plan = Self.videoDecoderPlan(desired: latest.effectiveVideoDecoder(),
                                         snapshotCodecs: Self.readGuestCodecsMarker(avdDir),
                                         hasQuickBootSnapshot: Self.hasQuickBootSnapshot(snapshotsDirectory),
                                         coldBoot: options.coldBoot, isClone: config.goldenSource != nil)
        if let note = plan.note { log.notice("\(note)") }
        var launchOptions = options
        launchOptions.coldBoot = plan.coldBoot
        let args = EngineCommandLine.arguments(for: config, ports: chosen, grpcPort: grpc, options: launchOptions,
                                               videoDecoder: plan.mode)
        Self.writeGuestCodecsMarker(avdDir, plan.mode.usesHostCodecs ? .host : .guest)
        Self.appendLogHeader(logURL, "emuu launch \(ISO8601DateFormatter().string(from: deps.clock.now())): emulator \(args.joined(separator: " ")) [video decoder: \(plan.mode.rawValue)]")
        let request = ProcessRequest(executable: sdk.emulator, arguments: args,
                                     environment: EngineCommandLine.environment(paths: paths, sdk: sdk, videoDecoder: plan.mode),
                                     workingDirectory: paths.root, stdout: .file(logURL), stderr: .file(logURL))
        let launchedAt = deps.clock.now()
        let launchLogOffset = Self.fileSize(logURL)
        let spawned: any SpawnedProcess
        do { spawned = try await deps.runner.spawn(request) } catch {
            setState(.crashed(reason: "launch failed: \(error.localizedDescription)"))
            throw error
        }
        process = spawned
        pid = spawned.pid
        engineSince = launchedAt
        engineLogOffset = launchLogOffset
        ports = chosen
        console = nil
        frozenBy = nil
        writePIDFile(spawned.pid)
        log.notice("launched engine pid \(spawned.pid) on \(chosen.serial)")
        setState(.booting)
        watch(spawned)
        do {
            try await waitForBoot(timeout: options.bootTimeout)
        } catch {
            if current.isRunningEngine {
                log.error("boot failed (\(error.localizedDescription)); force-stopping")
                try? await stop(.force)
            }
            throw error
        }
        HibernationMarker.clear(for: instanceID, paths: paths)
        CrashMarker.clear(for: instanceID, paths: paths)
    }

    /// Polls `adb shell getprop sys.boot_completed` until it reads 1.
    public func waitForBoot(timeout: Duration) async throws {
        let deadline = deps.clock.monotonicNow() + timeout
        while true {
            try Task.checkCancellation()
            guard current == .booting || current == .running else {
                throw EmuuError.engine("engine left booting state: \(current)")
            }
            if current == .running { return }
            if await isBootCompleted() {
                if current == .booting { setState(.running) }
                return
            }
            if deps.clock.monotonicNow() >= deadline {
                throw EmuuError.engine("\(instanceID) did not finish booting within \(timeout)")
            }
            try await deps.clock.sleep(for: timings.bootPollInterval)
        }
    }

    private func isBootCompleted() async -> Bool {
        guard let serial = ports?.serial else { return false }
        let req = ProcessRequest(executable: sdk.adb, arguments: ["-s", serial.rawValue, "shell", "getprop", "sys.boot_completed"],
                                 timeout: timings.adbProbeTimeout)
        guard let result = try? await deps.runner.run(req) else { return false }
        return result.succeeded && result.trimmedStdout == "1"
    }

    // MARK: Freeze (T4)

    public func freeze() async throws {
        switch current {
        case .frozen: return
        case .running: break
        default: throw EmuuError.invalidStateTransition(from: current, action: "freeze")
        }
        guard let pid else { throw EmuuError.invalidStateTransition(from: current, action: "freeze") }
        switch freezeMechanism {
        case .signal:
            sendSignal(SIGSTOP, to: pid)
            guard await waitUntil({ self.deps.host.isStopped(pid) }, timeout: timings.signalSettle) else {
                throw EmuuError.engine("SIGSTOP did not stop pid \(pid)")
            }
        case .console:
            let c = try consoleClient()
            try await c.avdStop()
            guard case .stopped = try await c.vmStatus() else { throw EmuuError.console("avd stop did not stop the VM") }
        }
        frozenBy = freezeMechanism
        FreezeMarker.set(for: instanceID, paths: paths)
        setState(.frozen)
    }

    public func thaw() async throws {
        switch current {
        case .running: return
        case .frozen: break
        default: throw EmuuError.invalidStateTransition(from: current, action: "thaw")
        }
        guard let pid else { throw EmuuError.invalidStateTransition(from: current, action: "thaw") }
        // Undo whichever mechanism is in effect (it may have been applied by another Emuu process).
        if frozenBy == .signal || deps.host.isStopped(pid) {
            sendSignal(SIGCONT, to: pid)
            guard await waitUntil({ !self.deps.host.isStopped(pid) }, timeout: timings.signalSettle) else {
                throw EmuuError.engine("SIGCONT did not resume pid \(pid)")
            }
        }
        if frozenBy == .console || frozenBy == nil {
            let c = try consoleClient()
            if case .stopped = try await c.vmStatus() { try await c.avdStart() }
        }
        frozenBy = nil
        FreezeMarker.clear(for: instanceID, paths: paths)
        setState(.running)
    }

    // MARK: Snapshots

    /// Saves a named snapshot. Caution (measured on 36.4.9, 3 of 3 cases): after a session that saved/deleted a
    /// named snapshot is hibernated, the *next* session's quick-boot save fails ("unable to save default_boot
    /// and will now erase it"), so the hibernate after that falls back to a cold boot (data kept). The memory
    /// governor should hibernate only through `hibernate()`, never with named snapshots.
    public func saveSnapshot(named name: String) async throws {
        try requireRunning("save snapshot")
        try await consoleClient().snapshotSave(name)
    }

    public func loadSnapshot(named name: String) async throws {
        try requireRunning("load snapshot")
        try await consoleClient().snapshotLoad(name)
    }

    /// Farm reset: loads `default_boot` into the running engine (console `avd snapshot load`), which rolls RAM
    /// *and* the qcow2 disks back to the snapshot, then waits until adb answers again (the transport drops for
    /// a moment during the load). Measured on 36.4.9: an installed app, files in /sdcard and /data/local/tmp and a
    /// changed setting were all gone afterwards.
    public func resetToQuickBootSnapshot(timeout: Duration = .seconds(60)) async throws {
        try requireRunning("reset to snapshot")
        try await consoleClient().snapshotLoad("default_boot", timeout: timeout)
        setState(.booting)
        try await waitForBoot(timeout: timeout)
    }

    /// Guest-only reboot (`adb reboot`): the engine keeps running, Android restarts from its disks.
    public func rebootGuest(timeout: Duration = .seconds(180)) async throws {
        try requireRunning("reboot guest")
        guard let serial = ports?.serial else { throw EmuuError.engine("no adb serial") }
        let req = ProcessRequest(executable: sdk.adb, arguments: ["-s", serial.rawValue, "reboot"], timeout: .seconds(20))
        _ = try await deps.runner.run(req)
        setState(.booting)
        // boot_completed still reads 1 for a moment while the old userspace shuts down.
        try await deps.clock.sleep(for: .seconds(3))
        try await waitForBoot(timeout: timeout)
    }

    public func deleteSnapshot(named name: String) async throws {
        if current == .running {
            try await consoleClient().snapshotDelete(name)
        } else if !current.isRunningEngine {
            try ConsoleClient.checkSnapshotName(name)
            let dir = snapshotsDirectory.appendingPathComponent(name, isDirectory: true)
            guard FileManager.default.fileExists(atPath: dir.path) else { return }
            do { try FileManager.default.removeItem(at: dir) } catch {
                throw EmuuError.io(path: dir.path, message: error.localizedDescription)
            }
        } else {
            throw EmuuError.invalidStateTransition(from: current, action: "delete snapshot")
        }
    }

    /// From the console while running; from `<avd>/snapshots/*/snapshot.pb` otherwise (also while
    /// SIGSTOPped, when the console cannot answer).
    public func listSnapshots() async throws -> [String] {
        if current == .running, let names = try? await consoleClient().snapshotList() { return names }
        return Self.snapshotsOnDisk(snapshotsDirectory)
    }

    // MARK: video decoder vs. quick-boot snapshot

    /// Which codec set the guest registered at boot: the host-backed goldfish codecs or Android's software codecs.
    public enum GuestCodecs: String, Sendable { case host, guest }

    /// File in the AVD directory recording the guest codec set of the last launch (and so of any snapshot it saved).
    /// Clones copy it with the golden's snapshot.
    static let guestCodecsMarkerName = "emuu-guest-codecs"

    static func readGuestCodecsMarker(_ avdDir: URL) -> GuestCodecs? {
        (try? String(contentsOf: avdDir.appendingPathComponent(guestCodecsMarkerName), encoding: .utf8))
            .flatMap { GuestCodecs(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    static func writeGuestCodecsMarker(_ avdDir: URL, _ codecs: GuestCodecs) {
        try? Data("\(codecs.rawValue)\n".utf8).write(to: avdDir.appendingPathComponent(guestCodecsMarkerName), options: .atomic)
    }

    static func hasQuickBootSnapshot(_ snapshots: URL) -> Bool {
        FileManager.default.fileExists(atPath: snapshots.appendingPathComponent("default_boot/snapshot.pb").path)
    }

    /// Decides the decoder mode and whether to cold-boot. The guest picks its codecs from the kernel command line at
    /// boot, so a quick-boot snapshot keeps the codec set it was saved with whatever flags the next launch passes.
    /// A snapshot with no marker predates the setting and was taken with the engine default (host codecs).
    /// * snapshot matches (or none, or cold boot requested) → `desired` as asked;
    /// * mismatch on an ordinary instance → cold boot once with `desired` (the next snapshot then matches);
    /// * mismatch on a farm clone → keep the golden snapshot's codec set (a clone never saves, so a cold boot would
    ///   repeat on every start); re-seal the golden to change it.
    static func videoDecoderPlan(desired: VideoDecoderMode, snapshotCodecs: GuestCodecs?, hasQuickBootSnapshot: Bool,
                                 coldBoot: Bool, isClone: Bool) -> (mode: VideoDecoderMode, coldBoot: Bool, note: String?) {
        let desired = desired.resolved
        guard hasQuickBootSnapshot, !coldBoot else { return (desired, coldBoot, nil) }
        let recorded = snapshotCodecs ?? .host
        guard (recorded == .host) != desired.usesHostCodecs else { return (desired, false, nil) }
        if isClone {
            let kept: VideoDecoderMode = recorded == .host ? .hardware : .software
            return (kept, false, "video decoder \(desired.rawValue) requested, but the golden snapshot was saved with "
                    + "\(recorded == .host ? "host" : "guest software") decoders; keeping \(kept.rawValue) (re-seal the golden to change it)")
        }
        return (desired, true, "video decoder \(desired.rawValue): the quick-boot snapshot was saved with "
                + "\(recorded == .host ? "host" : "guest software") decoders; cold boot")
    }

    var snapshotsDirectory: URL { paths.avdDirectory(for: instanceID).appendingPathComponent("snapshots", isDirectory: true) }

    static func snapshotsOnDisk(_ dir: URL) -> [String] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return items.filter { fm.fileExists(atPath: dir.appendingPathComponent($0).appendingPathComponent("snapshot.pb").path) }.sorted()
    }

    // MARK: Reclaim (T3)

    /// Engine 36.4.9 + android-36.1 cannot return guest RAM to the host. Measured: QEMU 2.12 does accept
    /// `-qemu -device virtio-balloon-pci` and a `-monitor`, but the guest kernel has no virtio_balloon
    /// driver (CONFIG_VIRTIO_BALLOON=m, module not shipped), the device stays unbound and `balloon <MB>`
    /// leaves `actual` unchanged; the console's own `qemu monitor` is disabled. Free-page reporting needs
    /// the same driver. The working way to give memory back is T5 (hibernate).
    public func reclaimGuestMemory(targetBytes: UInt64?) async throws -> ReclaimOutcome {
        guard current == .running || current == .frozen else {
            throw EmuuError.invalidStateTransition(from: current, action: "reclaim guest memory")
        }
        return .unsupported(reason: Self.reclaimUnsupportedReason)
    }

    public static let reclaimUnsupportedReason =
        "no guest balloon: the android-36.1 kernel ships no virtio_balloon driver (device stays unbound) and the "
        + "console's QEMU monitor is disabled in engine 36.4.9; use hibernate (T5) to return memory"

    // MARK: Hibernate (T5)

    /// Saves the quick-boot snapshot and quits (console `kill`, which saves `default_boot`), then marks the
    /// instance hibernated. Thaws first if frozen.
    public func hibernate() async throws {
        switch current {
        case .hibernated: return
        case .running, .frozen: break
        default: throw EmuuError.invalidStateTransition(from: current, action: "hibernate")
        }
        if current == .frozen { try await thaw() }
        let started = deps.clock.now()
        let logOffset = Self.fileSize(paths.engineLogFile(for: instanceID))
        setState(.hibernating)
        do {
            try await shutDown(save: true)
        } catch {
            shuttingDownPID = nil
            await refresh()
            if !current.isRunningEngine {
                // The engine is gone anyway (e.g. it had to be SIGKILLed; the snapshot was discarded): the
                // memory is released, so park the instance as hibernated (resume cold-boots) instead of
                // leaving it "stopped", which supervisors read as "stopped by someone else".
                parkAfterFailedSave()
            }
            throw error
        }
        clearRuntime()
        if quickBootSnapshotLooksComplete(savedAfter: started, logOffset: logOffset) {
            try HibernationMarker.set(for: instanceID, paths: paths, at: deps.clock.now())
            setState(.hibernated)
        } else {
            // The engine is gone and its disks are current; make sure a stub snapshot is not loaded later.
            invalidateQuickBoot()
            parkAfterFailedSave()
            throw EmuuError.engine("hibernate: engine exited without a complete quick-boot snapshot; the instance is parked and the next resume cold-boots (data kept)")
        }
    }

    /// Hibernate released the engine but without a usable quick-boot snapshot. The instance is still parked
    /// by request: mark it hibernated so auto-resume and supervisors treat it like any hibernated instance;
    /// `start()` finds no `default_boot` and cold-boots from the current disks.
    private func parkAfterFailedSave() {
        if (try? HibernationMarker.set(for: instanceID, paths: paths, at: deps.clock.now())) != nil {
            setState(.hibernated)
        } else {
            setState(.stopped)
        }
    }

    /// Smallest plausible `ram.bin` for a real save. A failed save leaves a stub: engine 36.4.9 once logged
    /// "The emulator was unable to save default_boot and will now erase it" and then "Saving snapshot
    /// 'default_boot' using 8 ms"; the next launch could not load it and cold-booted.
    public static let minimumRAMSnapshotBytes: UInt64 = 16 * 1024 * 1024

    /// Fresh `snapshot.pb`, a `ram.bin` of plausible size, and no save failure in the engine log written since
    /// `logOffset`.
    func quickBootSnapshotLooksComplete(savedAfter started: Date, logOffset: UInt64) -> Bool {
        let dir = snapshotsDirectory.appendingPathComponent("default_boot", isDirectory: true)
        let fm = FileManager.default
        guard let pbDate = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent("snapshot.pb").path))?[.modificationDate] as? Date,
              pbDate >= started.addingTimeInterval(-2) else {
            log.error("hibernate: no fresh default_boot/snapshot.pb")
            return false
        }
        let ramBytes = Self.fileSize(dir.appendingPathComponent("ram.bin"))
        guard ramBytes >= Self.minimumRAMSnapshotBytes else {
            log.error("hibernate: default_boot/ram.bin is \(ramBytes) bytes; save incomplete")
            return false
        }
        let newLog = Self.read(paths.engineLogFile(for: instanceID), from: logOffset)
        if newLog.contains("unable to save default_boot") {
            log.error("hibernate: engine reported it was unable to save default_boot")
            return false
        }
        return true
    }

    static func fileSize(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    static func read(_ url: URL, from offset: UInt64) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    /// Starts from the hibernation snapshot (quick boot), or a normal start. Thaws when frozen.
    public func resume() async throws {
        switch current {
        case .running: return
        case .frozen: return try await thaw()
        case .stopped, .hibernated, .crashed: try await start()
        case .booting: try await waitForBoot(timeout: EngineLaunchOptions().bootTimeout)
        case .stopping, .hibernating: throw EmuuError.invalidStateTransition(from: current, action: "resume")
        }
    }

    /// Name of the snapshot the running session was restored from (`default_boot` after a quick boot),
    /// nil after a cold boot.
    public func loadedSnapshot() async throws -> String? {
        try requireRunning("query loaded snapshot")
        return try await consoleClient().loadedSnapshot()
    }

    // MARK: Stop

    /// `.graceful(saveQuickBoot: true)`: console `kill` (engine saves `default_boot`), SIGTERM after
    /// `gracefulExitTimeout`, SIGKILL after `termGrace`.
    /// `.graceful(saveQuickBoot: false)`: same exit (the engine always saves on a clean exit), then the
    /// quick-boot snapshot is deleted so the next start cold-boots from the current disk.
    /// `.force`: SIGKILL; the quick-boot snapshot is deleted because it no longer matches the disks
    /// (loading it would roll userdata back).
    public func stop(_ mode: EngineStopMode) async throws {
        if !current.isRunningEngine, findEnginePID() == nil {
            if case .crashed = current { setState(.stopped) }
            return
        }
        if pid == nil { await refresh() }
        switch mode {
        case .force:
            setState(.stopping)
            shuttingDownPID = pid
            if let pid { sendSignal(SIGKILL, to: pid) }
            guard await waitForExit(timeout: timings.killGrace) else {
                shuttingDownPID = nil
                throw EmuuError.engine("engine pid \(pid ?? -1) survived SIGKILL")
            }
            invalidateQuickBoot()
            if let pid { Self.removeDiscoveryFile(pid: pid) }
            finishStopped()
        case .graceful(let save):
            if current == .frozen { try await thaw() }
            setState(.stopping)
            do { try await shutDown(save: save) } catch {
                shuttingDownPID = nil
                await refresh()
                throw error
            }
            if !save { invalidateQuickBoot() }
            finishStopped()
        }
    }

    // MARK: Internals

    private func shutDown(save: Bool) async throws {
        guard let pid else { return }
        shuttingDownPID = pid
        do {
            try await consoleClient().kill()
        } catch {
            log.warning("console kill failed (\(error.localizedDescription)); sending SIGTERM")
            sendSignal(SIGTERM, to: pid)
        }
        if await waitForExit(timeout: timings.gracefulExitTimeout) { return }
        log.warning("engine still running \(timings.gracefulExitTimeout) after kill; SIGTERM")
        sendSignal(SIGTERM, to: pid)
        if await waitForExit(timeout: timings.termGrace) { return }
        log.error("engine ignored SIGTERM; SIGKILL")
        sendSignal(SIGKILL, to: pid)
        if await waitForExit(timeout: timings.killGrace) {
            invalidateQuickBoot()
            throw EmuuError.engine("engine had to be SIGKILLed; quick-boot snapshot discarded")
        }
        throw EmuuError.engine("engine pid \(pid) did not exit")
    }

    private func finishStopped() {
        CrashMarker.clear(for: instanceID, paths: paths)
        clearRuntime()
        HibernationMarker.clear(for: instanceID, paths: paths)
        setState(.stopped)
    }

    /// Forgets the engine. `removeArtifacts` also deletes the pid file and the AVD's *.lock files; it is false
    /// when another Emuu process stopped the engine (that process cleans up, and may already be launching a
    /// new engine whose fresh lock files must not be removed).
    private func clearRuntime(removeArtifacts: Bool = true) {
        watchTask?.cancel()
        watchTask = nil
        logCapTask?.cancel()
        logCapTask = nil
        Task { [console] in await console?.disconnect() }
        console = nil
        process = nil
        pid = nil
        engineSince = nil
        shuttingDownPID = nil
        frozenBy = nil
        if config.ports == nil { ports = nil }
        guard removeArtifacts else { return }
        FreezeMarker.clear(for: instanceID, paths: paths)
        try? FileManager.default.removeItem(at: paths.pidFile(for: instanceID))
        // The engine leaves *.lock files behind even on a clean exit; remove them once it is gone.
        AVDLockProbe.staleLockArtifacts(in: paths.avdDirectory(for: instanceID)).forEach {
            try? FileManager.default.removeItem(at: $0)
        }
    }

    /// Deletes `default_boot` so the next start cold-boots.
    private func invalidateQuickBoot() {
        let dir = snapshotsDirectory.appendingPathComponent("default_boot", isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.removeItem(at: dir)
            log.notice("discarded quick-boot snapshot")
        }
    }

    private func requireRunning(_ action: String) throws {
        guard current == .running else { throw EmuuError.invalidStateTransition(from: current, action: action) }
    }

    private func consoleClient() throws -> ConsoleClient {
        if let console { return console }
        guard let ports else { throw EmuuError.engine("console port unknown") }
        let c = ConsoleClient(port: ports.console, connector: deps.consoleConnector, token: deps.consoleToken)
        console = c
        return c
    }

    private func sendSignal(_ sig: Int32, to pid: Int32) {
        if let process, process.pid == pid {
            process.send(signal: sig) // no-op after exit, so a recycled pid is never hit
        } else {
            deps.host.signal(pid, sig)
        }
    }

    private func isEngineAlive() -> Bool {
        if let process { return process.isRunning }
        guard let pid else { return false }
        return deps.host.isAlive(pid)
    }

    private func waitForExit(timeout: Duration) async -> Bool {
        await waitUntil({ !self.isEngineAlive() }, timeout: timeout)
    }

    private func waitUntil(_ condition: () -> Bool, timeout: Duration) async -> Bool {
        let deadline = deps.clock.monotonicNow() + timeout
        while true {
            if condition() { return true }
            if deps.clock.monotonicNow() >= deadline { return false }
            try? await deps.clock.sleep(for: timings.exitPollInterval)
        }
    }

    private func choosePorts() throws -> InstancePorts {
        if let fixed = config.ports {
            guard deps.isPortFree(fixed.console), deps.isPortFree(fixed.adb) else {
                throw EmuuError.engine("ports \(fixed.portsArgument) are in use")
            }
            return fixed
        }
        guard let pair = PortAllocator.firstFreePair(isFree: deps.isPortFree) else {
            throw EmuuError.engine("no free console/adb port pair in \(InstancePorts.consoleRange)")
        }
        return pair
    }

    /// pid file first (fast), then a scan of host processes.
    private func findEnginePID() -> Int32? {
        if let pid, isEngineAlive() { return pid }
        let avdHome = paths.avdHome
        if let text = try? String(contentsOf: paths.pidFile(for: instanceID), encoding: .utf8),
           let filePID = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           deps.host.isAlive(filePID),
           deps.host.enginePIDs(for: instanceID, avdHome: avdHome).contains(filePID) || isOurArgv(filePID) {
            return filePID
        }
        let found = deps.host.enginePIDs(for: instanceID, avdHome: avdHome)
        // Prefer the QEMU process if both a launcher and QEMU show up.
        return found.first { deps.host.arguments(of: $0)?.first?.contains("qemu-system") == true } ?? found.first
    }

    private func isOurArgv(_ pid: Int32) -> Bool {
        guard let argv = deps.host.arguments(of: pid), let i = argv.firstIndex(of: "-avd") else { return false }
        return i + 1 < argv.count && argv[i + 1] == instanceID.rawValue
    }

    private func adopt(pid newPID: Int32) {
        watchTask?.cancel()
        process = nil
        pid = newPID
        console = nil
        let argv = deps.host.arguments(of: newPID) ?? []
        if let port = EngineCommandLine.consolePort(fromArguments: argv), let p = try? InstancePorts(console: port) {
            ports = p
        } else {
            ports = config.ports
        }
        engineSince = deps.clock.now()
        engineLogOffset = Self.fileSize(paths.engineLogFile(for: instanceID))
        writePIDFile(newPID)
        log.notice("adopted running engine pid \(newPID) on \(ports?.serial.rawValue ?? "unknown port")")
        let interval = timings.adoptedPollInterval
        let host = deps.host
        let clock = deps.clock
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await clock.sleep(for: interval)
                if Task.isCancelled { return }
                if !host.isAlive(newPID) {
                    await self?.engineExited(pid: newPID, termination: nil)
                    return
                }
            }
        }
        startLogCap()
    }

    private func watch(_ spawned: any SpawnedProcess) {
        watchTask?.cancel()
        let watchedPID = spawned.pid
        watchTask = Task { [weak self] in
            let termination = await spawned.waitForExit()
            await self?.engineExited(pid: watchedPID, termination: termination)
        }
        startLogCap()
    }

    /// The engine exited without this controller shutting it down. That is either a crash, or a clean stop /
    /// hibernate by *another* Emuu process (the app and the CLI both observe the same engine; `emuu hibernate`
    /// talks to the engine directly when the app governs it). A clean exit always writes a fresh, full-size
    /// `default_boot` (console `kill` and SIGTERM both save), so:
    /// * fresh complete snapshot, no "unable to save default_boot" in the engine log since launch, and not
    ///   SIGKILLed → stopped elsewhere: keep the snapshot and the other process's files, report
    ///   `.hibernated`/`.stopped` from the marker (re-checked for a few seconds, since the stopping process
    ///   writes the marker only after verifying the save);
    /// * otherwise → crash: the existing snapshot predates the disks (or is a stub), so it is discarded.
    /// The exit status alone cannot tell: measured on 36.4.9, an engine stopped with console `kill` logs
    /// "Saving snapshot 'default_boot' … saving done" and then dies with SIGABRT (signal 6).
    /// An adopted engine (exit status unknowable) that leaves no snapshot at all is reported as stopped: there
    /// is nothing to discard and no evidence of a crash.
    private func engineExited(pid exitedPID: Int32, termination: ProcessTermination?) {
        guard exitedPID == pid else { return }
        if shuttingDownPID == exitedPID { return } // stop/hibernate finish the bookkeeping
        let since = engineSince ?? .distantPast
        let sigkilled = termination == .signaled(signal: SIGKILL)
        var snapshotState = quickBootSnapshotState(since: since)
        if snapshotState == .freshComplete,
           Self.read(paths.engineLogFile(for: instanceID), from: engineLogOffset).contains("unable to save default_boot") {
            snapshotState = .stale
        }
        watchTask = nil
        if !sigkilled && snapshotState == .freshComplete {
            log.notice("engine pid \(exitedPID) exited cleanly (stopped by another process; quick-boot snapshot saved)")
            clearRuntime(removeArtifacts: false)
            settleAfterExternalStop()
            return
        }
        if termination == nil && snapshotState == .absent {
            log.notice("adopted engine pid \(exitedPID) exited (no quick-boot snapshot to keep)")
            clearRuntime(removeArtifacts: false)
            settleAfterExternalStop()
            return
        }
        let reason = crashReason(termination)
        log.error("engine pid \(exitedPID) exited unexpectedly: \(reason)")
        // The quick-boot snapshot is older than the disks now; loading it would roll userdata back.
        invalidateQuickBoot()
        clearRuntime()
        CrashMarker.set(for: instanceID, paths: paths, reason: reason)
        setState(.crashed(reason: reason))
    }

    enum QuickBootSnapshotState: Equatable { case absent, stale, freshComplete }

    /// `default_boot` relative to `since`: absent, older (or a stub), or written after `since` with a
    /// plausible `ram.bin`.
    func quickBootSnapshotState(since: Date) -> QuickBootSnapshotState {
        let dir = snapshotsDirectory.appendingPathComponent("default_boot", isDirectory: true)
        guard let pbDate = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("snapshot.pb").path))?[.modificationDate] as? Date else {
            return .absent
        }
        guard pbDate >= since, Self.fileSize(dir.appendingPathComponent("ram.bin")) >= Self.minimumRAMSnapshotBytes else { return .stale }
        return .freshComplete
    }

    /// After another process stopped the engine: report the marker state now and again for a short while,
    /// because a hibernating process sets the marker only after it has verified the snapshot.
    private func settleAfterExternalStop() {
        setState(HibernationMarker.isSet(for: instanceID, paths: paths) ? .hibernated : .stopped)
        let interval = timings.adoptedPollInterval
        let clock = deps.clock
        let rounds = max(1, Int((Duration.seconds(20) / interval).rounded(.up)))
        watchTask = Task { [weak self] in
            for _ in 0..<rounds {
                try? await clock.sleep(for: interval)
                if Task.isCancelled { return }
                guard let self, await self.applyMarkerIfIdle() else { return }
            }
        }
    }

    /// Re-reads the marker while no engine is attached. Returns false once there is nothing left to settle.
    private func applyMarkerIfIdle() -> Bool {
        guard pid == nil, current == .stopped || current == .hibernated else { return false }
        setState(HibernationMarker.isSet(for: instanceID, paths: paths) ? .hibernated : .stopped)
        return true
    }

    /// Caps the engine log in place every few minutes while this controller watches the engine. Its stdout and
    /// stderr are an O_APPEND descriptor held by the engine, so truncation is safe (writes continue at the new end).
    private func startLogCap() {
        logCapTask?.cancel()
        let url = paths.engineLogFile(for: instanceID)
        logCapTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                if Task.isCancelled { return }
                LogFileCap.capInPlace(url, limit: Self.engineLogLimit)
            }
        }
    }

    public static let engineLogLimit: UInt64 = 8 * 1024 * 1024

    /// A SIGKILLed engine cannot remove its discovery file
    /// (`~/Library/Caches/TemporaryItems/avd/running/pid_<pid>.ini`, which holds its gRPC token); measured: farm
    /// devices destroyed with SIGKILL left theirs behind. Only the file of the pid Emuu just killed is removed.
    static func removeDiscoveryFile(pid: Int32, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let url = home.appendingPathComponent("Library/Caches/TemporaryItems/avd/running/pid_\(pid).ini")
        try? FileManager.default.removeItem(at: url)
    }

    private func crashReason(_ termination: ProcessTermination?) -> String {
        var parts: [String] = [termination.map { "engine \($0)" } ?? "engine process disappeared"]
        let interesting = Self.tail(of: paths.engineLogFile(for: instanceID), bytes: 16 * 1024)
            .filter { ($0.contains("FATAL") || $0.contains("ERROR") || $0.contains("crash")) && !$0.hasPrefix("INFO") }
        if let last = interesting.last { parts.append(last.trimmingCharacters(in: .whitespaces)) }
        return parts.joined(separator: "; ")
    }

    private func writePIDFile(_ pid: Int32) {
        try? FileManager.default.createDirectory(at: paths.runDirectory, withIntermediateDirectories: true)
        try? Data("\(pid)\n".utf8).write(to: paths.pidFile(for: instanceID), options: .atomic)
    }

    static func tail(of url: URL, bytes: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// Keeps the engine log bounded across long runs: >8 MiB at launch moves it to `.1`.
    static func rotateLogIfLarge(_ url: URL, limit: UInt64 = 8 * 1024 * 1024) {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value, size > limit else { return }
        let rotated = url.deletingPathExtension().appendingPathExtension("1.log")
        try? fm.removeItem(at: rotated)
        try? fm.moveItem(at: url, to: rotated)
    }

    static func appendLogHeader(_ url: URL, _ line: String) {
        let data = Data("==== \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
