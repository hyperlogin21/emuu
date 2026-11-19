import Foundation
import Testing
import EmuuBase
import EmuuMemory
import EmuuTestSupport
@testable import emuu

/// Short temp dir (unix socket paths are limited to 103 bytes).
func shortTempDir() throws -> URL {
    let url = URL(fileURLWithPath: "/tmp/emuu-t-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct ControlSocketTests {
    @Test func roundTripsRequestsAndReplies() async throws {
        let dir = try shortTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("s.sock").path
        let seen = Locked<[ControlRequest]>([])
        let server = try ControlServer(socketPath: path) { req in
            seen.withLock { $0.append(req) }
            switch req.command {
            case .events:
                return ControlReply(ok: true, events: [], nextSeq: (req.since ?? 0) + 1)
            case .trim:
                return ControlReply(ok: true, reports: [TierReport(step: "T1", outcome: .applied("x", reclaimedBytes: 4096))])
            default:
                return .failure("nope: \(req.command.rawValue)")
            }
        }
        defer { server.close() }
        let client = ControlClient(socketPath: path)

        let r1 = try await client.send(ControlRequest(command: .events, since: 41))
        #expect(r1.ok && r1.nextSeq == 42)
        let r2 = try await client.send(ControlRequest(command: .trim, kill: true, level: .background, cachesBytes: 1 << 30))
        #expect(r2.reports?.first?.reclaimedBytes == 4096)
        let r3 = try await client.send(ControlRequest(command: .freeze))
        #expect(!r3.ok && r3.message == "nope: freeze")
        let trim = seen.current.first { $0.command == .trim }
        #expect(trim?.level == .background && trim?.kill == true && trim?.cachesBytes == 1 << 30)
    }

    @Test func servesConcurrentClientsAndCleansUp() async throws {
        let dir = try shortTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("c.sock").path
        let server = try ControlServer(socketPath: path) { req in
            try? await Task.sleep(for: .milliseconds(50))
            return ControlReply(ok: true, nextSeq: req.since)
        }
        let results = await withTaskGroup(of: UInt64?.self) { group in
            for i in 0..<20 {
                group.addTask { try? await ControlClient(socketPath: path).send(ControlRequest(command: .events, since: UInt64(i))).nextSeq }
            }
            var out: [UInt64] = []
            for await r in group { if let r { out.append(r) } }
            return out.sorted()
        }
        #expect(results == (0..<20).map(UInt64.init))
        server.close()
        #expect(!FileManager.default.fileExists(atPath: path))
        await #expect(throws: (any Error).self) { try await ControlClient(socketPath: path).send(ControlRequest(command: .status)) }
    }

    @Test func rejectsGarbageWithAReply() throws {
        let dir = try shortTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("g.sock").path
        let server = try ControlServer(socketPath: path) { _ in ControlReply(ok: true) }
        defer { server.close() }
        var addr = try UnixSocket.address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        UnixSocket.setTimeouts(fd, .seconds(5))
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(rc == 0)
        #expect(UnixSocket.writeAll(fd, Data("{not json\n".utf8)))
        let line = try #require(UnixSocket.readLine(fd))
        let reply = try JSONText.decoder.decode(ControlReply.self, from: line)
        #expect(!reply.ok)
        #expect(reply.message?.hasPrefix("bad request") == true)
    }

    @Test func socketPathTooLongIsRejectedAndRegistryFallsBack() throws {
        let long = "/tmp/" + String(repeating: "x", count: 120) + ".sock"
        #expect(throws: (any Error).self) { _ = try UnixSocket.address(long) }
        let fallback = SupervisorRegistry.socketPath(preferred: long)
        #expect(fallback.hasPrefix("/tmp/emuu-\(getuid())-"))
        #expect(fallback.utf8.count <= UnixSocket.maxPathBytes)
        #expect(SupervisorRegistry.socketPath(preferred: long) == fallback)   // stable
        #expect(SupervisorRegistry.socketPath(preferred: "/tmp/a.sock") == "/tmp/a.sock")
    }
}

@Suite struct RegistryTests {
    @Test func lockStatusAndCleanup() throws {
        let dir = try shortTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = EmuuPaths(root: dir)
        try paths.ensureDirectories()
        let registry = SupervisorRegistry(paths: paths)
        let id = try InstanceID(validating: "pixel")
        #expect(registry.liveSupervisor(for: id) == nil)

        let lock = try #require(try FileLock(url: registry.lockFile(for: id)))
        #expect(registry.isLocked(id))
        #expect(try FileLock(url: registry.lockFile(for: id)) == nil)   // second holder refused

        let status = SupervisorStatus(
            instanceID: "pixel", pid: 1234, mode: "headless", startedAt: Date(timeIntervalSince1970: 1_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_000_060), socketPath: registry.socketPath(for: id), ownsEngine: true,
            visible: false, engineState: "running", engineStateDetail: "running", enginePID: 99, serial: "emulator-5554",
            governor: .init(enabled: true, profile: "balanced", level: "normal", tier: "T0 none", tierNumber: 0, disabledTiers: ["T3 reclaim"],
                            creepActive: false, samplesTaken: 3, actionsApplied: 1, actionsFailed: 0, maintenanceRuns: 0,
                            consecutiveGuestSampleFailures: 0, freezeWhenHiddenAfterSeconds: nil, hibernateWhenFrozenAfterSeconds: 7200),
            lastSample: nil, lastEvent: "x")
        try registry.writeStatus(status, for: id)
        #expect(registry.liveSupervisor(for: id) == nil)   // no socket yet: not a reachable CLI supervisor
        #expect(registry.otherHolder(for: id) == "another Emuu process")
        try "{\"ownerKind\":\"app\",\"ownerPID\":77}".write(to: paths.runDirectory.appendingPathComponent("pixel.frontend.json"), atomically: true, encoding: .utf8)
        #expect(registry.otherHolder(for: id) == "the Emuu app (pid 77)")
        #expect(FileManager.default.createFile(atPath: status.socketPath, contents: nil))
        let live = try #require(registry.liveSupervisor(for: id))
        #expect(live.pid == 1234)
        #expect(live.status == status)
        #expect(live.socketPath == status.socketPath)

        registry.cleanUp(id, socketPath: status.socketPath)
        #expect(registry.readStatus(id) == nil)
        lock.release()
        #expect(!registry.isLocked(id))
        #expect(registry.otherHolder(for: id) == nil)
        #expect(registry.liveSupervisor(for: id) == nil)
    }

    @Test func effectiveRAMReadsWhatTheEngineUsed() throws {
        let dir = try shortTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = EmuuPaths(root: dir)
        let config = InstancePresetFixtures.config("lite", profile: .frugal, ramMB: 1536)
        #expect(EffectiveRAM.megabytes(for: config, paths: paths) == 1536)   // never booted
        let avd = paths.avdDirectory(for: config.id)
        try FileManager.default.createDirectory(at: avd, withIntermediateDirectories: true)
        try "hw.cpu.ncore = 2\nhw.ramSize = 2048\n".write(to: avd.appendingPathComponent("hardware-qemu.ini"), atomically: true, encoding: .utf8)
        #expect(EffectiveRAM.megabytes(for: config, paths: paths) == 2048)
    }
}

@Suite struct GovernorWiringTests {
    @Test func headlessDisablesIdleFreezeUnlessAsked() {
        let base = GovernorConfig.preset(.balanced, guestRAMMB: 2048)
        #expect(base.freezeWhenHiddenAfter != nil)
        let headless = GovernorOptions(profile: .balanced, guestRAMMB: 2048, headless: true, idleFreezeAfter: nil).config()
        #expect(headless.freezeWhenHiddenAfter == nil)
        #expect(headless.autoResume)
        #expect(headless.engineFootprintBudgetBytes == GovernorConfig.footprintBudget(guestRAMMB: 2048))
        let idle = GovernorOptions(profile: .frugal, guestRAMMB: 2048, headless: true, idleFreezeAfter: .minutes(4)).config()
        #expect(idle.freezeWhenHiddenAfter == .minutes(4))
        let window = GovernorOptions(profile: .performance, guestRAMMB: 3072, headless: false, idleFreezeAfter: .minutes(1)).config()
        #expect(window == GovernorConfig.preset(.performance, guestRAMMB: 3072))
    }

    @Test func activityCombinesOverrideDisplayAndTouches() async throws {
        let clock = FakeClock()
        let display = Display()
        let id = try InstanceID(validating: "a")
        let activity = SupervisorActivity(display: display, clock: clock)
        #expect(await activity.isDisplayVisible(id) == false)
        #expect(await activity.lastUserInteraction(id) == nil)
        display.visible.set(true)
        display.last.set(.seconds(5))
        #expect(await activity.isDisplayVisible(id))
        #expect(await activity.lastUserInteraction(id) == .seconds(5))
        clock.advance(by: .seconds(10))
        activity.noteInteraction()
        #expect(await activity.lastUserInteraction(id) == clock.monotonicNow())
        activity.setVisible(false)
        #expect(await activity.isDisplayVisible(id) == false)
        activity.setVisible(nil)
        #expect(await activity.isDisplayVisible(id))

        let headless = SupervisorActivity(clock: clock)
        #expect(await headless.isDisplayVisible(id) == false)
    }

    /// Regression: a front end that reported "visible" and then crashed pinned the instance as visible forever
    /// (no idle freeze, no hibernate). The report now expires unless refreshed.
    @Test func reportedVisibilityExpiresWithoutRefresh() async throws {
        let clock = FakeClock()
        let id = try InstanceID(validating: "a")
        let activity = SupervisorActivity(clock: clock, visibilityTTL: .seconds(60))
        activity.setVisible(true)
        #expect(await activity.isDisplayVisible(id))
        clock.advance(by: .seconds(40))
        activity.setVisible(true) // the app's 20 s heartbeat
        clock.advance(by: .seconds(40))
        #expect(await activity.isDisplayVisible(id))
        clock.advance(by: .seconds(30))
        #expect(await activity.isDisplayVisible(id) == false)
    }

    final class Display: GovernorActivitySource, @unchecked Sendable {
        let visible = Locked(false)
        let last = Locked<Duration?>(nil)
        func isDisplayVisible(_ id: InstanceID) async -> Bool { visible.current }
        func lastUserInteraction(_ id: InstanceID) async -> Duration? { last.current }
    }

    @Test func manualReclaimReportsUnsupportedHonestlyAndCompacts() async throws {
        let id = try InstanceID(validating: "a")
        let engine = FakeEngineControl(instanceID: id)
        engine.reclaimOutcome = .unsupported(reason: "no balloon")
        let shell = FakeDeviceShell()
        shell.onShell(prefix: "cmd activity help", reply: .ok("Activity manager (activity) commands:\n  send-trim-memory [--user <USER_ID>] <PROCESS>\n  kill [--user <USER_ID> | all | current] <PACKAGE>\n  compact [some|full] <PROCESS>\n"))
        shell.onShell(prefix: "cmd package help", reply: .ok("Package manager (package) commands:\n  trim-caches DESIRED_FREE_SPACE [internal|UUID]\n"))
        shell.onShell(where: { $0.contains("compact system") }, reply: .ok("avail 100\n@@run\n@@done\navail 300\n"))
        let reports = await ManualTiers.reclaim(guest: GuestEffector(shell: shell), engine: EngineEffector(engine: engine))
        #expect(reports.count == 2)
        #expect(reports[0].status == "unsupported")
        #expect(reports[0].detail.contains("no balloon"))
        #expect(reports[1].status == "applied")
        #expect(reports[1].reclaimedBytes == 200 * 1024)
        #expect(ManualTiers.render(reports).contains("+200 KiB"))
    }

    @Test func manualTrimReportsFailuresPerStep() async throws {
        let shell = FakeDeviceShell()
        shell.onShell(prefix: "cmd activity help", reply: .error(.deviceNotReady(shell.serial)))
        let reports = await ManualTiers.trim(guest: GuestEffector(shell: shell), level: .moderate, kill: true, caches: 1 << 30)
        #expect(reports.map(\.step) == ["T1 send-trim-memory MODERATE", "T1 trim-caches", "T2 kill cached apps"])
        #expect(reports.allSatisfy { $0.status == "failed" })
    }
}

@Suite struct PlannerAndResolutionTests {
    @Test func installPlannerHandlesFilesDirectoriesAndSplitSets() throws {
        let dir = try shortTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        func touch(_ rel: String) throws -> URL {
            let u = dir.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: u)
            return u.standardizedFileURL
        }
        let single = try touch("one.apk")
        let xapk = try touch("game.XAPK")
        let split1 = try touch("splits/split_config.arm64_v8a.apk")
        let base = try touch("splits/base.apk")
        let loose1 = try touch("loose/a.apk")
        let loose2 = try touch("loose/b.apk")
        let bundle = try touch("loose/c.apkm")
        _ = try touch("loose/readme.txt")
        _ = try touch("empty/readme.txt")

        #expect(try InstallPlanner.plan([single.path, xapk.path], splitSet: false) == [.apk(single), .xapk(xapk)])
        #expect(try InstallPlanner.plan([dir.appendingPathComponent("splits").path], splitSet: false) == [.splitAPKs([base, split1])])
        #expect(try InstallPlanner.plan([dir.appendingPathComponent("loose").path], splitSet: false) == [.apk(loose1), .apk(loose2), .apkm(bundle)])
        #expect(try InstallPlanner.plan([dir.appendingPathComponent("loose").path], splitSet: true) == [.splitAPKs([loose1, loose2]), .apkm(bundle)])
        #expect(try InstallPlanner.plan([loose2.path, loose1.path, xapk.path], splitSet: true) == [.splitAPKs([loose1, loose2]), .xapk(xapk)])
        #expect(throws: InstallPlanner.Problem.self) { try InstallPlanner.plan([dir.appendingPathComponent("empty").path], splitSet: false) }
        #expect(throws: InstallPlanner.Problem.self) { try InstallPlanner.plan([dir.appendingPathComponent("nope.apk").path], splitSet: false) }
        #expect(throws: InstallPlanner.Problem.self) { try InstallPlanner.plan([dir.appendingPathComponent("loose/readme.txt").path], splitSet: false) }
    }

    @Test func defaultInstanceResolution() throws {
        let a = InstancePresetFixtures.config("a"), b = InstancePresetFixtures.config("b")
        #expect(try InstanceResolution.pick(from: [a], isActive: { _ in false }).id == a.id)
        #expect(try InstanceResolution.pick(from: [a, b], isActive: { $0.id == b.id }).id == b.id)
        #expect(throws: CLIError.self) { try InstanceResolution.pick(from: [], isActive: { _ in true }) }
        #expect(throws: CLIError.self) { try InstanceResolution.pick(from: [a, b], isActive: { _ in true }) }
        #expect(throws: CLIError.self) { try InstanceResolution.pick(from: [a, b], isActive: { _ in false }) }
    }
}

@Suite struct FormattingTests {
    @Test func tableAlignsColumns() {
        let t = Fmt.table(["NAME", "STATE"], [["a", "running"], ["longer", "stopped"]])
        #expect(t == "NAME    STATE\na       running\nlonger  stopped")
    }

    @Test func uptimeAndMemoryLine() {
        #expect(Fmt.uptime(12) == "12s")
        #expect(Fmt.uptime(250) == "4m 10s")
        #expect(Fmt.uptime(7500) == "2h 05m")
        #expect(Fmt.uptime(90_000) == "1d 01h")
        let line = Fmt.memoryLine(guestTotal: 2 * ByteCount.gib, guestAvailable: ByteCount.gib, engineFootprint: 4 * ByteCount.gib,
                                  enginePeak: 5 * ByteCount.gib, cpuPercent: 3.4, hostPressure: .elevated, swapUsed: 512 * ByteCount.mib)
        #expect(line == "guest 1.00 GiB/2.00 GiB used (avail 50%), zram 512 MiB · engine 4.00 GiB (peak 5.00 GiB) · cpu 3% · host elevated")
        #expect(Fmt.memoryLine(guestTotal: nil, guestAvailable: nil, engineFootprint: nil, enginePeak: nil, cpuPercent: nil, hostPressure: nil)
                == "guest - · engine -")
    }

    @Test func logTailTakesLastLines() {
        let data = Data("1\n2\n3\n4\n".utf8)
        #expect(LogTail.lastLines(data, count: 2) == "3\n4")
        #expect(LogTail.lastLines(data, count: 10) == "1\n2\n3\n4")
        #expect(LogTail.lastLines(data, count: 0) == "")
    }

    @Test func eventTextRendersActions() throws {
        let id = try InstanceID(validating: "a")
        let e = GovernorEvent(instanceID: id, timestamp: Date(), kind: .actionApplied(.trimMemory(level: .background, packages: []),
                                                                                     .applied("trim BACKGROUND → 3/3 processes", reclaimedBytes: 2 * ByteCount.mib)))
        let text = EventText.render(e)
        #expect(text.contains("action"))
        #expect(text.contains("applied: trim BACKGROUND → 3/3 processes (+2 MiB guest available)"))
        let creep = EventText.render(GovernorEvent(instanceID: id, timestamp: Date(), kind: .creepDetected(bytesPerHour: 200 * Int64(ByteCount.mib), window: .hours(1))))
        #expect(creep.contains("+200 MiB/h over 1h 00m"))
    }

    @Test func benchMarkdownHasEveryRow() {
        var r = BenchReport(instance: "p", ramMB: 2048, cores: 4, engineVersion: "36.4.9", host: "16 GB Mac", date: Date(timeIntervalSince1970: 0))
        r.coldBoot = .milliseconds(23_400)
        r.hibernate = .milliseconds(2_100)
        r.resume = .milliseconds(1_900)
        r.hibernateFootprintBefore = 4 * ByteCount.gib
        r.phases = [
            .init(label: "Without governor", minutes: 10, footprintStart: 3 * ByteCount.gib, footprintEnd: 4 * ByteCount.gib,
                  footprintPeak: 4 * ByteCount.gib, residentEnd: 2 * ByteCount.gib, guestAvailableEnd: ByteCount.gib,
                  guestTotal: 2 * ByteCount.gib, cpuAveragePercent: 12.5, governorActions: nil),
            .init(label: "With governor (balanced)", minutes: 10, footprintStart: nil, footprintEnd: nil, footprintPeak: nil,
                  residentEnd: nil, guestAvailableEnd: nil, guestTotal: nil, cpuAveragePercent: nil, governorActions: 2,
                  governorNotes: ["trim applied"]),
        ]
        let md = r.markdown()
        #expect(md.contains("| Cold boot (launch → sys.boot_completed) | 23.4 s |"))
        #expect(md.contains("| Resume from hibernation (quick boot → sys.boot_completed) | 1.9 s |"))
        #expect(md.contains("| Host memory returned by hibernate | 4.00 GiB"))
        #expect(md.contains("| Without governor | 10 | 3072 MiB | 4096 MiB | 4096 MiB | 2048 MiB | 1024 MiB (50%) | 12.5% | n/a |"))
        #expect(md.contains("| With governor (balanced) | 10 | - | - | - | - | - | - | 2 |"))
        #expect(md.contains("- With governor (balanced): trim applied"))
    }
}

@Suite struct DoctorTests {
    static func facts() -> DoctorFacts {
        DoctorFacts(isARM64: true, macOSVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 1, patchVersion: 0),
                    hypervisorSupported: true, physicalMemoryBytes: 16 * ByteCount.gib, sdkRoot: "/sdk", sdkError: nil,
                    sdkManagerPath: "/sdk/cmdline-tools/latest/bin/sdkmanager", emulatorVersion: "36.4.9",
                    accelCheckOutput: "accel:\n0\nHypervisor.Framework OS X Version 26.6\naccel", playStoreImages: ["ps"],
                    otherARMImages: [], imageAdvice: nil, adbPath: "/sdk/platform-tools/adb", adbServerVersion: 41, adbError: nil,
                    emuuHome: "/home/.emuu", emuuHomeWritable: true, engineGRPCAvailable: true, instanceCount: 0, runningInstances: [])
    }

    @Test func healthyMachineHasNoFailures() {
        let checks = Self.facts().evaluate()
        #expect(!checks.contains { $0.level == .fail || $0.level == .warn })
        #expect(checks.first { $0.name == "Engine acceleration" }?.detail == "Hypervisor.Framework OS X Version 26.6")
        #expect(checks.first { $0.name == "Instances" }?.fix == "emuu create phone && emuu start phone")
    }

    @Test func missingPiecesGetFixCommands() {
        var f = Self.facts()
        f.playStoreImages = []
        f.otherARMImages = ["system-images;android-35;google_apis;arm64-v8a"]
        f.adbServerVersion = nil
        f.adbError = "connection refused"
        f.emulatorVersion = "34.1.0"
        let checks = f.evaluate()
        let image = checks.first { $0.name == "Play Store image" }
        #expect(image?.level == .warn)
        #expect(image?.fix == "/sdk/cmdline-tools/latest/bin/sdkmanager \"system-images;android-36.1;google_apis_playstore;arm64-v8a\"")
        #expect(checks.first { $0.name == "adb" }?.fix == "/sdk/platform-tools/adb start-server")
        #expect(checks.first { $0.name == "Emulator engine" }?.level == .warn)

        f.sdkRoot = nil
        f.sdkError = "Android SDK not found."
        f.isARM64 = false
        let noSDK = f.evaluate()
        #expect(noSDK.first { $0.name == "Android SDK" }?.level == .fail)
        #expect(noSDK.first { $0.name == "Apple Silicon" }?.level == .fail)
        #expect(!noSDK.contains { $0.name == "adb" })
        #expect(noSDK.last?.name == "Instances")
    }

    @Test func versionParsing() {
        #expect(DoctorFacts.versionTriple("36.4.9") == [36, 4, 9])
        #expect(DoctorFacts.versionTriple("35.1") == [35, 1, 0])
        #expect(DoctorFacts.versionTriple("x") == nil)
    }
}
