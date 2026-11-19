import Darwin
import Foundation
import Testing
import EmuuBase
import EmuuTestSupport
@testable import EmuuEngine

/// Wires an `EngineInstance` to fakes: process runner (spawn + adb), host processes and console.
final class EngineRig: @unchecked Sendable {
    let world: TempWorld
    let runner = FakeProcessRunner()
    let host: FakeHost
    let console: FakeConsole
    let config: InstanceConfig
    let deps: EngineDependencies
    /// Replies to `getprop sys.boot_completed`, in order; the last repeats.
    let bootReplies = Locked<[String]>(["", "1"])
    let vmStopped = Locked(false)
    /// Whether console `kill` writes a fresh default_boot snapshot and makes the process exit.
    let killSaves = Locked(true)
    let killExits = Locked(true)
    let loaded = Locked<String?>(nil)

    static let timings: EngineTimings = {
        var t = EngineTimings()
        t.bootPollInterval = .milliseconds(5)
        t.exitPollInterval = .milliseconds(5)
        t.gracefulExitTimeout = .milliseconds(300)
        t.termGrace = .milliseconds(300)
        t.killGrace = .milliseconds(300)
        t.adoptedPollInterval = .milliseconds(10)
        t.signalSettle = .milliseconds(300)
        return t
    }()

    init(world: TempWorld? = nil, fixedPorts: Bool = true) throws {
        let w = try world ?? TempWorld()
        self.world = w
        host = FakeHost(runner: runner)
        let id = InstanceID(rawValue: "phone")!
        let store = try InstanceStore(paths: w.paths, sdk: w.sdk)
        if let existing = try? store.load(id) {
            config = existing
        } else {
            config = try store.create(InstancePreset.standard.makeConfig(id: id, ports: fixedPorts ? try InstancePorts(console: 5580) : nil))
        }
        console = FakeConsole()
        deps = EngineDependencies(runner: runner, clock: SystemClock(), host: host, consoleConnector: console,
                                  consoleToken: "secret", isPortFree: { _ in true }, isAVDLocked: { _ in false })

        let replies = bootReplies
        runner.on({ $0.executable.lastPathComponent == "adb" && $0.arguments.suffix(3) == ["shell", "getprop", "sys.boot_completed"] },
                  respond: .handler { req in
                      let out = replies.withLock { r -> String in r.count > 1 ? r.removeFirst() : r[0] }
                      return ProcessResult(request: req, termination: .exited(code: 0), stdout: Data((out + "\n").utf8))
                  })
        let snapshots = w.paths.avdDirectory(for: id).appendingPathComponent("snapshots", isDirectory: true)
        console.handler = { [runner, vmStopped, killSaves, killExits, loaded] cmd in
            switch cmd {
            case "kill":
                if killSaves.current { Self.writeSnapshot(snapshots, "default_boot") }
                if killExits.current { runner.spawnedProcesses.last?.exit(code: 0) }
                return .okThenClose("OK: killing emulator, bye bye")
            case "avd stop": vmStopped.set(true); return .ok("")
            case "avd start": vmStopped.set(false); return .ok("")
            case "avd status": return .ok(vmStopped.current ? "virtual device is stopped" : "virtual device is running")
            case "avd snapshot get": return .ok(loaded.current ?? "(null)")
            case "avd snapshot list":
                let names = EngineInstance.snapshotsOnDisk(snapshots)
                if names.isEmpty { return .ok("There is no snapshot available.") }
                return .ok("List of snapshots present on all disks:\nID        TAG                 VM SIZE                DATE       VM CLOCK\n"
                           + names.map { "--        \($0)            68M 2026-11-18 20:58:52   00:07:26.927" }.joined(separator: "\n"))
            default:
                if cmd.hasPrefix("avd snapshot save ") { Self.writeSnapshot(snapshots, String(cmd.dropFirst(18))); return .ok("") }
                if cmd.hasPrefix("avd snapshot delete ") {
                    try? FileManager.default.removeItem(at: snapshots.appendingPathComponent(String(cmd.dropFirst(20))))
                    return .ok("")
                }
                if cmd.hasPrefix("avd snapshot load ") { return .ok("") }
                return .ko("unknown command, try 'help'")
            }
        }
    }

    static func writeSnapshot(_ dir: URL, _ name: String, ramBytes: UInt64 = EngineInstance.minimumRAMSnapshotBytes) {
        let d = dir.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? Data("pb".utf8).write(to: d.appendingPathComponent("snapshot.pb"))
        // Sparse file: costs no disk space.
        let ram = d.appendingPathComponent("ram.bin")
        FileManager.default.createFile(atPath: ram.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: ram) { try? h.truncate(atOffset: ramBytes); try? h.close() }
    }

    func makeEngine(freeze: FreezeMechanism = .signal) -> EngineInstance {
        EngineInstance(config: config, sdk: world.sdk, paths: world.paths, dependencies: deps, timings: Self.timings, freezeMechanism: freeze)
    }

    var lastProcess: FakeSpawnedProcess? { runner.spawnedProcesses.last }
    var snapshotDir: URL { world.paths.avdDirectory(for: config.id).appendingPathComponent("snapshots/default_boot") }
}

func eventually(_ timeout: Duration = .seconds(2), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

@Suite struct EngineInstanceTests {
    @Test func startSpawnsHeadlessEngineAndWaitsForBoot() async throws {
        let rig = try EngineRig()
        rig.bootReplies.set(["", "0", "1"])
        let engine = rig.makeEngine()
        let updates = await engine.stateUpdates()
        try await engine.start()
        #expect(await engine.state() == .running)
        let proc = try #require(rig.lastProcess)
        #expect(proc.request.executable == rig.world.sdk.emulator)
        #expect(proc.request.arguments.starts(with: ["-avd", "phone", "-no-window", "-no-boot-anim", "-ports", "5580,5581"]))
        #expect(proc.request.environment["ANDROID_AVD_HOME"] == rig.world.paths.avdHome.path)
        #expect(proc.request.stdout == .file(rig.world.paths.engineLogFile(for: rig.config.id)))
        #expect(try String(contentsOf: rig.world.paths.pidFile(for: rig.config.id), encoding: .utf8) == "\(proc.pid)\n")
        #expect(await engine.enginePID() == proc.pid)
        #expect(await engine.serial() == DeviceSerial(rawValue: "emulator-5580"))
        var seen: [InstanceState] = []
        for await s in updates { seen.append(s); if s == .running { break } }
        #expect(seen == [.stopped, .booting, .running])
        try await engine.start() // idempotent
        #expect(rig.runner.spawnedProcesses.count == 1)
    }

    @Test func picksFreePortsWhenNoneFixed() async throws {
        let rig = try EngineRig(fixedPorts: false)
        let deps = EngineDependencies(runner: rig.runner, clock: SystemClock(), host: rig.host, consoleConnector: rig.console,
                                      consoleToken: "secret", isPortFree: { $0 >= 5560 }, isAVDLocked: { _ in false })
        rig.runner.on({ $0.executable.lastPathComponent == "adb" }, respond: .success("1\n"))
        let engine = EngineInstance(config: rig.config, sdk: rig.world.sdk, paths: rig.world.paths, dependencies: deps, timings: EngineRig.timings)
        try await engine.start()
        #expect(await engine.serial() == DeviceSerial(rawValue: "emulator-5560"))
        #expect(rig.lastProcess?.request.arguments.contains("5560,5561") == true)
    }

    @Test func bootTimeoutKillsEngine() async throws {
        let rig = try EngineRig()
        rig.bootReplies.set(["0"])
        let engine = rig.makeEngine()
        await #expect(throws: EmuuError.self) { try await engine.start(EngineLaunchOptions(bootTimeout: .milliseconds(100))) }
        #expect(rig.lastProcess?.receivedSignals.contains(SIGKILL) == true)
        #expect(await engine.state() == .stopped)
    }

    @Test func crashWhileBootingFailsStart() async throws {
        let rig = try EngineRig()
        rig.bootReplies.set(["0"])
        let engine = rig.makeEngine()
        let task = Task { try await engine.start() }
        #expect(await eventually { rig.lastProcess != nil })
        try Data("ERROR | something\nFATAL | could not init hvf\n".utf8).write(to: rig.world.paths.engineLogFile(for: rig.config.id))
        rig.lastProcess?.exit(code: 1)
        await #expect(throws: EmuuError.self) { try await task.value }
        guard case .crashed(let reason) = await engine.state() else { Issue.record("expected crashed"); return }
        #expect(reason.contains("exit 1") && reason.contains("could not init hvf"))
    }

    @Test func crashWhileRunningIsReportedAndQuickBootDiscarded() async throws {
        let rig = try EngineRig()
        let engine = rig.makeEngine()
        // A quick-boot snapshot from before this launch (the engine booted from it), then a crash.
        EngineRig.writeSnapshot(rig.snapshotDir.deletingLastPathComponent(), "default_boot")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)],
                                              ofItemAtPath: rig.snapshotDir.appendingPathComponent("snapshot.pb").path)
        try await engine.start()
        rig.lastProcess?.finish(.signaled(signal: SIGSEGV))
        #expect(await eventually { if case .crashed = await engine.state() { true } else { false } })
        #expect(!FileManager.default.fileExists(atPath: rig.snapshotDir.path))
        #expect(!FileManager.default.fileExists(atPath: rig.world.paths.pidFile(for: rig.config.id).path))
        #expect(await engine.enginePID() == nil)
        try await engine.stop(.graceful(saveQuickBoot: true)) // acknowledges the crash
        #expect(await engine.state() == .stopped)
        try await engine.start() // can start again after a crash
        #expect(await engine.state() == .running)
    }

    @Test func freezeAndThawWithSignals() async throws {
        let rig = try EngineRig()
        let engine = rig.makeEngine(freeze: .signal)
        await #expect(throws: EmuuError.invalidStateTransition(from: .stopped, action: "freeze")) { try await engine.freeze() }
        try await engine.start()
        try await engine.freeze()
        #expect(await engine.state() == .frozen)
        try await engine.freeze() // idempotent
        #expect(rig.lastProcess?.receivedSignals == [SIGSTOP])
        // Another controller sees the stopped process as frozen.
        let other = rig.makeEngine()
        #expect(await other.refresh() == .frozen)
        try await engine.thaw()
        #expect(rig.lastProcess?.receivedSignals == [SIGSTOP, SIGCONT])
        #expect(await engine.state() == .running)
        try await engine.thaw() // idempotent
    }

    @Test func freezeAndThawWithConsole() async throws {
        let rig = try EngineRig()
        let engine = rig.makeEngine(freeze: .console)
        try await engine.start()
        try await engine.freeze()
        #expect(await engine.state() == .frozen)
        #expect(rig.vmStopped.current)
        #expect(await rig.makeEngine().refresh() == .frozen)
        try await engine.thaw()
        #expect(!rig.vmStopped.current)
        #expect(rig.console.commands.contains("avd stop") && rig.console.commands.contains("avd start"))
        #expect(rig.lastProcess?.receivedSignals.isEmpty == true)
    }

    @Test func hibernateSavesAndQuitsThenResumeQuickBoots() async throws {
        let rig = try EngineRig()
        let engine = rig.makeEngine()
        try await engine.start()
        try await engine.freeze()
        try await engine.hibernate() // thaws first: the console cannot answer a SIGSTOPped engine
        #expect(await engine.state() == .hibernated)
        #expect(rig.lastProcess?.receivedSignals == [SIGSTOP, SIGCONT])
        #expect(rig.console.commands.contains("kill"))
        #expect(HibernationMarker.isSet(for: rig.config.id, paths: rig.world.paths))
        #expect(await engine.enginePID() == nil)
        #expect(try await engine.listSnapshots() == ["default_boot"]) // from disk while not running
        // A fresh controller (another process) sees it hibernated.
        #expect(await rig.makeEngine().refresh() == .hibernated)

        try await engine.resume()
        #expect(await engine.state() == .running)
        #expect(rig.runner.spawnedProcesses.count == 2)
        #expect(rig.runner.spawnedProcesses[1].request.arguments.contains("-no-snapshot-load") == false)
        #expect(!HibernationMarker.isSet(for: rig.config.id, paths: rig.world.paths))
        rig.loaded.set("default_boot")
        #expect(try await engine.loadedSnapshot() == "default_boot")
    }

    @Test func hibernateWithoutFreshSnapshotFails() async throws {
        let rig = try EngineRig()
        rig.killSaves.set(false)
        let engine = rig.makeEngine()
        try await engine.start()
        await #expect(throws: EmuuError.self) { try await engine.hibernate() }
        // Parked: hibernated (so auto-resume and supervisors treat it as such), next start cold-boots.
        #expect(await engine.state() == .hibernated)
        #expect(HibernationMarker.isSet(for: rig.config.id, paths: rig.world.paths))
        #expect(!FileManager.default.fileExists(atPath: rig.snapshotDir.path))
    }

    @Test func hibernateRejectsStubSnapshotAndEngineSaveFailure() async throws {
        let rig = try EngineRig()
        let engine = rig.makeEngine()
        try await engine.start()
        // Engine writes only a tiny ram.bin (failed save).
        rig.killSaves.set(false)
        let snapshots = rig.snapshotDir.deletingLastPathComponent()
        rig.console.handler = { [runner = rig.runner] cmd in
            if cmd == "kill" {
                EngineRig.writeSnapshot(snapshots, "default_boot", ramBytes: 4096)
                runner.spawnedProcesses.last?.exit(code: 0)
                return .okThenClose("OK: killing emulator, bye bye")
            }
            return .ok("")
        }
        await #expect(throws: EmuuError.self) { try await engine.hibernate() }
        #expect(await engine.state() == .hibernated)
        #expect(!FileManager.default.fileExists(atPath: rig.snapshotDir.path))

        // Full-size snapshot but the engine log says the save failed.
        try await engine.start()
        let logURL = rig.world.paths.engineLogFile(for: rig.config.id)
        rig.console.handler = { [runner = rig.runner] cmd in
            if cmd == "kill" {
                EngineRig.writeSnapshot(snapshots, "default_boot")
                if let h = try? FileHandle(forWritingTo: logURL) {
                    _ = try? h.seekToEnd()
                    try? h.write(contentsOf: Data("USER_WARNING | The emulator was unable to save default_boot and will now erase it\n".utf8))
                    try? h.close()
                }
                runner.spawnedProcesses.last?.exit(code: 0)
                return .okThenClose("OK: killing emulator, bye bye")
            }
            return .ok("")
        }
        await #expect(throws: EmuuError.self) { try await engine.hibernate() }
        #expect(await engine.state() == .hibernated)
        #expect(!FileManager.default.fileExists(atPath: rig.snapshotDir.path))
        // Resume cold-boots (no quick-boot snapshot) and clears the marker.
        try await engine.resume()
        #expect(await engine.state() == .running)
        #expect(!HibernationMarker.isSet(for: rig.config.id, paths: rig.world.paths))
    }

    @Test func gracefulStopWithoutSaveDiscardsQuickBoot() async throws {
        let rig = try EngineRig()
        let engine = rig.makeEngine()
        try await engine.start()
        try await engine.stop(.graceful(saveQuickBoot: false))
        #expect(await engine.state() == .stopped)
        #expect(!FileManager.default.fileExists(atPath: rig.snapshotDir.path))
        try await engine.stop(.graceful(saveQuickBoot: false)) // idempotent

        try await engine.start()
        try await engine.stop(.graceful(saveQuickBoot: true))
        #expect(FileManager.default.fileExists(atPath: rig.snapshotDir.appendingPathComponent("snapshot.pb").path))
        #expect(!HibernationMarker.isSet(for: rig.config.id, paths: rig.world.paths))
    }

    @Test func gracefulStopEscalatesToSIGTERMWhenKillIsIgnored() async throws {
        let rig = try EngineRig()
        rig.killExits.set(false)
        let engine = rig.makeEngine()
        try await engine.start()
        try await engine.stop(.graceful(saveQuickBoot: true))
        #expect(rig.lastProcess?.receivedSignals == [SIGTERM])
        #expect(await engine.state() == .stopped)
    }

    @Test func gracefulStopEscalatesToSIGKILL() async throws {
        let rig = try EngineRig()
        rig.killExits.set(false)
        let engine = rig.makeEngine()
        try await engine.start()
        rig.lastProcess?.exitsOnTerminate = false
        await #expect(throws: EmuuError.self) { try await engine.stop(.graceful(saveQuickBoot: true)) }
        #expect(rig.lastProcess?.receivedSignals == [SIGTERM, SIGKILL])
        #expect(!FileManager.default.fileExists(atPath: rig.snapshotDir.path))
    }

    @Test func forceStopKillsFrozenEngine() async throws {
        let rig = try EngineRig()
        let engine = rig.makeEngine()
        try await engine.start()
        try await engine.freeze()
        try await engine.stop(.force)
        #expect(rig.lastProcess?.receivedSignals == [SIGSTOP, SIGKILL])
        #expect(await engine.state() == .stopped)
    }

    @Test func snapshotsViaConsole() async throws {
        let rig = try EngineRig()
        let engine = rig.makeEngine()
        await #expect(throws: EmuuError.self) { try await engine.saveSnapshot(named: "x") }
        try await engine.start()
        try await engine.saveSnapshot(named: "before_game")
        #expect(try await engine.listSnapshots() == ["before_game"])
        try await engine.loadSnapshot(named: "before_game")
        try await engine.deleteSnapshot(named: "before_game")
        #expect(try await engine.listSnapshots() == [])
        #expect(rig.console.commands.filter { $0.hasPrefix("avd snapshot") } ==
                ["avd snapshot save before_game", "avd snapshot list", "avd snapshot load before_game",
                 "avd snapshot delete before_game", "avd snapshot list"])
    }

    @Test func reclaimIsUnsupportedWithReason() async throws {
        let rig = try EngineRig()
        let engine = rig.makeEngine()
        await #expect(throws: EmuuError.self) { _ = try await engine.reclaimGuestMemory(targetBytes: nil) }
        try await engine.start()
        guard case .unsupported(let reason) = try await engine.reclaimGuestMemory(targetBytes: 1 << 29) else {
            Issue.record("expected unsupported"); return
        }
        #expect(reason.contains("virtio_balloon"))
    }

    @Test func adoptsEngineStartedByAnotherProcess() async throws {
        let rig = try EngineRig(fixedPorts: false)
        rig.bootReplies.set(["1"])
        let pid: Int32 = 7777
        rig.host.addForeign(pid: pid,
                            argv: ["/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64-headless", "-avd", "phone", "-ports", "5590,5591"],
                            env: ["ANDROID_AVD_HOME": rig.world.paths.avdHome.path])
        // Same name under a different AVD home must be ignored.
        rig.host.addForeign(pid: 8888, argv: ["/x/qemu-system-aarch64", "-avd", "phone", "-ports", "5600,5601"],
                            env: ["ANDROID_AVD_HOME": "/elsewhere"])
        let engine = rig.makeEngine()
        #expect(await engine.refresh() == .running)
        #expect(await engine.enginePID() == pid)
        #expect(await engine.serial() == DeviceSerial(rawValue: "emulator-5590"))
        try await engine.freeze()
        #expect(rig.host.isStopped(pid))
        #expect(rig.host.signalsToForeign.current.map(\.1) == [SIGSTOP])
        try await engine.thaw()
        #expect(!rig.host.isStopped(pid))
        // The adopted engine dies on its own and leaves no snapshot: detected by polling, reported stopped.
        rig.host.killForeign(pid)
        #expect(await eventually { await engine.state() == .stopped })
    }

    /// Regression: an observer (the app's library, a display-only window) must not treat a clean hibernate by
    /// another Emuu process as a crash, which deleted the snapshot that process had just saved.
    @Test func adoptedEngineHibernatedElsewhereKeepsSnapshot() async throws {
        let rig = try EngineRig(fixedPorts: false)
        rig.bootReplies.set(["1"])
        let pid: Int32 = 7778
        rig.host.addForeign(pid: pid,
                            argv: ["/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64-headless", "-avd", "phone", "-ports", "5590,5591"],
                            env: ["ANDROID_AVD_HOME": rig.world.paths.avdHome.path])
        let observer = rig.makeEngine()
        #expect(await observer.refresh() == .running)
        // The other process: console kill saves default_boot, the engine exits, then it sets the marker.
        let pidFile = rig.world.paths.pidFile(for: rig.config.id)
        let lock = rig.world.paths.avdDirectory(for: rig.config.id).appendingPathComponent("multiinstance.lock")
        try Data().write(to: lock)
        EngineRig.writeSnapshot(rig.snapshotDir.deletingLastPathComponent(), "default_boot")
        rig.host.killForeign(pid)
        #expect(await eventually { await observer.state() == .stopped })
        try HibernationMarker.set(for: rig.config.id, paths: rig.world.paths, at: Date())
        #expect(await eventually { await observer.state() == .hibernated })
        #expect(FileManager.default.fileExists(atPath: rig.snapshotDir.appendingPathComponent("snapshot.pb").path))
        // The stopping process owns the cleanup; the observer leaves its files alone.
        #expect(FileManager.default.fileExists(atPath: lock.path))
        #expect(FileManager.default.fileExists(atPath: pidFile.path))
    }

    /// An adopted engine that dies while only an old snapshot exists did crash: that snapshot is discarded.
    @Test func adoptedEngineCrashDiscardsStaleSnapshot() async throws {
        let rig = try EngineRig(fixedPorts: false)
        rig.bootReplies.set(["1"])
        EngineRig.writeSnapshot(rig.snapshotDir.deletingLastPathComponent(), "default_boot")
        let old = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: rig.snapshotDir.appendingPathComponent("snapshot.pb").path)
        let pid: Int32 = 7779
        rig.host.addForeign(pid: pid,
                            argv: ["/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64-headless", "-avd", "phone", "-ports", "5590,5591"],
                            env: ["ANDROID_AVD_HOME": rig.world.paths.avdHome.path])
        let observer = rig.makeEngine()
        #expect(await observer.refresh() == .running)
        rig.host.killForeign(pid)
        #expect(await eventually { if case .crashed = await observer.state() { true } else { false } })
        #expect(!FileManager.default.fileExists(atPath: rig.snapshotDir.path))
    }

    /// The app spawned the engine; `emuu hibernate` (another process) stops it through the console. The
    /// spawning controller sees a clean exit with a fresh snapshot: not a crash, snapshot kept.
    @Test func spawnedEngineStoppedByAnotherProcessIsNotACrash() async throws {
        let rig = try EngineRig()
        let engine = rig.makeEngine()
        try await engine.start()
        EngineRig.writeSnapshot(rig.snapshotDir.deletingLastPathComponent(), "default_boot")
        // Measured on 36.4.9: after console `kill` saves default_boot the engine dies with SIGABRT.
        rig.lastProcess?.finish(.signaled(signal: SIGABRT))
        #expect(await eventually { await engine.state() == .stopped })
        try HibernationMarker.set(for: rig.config.id, paths: rig.world.paths, at: Date())
        #expect(await eventually { await engine.state() == .hibernated })
        #expect(FileManager.default.fileExists(atPath: rig.snapshotDir.path))
        try await engine.resume()
        #expect(await engine.state() == .running)
        #expect(rig.runner.spawnedProcesses.count == 2)
    }

    /// A fresh snapshot is not proof of a clean save when the engine logged that the save failed, and a
    /// SIGKILLed engine never saved.
    @Test func spawnedEngineExitAfterFailedSaveOrSIGKILLIsACrash() async throws {
        let rig = try EngineRig()
        let engine = rig.makeEngine()
        try await engine.start()
        EngineRig.writeSnapshot(rig.snapshotDir.deletingLastPathComponent(), "default_boot")
        let log = try FileHandle(forWritingTo: rig.world.paths.engineLogFile(for: rig.config.id))
        _ = try log.seekToEnd()
        try log.write(contentsOf: Data("USER_WARNING | The emulator was unable to save default_boot and will now erase it\n".utf8))
        try log.close()
        rig.lastProcess?.exit(code: 0)
        #expect(await eventually { if case .crashed = await engine.state() { true } else { false } })
        #expect(!FileManager.default.fileExists(atPath: rig.snapshotDir.path))

        try await engine.stop(.graceful(saveQuickBoot: true))
        try await engine.start()
        EngineRig.writeSnapshot(rig.snapshotDir.deletingLastPathComponent(), "default_boot")
        rig.lastProcess?.finish(.signaled(signal: SIGKILL))
        #expect(await eventually { if case .crashed = await engine.state() { true } else { false } })
        #expect(!FileManager.default.fileExists(atPath: rig.snapshotDir.path))
    }

    /// Regression: concurrent start()/resume() (governor auto-resume racing a `wake` request) spawned two
    /// engines with the same ports, orphaning the first.
    @Test func concurrentStartsSpawnOneEngine() async throws {
        let rig = try EngineRig()
        rig.bootReplies.set(["", "", "", "1"])
        let engine = rig.makeEngine()
        async let a: Void = engine.start()
        async let b: Void = engine.resume()
        async let c: Void = engine.start()
        _ = try await (a, b, c)
        #expect(rig.runner.spawnedProcesses.count == 1)
        #expect(await engine.state() == .running)
        #expect(await engine.enginePID() == rig.lastProcess?.pid)
    }

    @Test func startRefusesWhenLockedByUnknownEngine() async throws {
        let rig = try EngineRig()
        let deps = EngineDependencies(runner: rig.runner, clock: SystemClock(), host: rig.host, consoleConnector: rig.console,
                                      consoleToken: "secret", isPortFree: { _ in true }, isAVDLocked: { _ in true })
        let engine = EngineInstance(config: rig.config, sdk: rig.world.sdk, paths: rig.world.paths, dependencies: deps, timings: EngineRig.timings)
        await #expect(throws: EmuuError.self) { try await engine.start() }
        #expect(rig.runner.spawnedProcesses.isEmpty)
    }

    @Test func startCleansStaleLockFiles() async throws {
        let rig = try EngineRig()
        let stale = rig.world.paths.avdDirectory(for: rig.config.id).appendingPathComponent("hardware-qemu.ini.lock")
        try Data("123".utf8).write(to: stale)
        try await rig.makeEngine().start()
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test func environmentCachesOneControllerPerInstance() async throws {
        let rig = try EngineRig()
        let env = try EngineEnvironment(paths: rig.world.paths, sdk: rig.world.sdk, dependencies: rig.deps, timings: EngineRig.timings)
        let a = try await env.engine(for: rig.config.id)
        let b = try await env.engine(for: rig.config.id)
        #expect(a === b)
        env.forget(rig.config.id)
        #expect(try await env.engine(for: rig.config.id) !== a)
        await #expect(throws: EmuuError.instanceNotFound(InstanceID(rawValue: "nope")!)) {
            _ = try await env.engine(for: InstanceID(rawValue: "nope")!)
        }
        #expect(env.preferredImage?.ref == .playStoreDefault)
        #expect(env.missingPlayStoreImageAdvice == nil)
        let created = try env.createInstance(id: InstanceID(rawValue: "lite1")!, preset: .lite)
        #expect(created.ramMB == 1536)
        try await env.deleteInstance(created.id)
        #expect(!env.store.exists(created.id))
    }
}
