import Foundation
import Testing
import EmuuBase
import EmuuTestSupport
@testable import EmuuMemory

/// Minimal adb-backed DeviceShell for opt-in device tests (EmuuADB provides the real one; this
/// module must not depend on it).
struct TestADBShell: DeviceShell {
    let serial: DeviceSerial
    let adbPath: String
    let runner = SystemProcessRunner()

    func shell(_ command: String, timeout: Duration?) async throws -> ProcessResult {
        try await adb(["shell", command], timeout: timeout)
    }

    func adb(_ arguments: [String], timeout: Duration?) async throws -> ProcessResult {
        try await runner.run(ProcessRequest(executable: URL(fileURLWithPath: adbPath),
                                            arguments: ["-s", serial.rawValue] + arguments, timeout: timeout))
    }
}

/// Runs only with `EMUU_DEVICE_SERIAL=emulator-5580 swift test --filter DeviceIntegrationTests`.
/// Non-destructive: trims two background processes, kills one cached app, `compact system`,
/// `trim-caches 1` (frees nothing when ≥1 byte is free).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["EMUU_DEVICE_SERIAL"] != nil))
struct DeviceIntegrationTests {
    let shell: TestADBShell = {
        let serial = ProcessInfo.processInfo.environment["EMUU_DEVICE_SERIAL"] ?? "emulator-5580"
        let sdk = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk/platform-tools/adb").path
        let adb = FileManager.default.isExecutableFile(atPath: sdk) ? sdk : "/opt/homebrew/bin/adb"
        return TestADBShell(serial: DeviceSerial(rawValue: serial), adbPath: adb)
    }()

    @Test func realSampleAndCost() async throws {
        let sampler = GuestSampler(shell: shell)
        let a = try await sampler.sample()
        try await Task.sleep(for: .seconds(2))
        let b = try await sampler.sample()
        print("[device] total=\(ByteCount.format(b.memory.totalBytes)) avail=\(ByteCount.format(b.memory.availableBytes)) (\(String(format: "%.1f", b.memory.availableFraction * 100))%) swapUsed=\(ByteCount.format(b.memory.swapUsedBytes)) psi=\(String(describing: b.memory.pressureStall)) cached=\(b.memory.cachedProcessCount ?? -1) fg=\(b.foregroundPackages) rates=\(String(describing: b.vmRates)) rtt=\(a.roundTrip),\(b.roundTrip)")
        #expect(b.memory.totalBytes > 1 * gib)
        #expect(b.memory.cachedProcessCount != nil)
        #expect(!b.foregroundProcesses.isEmpty)
        #expect(b.vmRates != nil)
        #expect(b.roundTrip < .seconds(2))
    }

    @Test func realCapabilitiesAndEffectors() async throws {
        let e = GuestEffector(shell: shell, maxTargets: 2)
        let caps = try await e.capabilities()
        print("[device] caps=\(caps)")
        #expect(caps == GuestCapabilities(sendTrimMemory: true, kill: true, compact: true, trimCaches: true))

        let targets = try await e.targets(minAdj: GuestEffector.cachedMinAdj)
        print("[device] fg=\(targets.foreground) cachedCandidates=\(targets.candidates.map(\.name))")
        let trim = try await e.apply(.trimMemory(level: .background, packages: []))
        print("[device] trim → \(trim)")
        #expect(trim.status == .applied)

        if let victim = targets.candidates.first.flatMap({ GuestParsers.packageName(fromProcessName: $0.name) }) {
            let kill = try await e.apply(.killBackground(packages: [victim]))
            print("[device] kill \(victim) → \(kill)")
            #expect(kill.status == .applied)
        }
        let compact = try await e.compactSystem()
        print("[device] compact → \(compact)")
        #expect(compact.status == .applied)
        let tc = try await e.apply(.trimCaches(desiredFreeBytes: 1))
        print("[device] trim-caches → \(tc)")
        #expect(tc.status == .applied)
    }

    @Test func realEngineFootprint() async throws {
        let r = try await SystemProcessRunner().run(ProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/pgrep"),
                                                                   arguments: ["-f", "qemu-system-aarch64.*-avd emuu-dev"]))
        let pid = try #require(r.trimmedStdout.split(separator: "\n").first.flatMap { Int32($0) })
        let clock = SystemClock()
        let sampler = HostSampler(clock: clock)
        _ = sampler.sample(enginePID: pid)
        try await Task.sleep(for: .seconds(2))
        let s = sampler.sample(enginePID: pid)
        let e = try #require(s.engine)
        print("[host] pid=\(pid) procs=\(e.processCount) footprint=\(ByteCount.format(e.footprintBytes)) peak=\(ByteCount.format(e.lifetimeMaxFootprintBytes)) rss=\(ByteCount.format(e.residentBytes)) cpu=\(String(format: "%.1f", e.cpuPercent ?? -1))% cpuTotal=\(String(format: "%.1f", e.cpuSeconds))s | system free=\(ByteCount.format(s.system.freeBytes)) compressed=\(ByteCount.format(s.system.compressedBytes)) swap=\(ByteCount.format(s.system.swapUsedBytes))/\(ByteCount.format(s.system.swapTotalBytes)) kernelLevel=\(s.system.kernelPressureLevel ?? -1) pressure=\(s.system.pressure)")
        #expect(e.footprintBytes > 256 * mib)
        #expect(e.cpuPercent != nil)
    }

    /// Live loop for ~65 s with SystemClock. The engine is a FakeEngineControl carrying the real
    /// QEMU pid, so freeze/hibernate can never touch the real engine; display visible + user active.
    @Test func realGovernorLoop() async throws {
        let r = try await SystemProcessRunner().run(ProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/pgrep"),
                                                                   arguments: ["-f", "qemu-system-aarch64.*-avd emuu-dev"]))
        let pid = try #require(r.trimmedStdout.split(separator: "\n").first.flatMap { Int32($0) })
        let engine = FakeEngineControl(instanceID: testID, state: .running, pid: pid, serial: shell.serial)
        let activity = FakeActivity(visible: true)
        let clock = SystemClock()
        activity.interact(at: clock.monotonicNow())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("emuu-live-\(UUID().uuidString)")
        let csv = SampleCSVLog(url: dir.appendingPathComponent("live.csv"))
        let g = MemoryGovernor.standard(instanceID: testID, config: .preset(.balanced), engine: engine, shell: shell,
                                        activity: activity, clock: clock, csvLog: csv)
        let events = await g.events()
        await g.start()
        try await Task.sleep(for: .seconds(65))
        await g.stop()
        var kinds: [String] = []
        for await e in events { kinds.append("\(e.kind)".components(separatedBy: "(").first ?? "") }
        let status = await g.status()
        let csvText = try String(contentsOf: dir.appendingPathComponent("live.csv"), encoding: .utf8)
        print("[live] status level=\(status.level) tier=\(status.tier) samples=\(status.samplesTaken) applied=\(status.actionsApplied) failed=\(status.actionsFailed) guestFailures=\(status.consecutiveGuestSampleFailures)")
        print("[live] events=\(kinds)")
        print("[live] csv:\n\(csvText)")
        #expect(status.samplesTaken >= 3)
        #expect(status.consecutiveGuestSampleFailures == 0)
        #expect(engine.calls.isEmpty)
        try? FileManager.default.removeItem(at: dir)
    }
}
