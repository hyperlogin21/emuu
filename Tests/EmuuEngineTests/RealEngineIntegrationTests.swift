import Darwin
import Foundation
import Testing
import EmuuBase
@testable import EmuuEngine

/// Drives the real engine on instance `emuu-dev` (console 5580). Opt-in only:
/// `EMUU_ENGINE_IT=1 swift test --filter RealEngineIntegration --scratch-path .build-engine`
/// Leaves emuu-dev running and booted.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["EMUU_ENGINE_IT"] == "1"))
struct RealEngineIntegration {
    static let id = InstanceID(rawValue: "emuu-dev")!

    static func footprintMB(_ pid: Int32) -> Double {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return rc == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : -1
    }

    static func cpuPercent(_ pid: Int32, over seconds: Double) async -> Double {
        func cpuNS() -> UInt64 {
            var info = rusage_info_v4()
            _ = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            // ri_user_time/ri_system_time are in mach absolute time units.
            var tb = mach_timebase_info_data_t()
            mach_timebase_info(&tb)
            return (info.ri_user_time + info.ri_system_time) * UInt64(tb.numer) / UInt64(tb.denom)
        }
        let a = cpuNS()
        try? await Task.sleep(for: .seconds(seconds))
        let b = cpuNS()
        return Double(b - a) / (seconds * 1e9) * 100
    }

    static func adb(_ args: [String], timeout: Duration = .seconds(10)) async throws -> ProcessResult {
        let sdk = try SDKLocator().locate()
        return try await SystemProcessRunner().run(ProcessRequest(executable: sdk.adb, arguments: args, timeout: timeout))
    }

    static func time<T>(_ body: () async throws -> T) async rethrows -> (T, Double) {
        let start = ContinuousClock.now
        let v = try await body()
        return (v, (ContinuousClock.now - start).timeInterval)
    }

    @Test func fullLifecycleOnEmuuDev() async throws {
        let env = try EngineEnvironment.live()
        print("SDK: \(env.sdk.root.path) emulator \(env.sdk.emulatorVersion ?? "?") adb \(env.sdk.adb.path)")
        print("preferred image: \(env.preferredImage?.description ?? "none")")
        let config = InstancePreset.standard.makeConfig(id: Self.id, displayName: "Emuu dev", ports: try InstancePorts(console: 5580))
        // Rewrite config.ini from code (keeps userdata). Must be stopped for that.
        if env.store.isRunning(Self.id) {
            if (try? env.store.load(Self.id)) == nil { try InstanceStore.encode(config, to: env.paths.instanceConfigFile(for: Self.id)) }
            try await env.engine(for: Self.id).stop(.graceful(saveQuickBoot: true))
            env.forget(Self.id)
        }
        try env.store.adoptOrUpdate(config)
        var engine: EngineInstance
        env.forget(Self.id)
        engine = try await env.engine(for: Self.id)
        print("initial state: \(await engine.state())")

        // Boot (quick boot if a snapshot exists, else cold).
        let hadSnapshot = try await engine.listSnapshots().contains("default_boot")
        let (_, bootSecs) = try await Self.time { try await engine.start() }
        #expect(await engine.state() == .running)
        let pid = try #require(await engine.enginePID())
        print("BOOT (\(hadSnapshot ? "quick" : "cold")) to sys.boot_completed: \(String(format: "%.1f", bootSecs)) s, pid \(pid)")
        let argv = SystemHostProcesses().arguments(of: pid) ?? []
        print("engine argv: \(argv.joined(separator: " "))")
        #expect(argv.first?.contains("qemu-system-aarch64-headless") == true)
        let hw = try IniFile(contentsOf: env.paths.avdDirectory(for: Self.id).appendingPathComponent("hardware-qemu.ini"))
        print("hardware-qemu.ini: ramSize=\(hw["hw.ramSize"] ?? "?") ncore=\(hw["hw.cpu.ncore"] ?? "?") vm.heapSize=\(hw["vm.heapSize"] ?? "?") audioInput=\(hw["hw.audioInput"] ?? "?") sdCard=\(hw["hw.sdCard"] ?? "?") camera.back=\(hw["hw.camera.back"] ?? "?") light=\(hw["hw.sensors.light"] ?? "?")")
        #expect(hw["hw.ramSize"] == "2048")
        #expect(hw["hw.audioInput"] == "false")
        let loaded = try await engine.loadedSnapshot()
        print("loaded snapshot: \(loaded ?? "(none, cold boot)")")

        try await Task.sleep(for: .seconds(20)) // let post-boot work settle
        let runCPU = await Self.cpuPercent(pid, over: 10)
        print("RUNNING idle: footprint \(Int(Self.footprintMB(pid))) MB, CPU \(String(format: "%.1f", runCPU))%")

        // T4 via SIGSTOP.
        let (_, freezeSecs) = try await Self.time { try await engine.freeze() }
        #expect(await engine.state() == .frozen)
        #expect(SystemHostProcesses().isStopped(pid))
        let frozenCPU = await Self.cpuPercent(pid, over: 10)
        print("FROZEN(signal) in \(String(format: "%.3f", freezeSecs)) s: footprint \(Int(Self.footprintMB(pid))) MB, CPU \(String(format: "%.2f", frozenCPU))%")
        // A second controller (another Emuu process) must see it frozen.
        let otherEnv = try EngineEnvironment.live()
        let other = try await otherEnv.engine(for: Self.id)
        #expect(await other.state() == .frozen)
        #expect(await other.enginePID() == pid)
        try await engine.freeze() // idempotent
        let (_, thawSecs) = try await Self.time { try await engine.thaw() }
        let (probe, adbSecs) = try await Self.time { try await Self.adb(["-s", "emulator-5580", "shell", "echo", "alive"]) }
        print("THAW(signal) in \(String(format: "%.3f", thawSecs)) s; first adb shell after thaw: '\(probe.trimmedStdout)' in \(String(format: "%.2f", adbSecs)) s")
        #expect(probe.trimmedStdout == "alive")

        // T4 via console.
        await engine.setFreezeMechanism(.console)
        try await engine.freeze()
        #expect(await engine.state() == .frozen)
        let consoleFrozenCPU = await Self.cpuPercent(pid, over: 10)
        print("FROZEN(console): footprint \(Int(Self.footprintMB(pid))) MB, CPU \(String(format: "%.2f", consoleFrozenCPU))%")
        let otherEnv2 = try EngineEnvironment.live()
        let o2 = try await otherEnv2.engine(for: Self.id)
        #expect(await o2.state() == .frozen)
        try await engine.thaw()
        #expect(try await Self.adb(["-s", "emulator-5580", "shell", "echo", "alive"]).trimmedStdout == "alive")
        await engine.setFreezeMechanism(.signal)

        // T3.
        let reclaim = try await engine.reclaimGuestMemory(targetBytes: 512 * 1_048_576)
        print("RECLAIM: \(reclaim)")

        // Named snapshot round trip.
        let (_, saveSecs) = try await Self.time { try await engine.saveSnapshot(named: "emuu_it") }
        let names = try await engine.listSnapshots()
        print("snapshots after save (\(String(format: "%.1f", saveSecs)) s): \(names)")
        #expect(names.contains("emuu_it"))
        try await engine.deleteSnapshot(named: "emuu_it")
        #expect(try await engine.listSnapshots().contains("emuu_it") == false)

        // T5: hibernate, observe from another controller, resume.
        let footBefore = Self.footprintMB(pid)
        let (_, hibSecs) = try await Self.time { try await engine.hibernate() }
        #expect(await engine.state() == .hibernated)
        #expect(SystemHostProcesses().isAlive(pid) == false)
        let snapDir = env.paths.avdDirectory(for: Self.id).appendingPathComponent("snapshots/default_boot")
        let ramSize = ((try? FileManager.default.attributesOfItem(atPath: snapDir.appendingPathComponent("ram.bin").path)[.size]) as? NSNumber)?.int64Value ?? -1
        print("HIBERNATE (save+quit) took \(String(format: "%.1f", hibSecs)) s; host footprint released: \(Int(footBefore)) MB; ram.bin \(ramSize / 1_048_576) MB")
        let otherEnv3 = try EngineEnvironment.live()
        let o3 = try await otherEnv3.engine(for: Self.id)
        #expect(await o3.state() == .hibernated)
        let (_, resumeSecs) = try await Self.time { try await engine.resume() }
        #expect(await engine.state() == .running)
        let newPID = try #require(await engine.enginePID())
        print("RESUME (quick boot) to sys.boot_completed: \(String(format: "%.1f", resumeSecs)) s; loaded snapshot: \(try await engine.loadedSnapshot() ?? "none")")
        try await Task.sleep(for: .seconds(15))
        print("after resume: footprint \(Int(Self.footprintMB(newPID))) MB, CPU \(String(format: "%.1f", await Self.cpuPercent(newPID, over: 10)))%")

        // Adoption by a fresh controller.
        let otherEnv4 = try EngineEnvironment.live()
        let adopted = try await otherEnv4.engine(for: Self.id)
        #expect(await adopted.state() == .running)
        #expect(await adopted.enginePID() == newPID)
        #expect(await adopted.serial() == DeviceSerial(rawValue: "emulator-5580"))
        #expect(try await Self.adb(["-s", "emulator-5580", "shell", "getprop", "sys.boot_completed"]).trimmedStdout == "1")
        print("left emuu-dev running, pid \(newPID)")
    }
}
