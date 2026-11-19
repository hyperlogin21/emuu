import Darwin
import Foundation
import EmuuBase
import EmuuEngine

/// `FarmDeviceDriver` over real engines: APFS clones of the golden AVD (with its quick-boot snapshot),
/// `EngineInstance` for start/reset/stop, `HealthProber` for health.
public final class LiveFarmDriver: FarmDeviceDriver, @unchecked Sendable {
    public let engines: EngineEnvironment
    public let prober: HealthProber
    private let log = EmuuLogger(category: "farm.driver")

    public init(engines: EngineEnvironment, runner: any ProcessRunner = SystemProcessRunner()) {
        self.engines = engines
        self.prober = HealthProber(runner: runner, adb: engines.sdk.adb)
    }

    /// Engine timings for farm devices: boot/reset readiness is polled every 100 ms (the default 1 s would add up
    /// to a second to every acquire).
    public static var farmTimings: EngineTimings {
        var t = EngineTimings()
        t.bootPollInterval = .milliseconds(100)
        t.adbProbeTimeout = .seconds(5)
        t.gracefulExitTimeout = .seconds(30)
        return t
    }

    public func provision(instance: String, consolePort: Int, golden: GoldenRecord) async throws -> Int32 {
        let id = try InstanceID(validating: instance)
        let goldenID = try InstanceID(validating: golden.name)
        if engines.store.exists(id) { await destroy(instance: instance) }
        let ports = try InstancePorts(console: consolePort)
        try engines.store.clone(goldenID, to: id, includeSnapshots: true) { c in
            c.ports = ports
            c.automationMode = true
            c.discardStateOnExit = true
            c.goldenSource = golden.name
            c.selfHeal = true
        }
        engines.forget(id)
        let engine = try await engines.engine(for: id)
        try await engine.start(EngineLaunchOptions(bootTimeout: .seconds(180)))
        guard let pid = await engine.enginePID() else { throw EmuuError.engine("\(instance) has no engine pid after start") }
        if let loaded = try? await engine.loadedSnapshot(), loaded != "default_boot" {
            throw EmuuError.engine("\(instance) did not resume from the golden snapshot (cold boot); re-seal the golden")
        }
        return pid
    }

    public func reset(instance: String) async throws {
        let id = try InstanceID(validating: instance)
        let engine = try await engines.engine(for: id)
        await engine.refresh()
        try await engine.resetToQuickBootSnapshot()
        await resetCamera(id, engine: engine)
    }

    /// After a reset the virtual scene camera is back to its known state: default posters and the start pose. The
    /// snapshot load restores the guest, not the engine's scene (a picture shown with `emuu camera show` would
    /// otherwise stay). Best effort: a device without the virtual scene has nothing to reset.
    func resetCamera(_ id: InstanceID, engine: EngineInstance) async {
        guard let config = try? engines.store.load(id),
              CameraLaunchPlan.launchedCameras(avdDirectory: engines.paths.avdDirectory(for: id))?.back == "virtualscene" else { return }
        do {
            let (scene, _) = try await VirtualSceneAccess.open(paths: engines.paths, engine: engine, config: config)
            try await scene.clear()
            CameraShownState.remove(engines.paths, id)
        } catch {
            log.warning("reset \(id): camera scene not reset: \(describe(error))")
        }
    }

    public func destroy(instance: String) async {
        guard let id = InstanceID(rawValue: instance) else { return }
        if let engine = try? await engines.engine(for: id) {
            await engine.refresh()
            do { try await engine.stop(.force) } catch { log.warning("destroy \(instance): \(describe(error))") }
        }
        engines.forget(id)
        if engines.store.exists(id) {
            do { try engines.store.delete(id) } catch { log.warning("delete \(instance): \(describe(error))") }
        }
    }

    public func health(_ device: FarmDevice, golden: GoldenRecord, deep: Bool) async -> HealthReport {
        let target = HealthProber.Target(instance: device.instance, enginePID: device.enginePID, consolePort: device.consolePort,
                                         frozenByEmuu: InstanceID(rawValue: device.instance).map { FreezeMarker.isSet(for: $0, paths: engines.paths) } ?? false,
                                         expectedBootID: golden.bootID)
        return await prober.check(target, deep: deep, farmDevice: true)
    }

    public func freeze(instance: String) async throws {
        let engine = try await engines.engine(for: InstanceID(validating: instance))
        await engine.refresh()
        try await engine.freeze()
    }

    public func thaw(instance: String) async throws {
        let engine = try await engines.engine(for: InstanceID(validating: instance))
        await engine.refresh()
        if await engine.state() == .frozen { try await engine.thaw() }
    }

    public func reconnectADB(serial: String) async {
        _ = try? await SystemProcessRunner().run(ProcessRequest(executable: engines.sdk.adb, arguments: ["-s", serial, "reconnect"], timeout: .seconds(10)))
        _ = try? await SystemProcessRunner().run(ProcessRequest(executable: engines.sdk.adb, arguments: ["reconnect", "offline"], timeout: .seconds(10)))
    }

    public func isPortFree(_ port: Int) -> Bool { PortAllocator.isPortFree(port) }

    public func isAlive(_ pid: Int32) -> Bool { SystemHostProcesses().isAlive(pid) }

    public func hostFacts() -> HostFacts { HostFacts.current() }
}
