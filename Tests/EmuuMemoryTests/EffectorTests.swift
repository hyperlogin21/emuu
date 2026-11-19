import Foundation
import Testing
import EmuuBase
import EmuuTestSupport
@testable import EmuuMemory

let activityHelpFixture = """
Activity manager (activity) commands:
  help
      Print this help text.
  kill [--user <USER_ID> | all | current] <PACKAGE>
      Kill all background processes associated with the given application.
  kill-all
      Kill all processes that are safe to kill (cached, etc).
  send-trim-memory [--user <USER_ID>] <PROCESS>
          [HIDDEN|RUNNING_MODERATE|BACKGROUND|RUNNING_LOW|MODERATE|RUNNING_CRITICAL|COMPLETE]
  compact [some|full] <PROCESS> [--user <USER_ID>]
      Perform a single process compaction.
"""

let packageHelpFixture = """
Package manager (package) commands:
  trim-caches DESIRED_FREE_SPACE [internal|UUID]
      Trim cache files to reach the given free space.
"""

let processListFixture = """
0 com.example.game
0 com.example.game:render
905 com.google.android.gms.persistent
910 com.android.vending
915 com.whatsapp
915 com.whatsapp
920 com.spotify.music:service
950 com.example.game:bg
300 com.foo.backup
600 com.google.android.apps.nexuslauncher
-800 system_server
930 android.process.acore
940 /system/bin/some_daemon
"""

@Suite struct GuestEffectorTests {
    func makeShell() -> FakeDeviceShell {
        let shell = FakeDeviceShell(serial: .emulator(consolePort: 5580))
        shell.onShell("cmd activity help 2>&1", reply: .ok(activityHelpFixture))
        shell.onShell("cmd package help 2>&1", reply: .ok(packageHelpFixture))
        shell.onShell(prefix: "for d in /proc/[0-9]*", reply: .ok(processListFixture))
        return shell
    }

    @Test func capabilitiesParse() {
        let c = GuestCapabilities.parse(activityHelp: activityHelpFixture, packageHelp: packageHelpFixture)
        #expect(c == GuestCapabilities(sendTrimMemory: true, kill: true, compact: true, trimCaches: true))
        let none = GuestCapabilities.parse(activityHelp: "  killer-feature\n  compaction-stats", packageHelp: "")
        #expect(none == GuestCapabilities(sendTrimMemory: false, kill: false, compact: false, trimCaches: false))
    }

    @Test func protectedPackages() {
        let p = ProtectedPackages.default
        #expect(p.contains("com.google.android.gms"))
        #expect(p.contains("com.google.android.gms.persistent"))
        #expect(p.contains("com.google.android.gms:snet"))
        #expect(p.contains("com.android.vending"))
        #expect(p.contains("android.process.acore"))
        #expect(p.contains("com.android.systemui"))
        #expect(!p.contains("com.whatsapp"))
        #expect(!p.contains("com.android.chrome"))
        #expect(!p.contains("com.google.android.youtube"))
        #expect(p.adding(["com.whatsapp"]).contains("com.whatsapp"))
    }

    @Test func targetSelectionExcludesForegroundAndProtected() {
        let entries = GuestParsers.processEntries(processListFixture)
        let t = GuestEffector.selectTargets(entries, minAdj: 900, protected: .default, limit: 40)
        #expect(t.foreground == ["com.example.game", "com.example.game:render"])
        // game:bg belongs to the foreground package → excluded; gms/vending/acore protected; daemon not a package.
        #expect(t.candidates.map(\.name) == ["com.spotify.music:service", "com.whatsapp"])
        let trim = GuestEffector.selectTargets(entries, minAdj: 300, protected: .default, limit: 40)
        #expect(trim.candidates.map(\.name) == ["com.spotify.music:service", "com.whatsapp", "com.foo.backup"])
        #expect(GuestEffector.selectTargets(entries, minAdj: 300, protected: .default, limit: 1).candidates.count == 1)
    }

    @Test func trimSendsPerProcessCommandsAndMeasures() async throws {
        let shell = makeShell()
        shell.onShell(prefix: "while read -r k v u", reply: .ok("avail 500000\n@@run\n@@done\navail 520000\n"))
        let e = GuestEffector(shell: shell)
        let out = try await e.apply(.trimMemory(level: .complete, packages: []))
        #expect(out.status == .applied)
        #expect(out.reclaimedBytes == 20000 * 1024)
        let cmd = shell.shellCommands.last!
        #expect(cmd.contains("cmd activity send-trim-memory com.spotify.music:service COMPLETE"))
        #expect(cmd.contains("cmd activity send-trim-memory com.whatsapp COMPLETE"))
        #expect(cmd.contains("cmd activity send-trim-memory com.foo.backup COMPLETE"))
        #expect(!cmd.contains("com.example.game"))
        #expect(!cmd.contains("gms"))
        #expect(!cmd.contains("vending"))
    }

    @Test func explicitPackagesStillSkipForegroundAndProtected() async throws {
        let shell = makeShell()
        shell.onShell(prefix: "while read -r k v u", reply: .ok("avail 1\n@@run\n@@done\navail 1\n"))
        let e = GuestEffector(shell: shell)
        let out = try await e.apply(.killBackground(packages: ["com.example.game", "com.android.vending", "com.whatsapp"]))
        #expect(out.status == .applied)
        let cmd = shell.shellCommands.last!
        #expect(cmd.contains("cmd activity kill com.whatsapp"))
        #expect(!cmd.contains("kill com.example.game"))
        #expect(!cmd.contains("kill com.android.vending"))
        #expect(!cmd.contains("kill-all"))
    }

    @Test func killTargetsOnlyCachedPackages() async throws {
        let shell = makeShell()
        shell.onShell(prefix: "while read -r k v u", reply: .ok("avail 100\n@@run\n@@done\navail 50\n"))
        let out = try await GuestEffector(shell: shell).killBackground(packages: [])
        #expect(out.status == .applied)
        #expect(out.reclaimedBytes == 0)
        let cmd = shell.shellCommands.last!
        #expect(cmd.contains("cmd activity kill com.spotify.music; cmd activity kill com.whatsapp"))
        #expect(!cmd.contains("com.foo.backup")) // adj 300 is not cached
    }

    @Test func noopWhenNothingToTarget() async throws {
        let shell = FakeDeviceShell()
        shell.onShell("cmd activity help 2>&1", reply: .ok(activityHelpFixture))
        shell.onShell("cmd package help 2>&1", reply: .ok(packageHelpFixture))
        shell.onShell(prefix: "for d in /proc/[0-9]*", reply: .ok("0 com.example.game\n910 com.google.android.gms\n"))
        let e = GuestEffector(shell: shell)
        #expect(try await e.apply(.killBackground(packages: [])).status == .noop)
        #expect(try await e.apply(.trimMemory(level: .background, packages: [])).status == .noop)
    }

    @Test func unsupportedWhenCommandMissing() async throws {
        let shell = FakeDeviceShell()
        shell.onShell("cmd activity help 2>&1", reply: .ok("Activity manager (activity) commands:\n  help\n"))
        shell.onShell("cmd package help 2>&1", reply: .ok(""))
        let e = GuestEffector(shell: shell)
        #expect(try await e.apply(.trimMemory(level: .background, packages: [])).status == .unsupported)
        #expect(try await e.apply(.killBackground(packages: [])).status == .unsupported)
        #expect(try await e.apply(.trimCaches(desiredFreeBytes: 1)).status == .unsupported)
        #expect(try await e.compactSystem().status == .unsupported)
        #expect(try await e.apply(.freeze).status == .unsupported)
        #expect(!e.handles(.freeze))
        // Capabilities are probed once.
        #expect(shell.shellCommands.filter { $0.hasPrefix("cmd activity help") }.count == 1)
    }

    @Test func probeFailureThrowsInsteadOfUnsupported() async throws {
        let shell = FakeDeviceShell()
        shell.onShell(prefix: "cmd ", reply: .fail(1, "adb: device 'emulator-5580' not found"))
        let e = GuestEffector(shell: shell)
        await #expect(throws: EmuuError.self) { try await e.apply(.trimMemory(level: .background, packages: [])) }
        let empty = FakeDeviceShell()
        empty.onShell(prefix: "cmd ", reply: .ok(""))
        await #expect(throws: EmuuError.deviceNotReady(empty.serial)) { try await GuestEffector(shell: empty).capabilities() }
        // Once the device answers properly, the probe succeeds (it was not cached as unsupported).
        shell.onShell("cmd activity help 2>&1", reply: .ok(activityHelpFixture))
        shell.onShell("cmd package help 2>&1", reply: .ok(packageHelpFixture))
        #expect(try await e.capabilities().sendTrimMemory)
    }

    @Test func trimCachesAndCompact() async throws {
        let shell = makeShell()
        shell.onShell("cmd package trim-caches 2147483648 2>&1", reply: .ok(""))
        shell.onShell(prefix: "while read -r k v u", reply: .ok("avail 100\n@@run\n@@done\navail 300\n"))
        let e = GuestEffector(shell: shell)
        #expect(try await e.apply(.trimCaches(desiredFreeBytes: 2 * gib)).status == .applied)
        let c = try await e.compactSystem()
        #expect(c.status == .applied)
        #expect(c.reclaimedBytes == 200 * 1024)
        #expect(shell.shellCommands.last!.contains("cmd activity compact system"))
    }

    @Test func trimCachesSecurityExceptionIsUnsupported() async throws {
        let shell = makeShell()
        shell.onShell("cmd package trim-caches 1 2>&1", reply: .output(exitCode: 255, stdout: "Exception occurred while executing 'trim-caches':\njava.lang.SecurityException: denied", stderr: ""))
        #expect(try await GuestEffector(shell: shell).trimCaches(desiredFreeBytes: 1).status == .unsupported)
    }

    @Test func rejectedTrimsAreCountedOncePerProcess() async throws {
        let shell = makeShell()
        let failure = """
        Exception occurred while executing 'send-trim-memory':
        java.lang.IllegalArgumentException: Unknown process: com.whatsapp
        	at com.android.server.am.ActivityManagerService.setProcessMemoryTrimLevel(ActivityManagerService.java:3202)
        """
        shell.onShell(prefix: "while read -r k v u", reply: .output(exitCode: 0, stdout: "avail 1\n@@run\n@@done\navail 1\n", stderr: failure))
        let out = try await GuestEffector(shell: shell).trim(level: .background, packages: [])
        #expect(out.status == .applied)
        #expect(out.detail.contains("2/3"))
        #expect(GuestEffector.errorLines(failure) == ["java.lang.IllegalArgumentException: Unknown process: com.whatsapp"])
        #expect(GuestEffector.errorLines(failure + "\n" + failure + "\n" + failure).count == 3)
    }

    @Test func measuredParsing() {
        #expect(GuestCommands.freedBytes(fromMeasured: "avail 10\n@@run\nx\n@@done\navail 15") == 5 * 1024)
        #expect(GuestCommands.freedBytes(fromMeasured: "nothing") == nil)
        #expect(GuestCommands.body(fromMeasured: "avail 10\n@@run\nhello\n@@done\navail 15") == "hello")
        #expect(GuestCommands.trim(processes: ["a.b", "c'd"], level: .background) == "cmd activity send-trim-memory a.b BACKGROUND; cmd activity send-trim-memory 'c'\\''d' BACKGROUND")
    }
}

@Suite struct EngineEffectorTests {
    @Test func mapsEngineCalls() async throws {
        let engine = FakeEngineControl(instanceID: testID)
        let e = EngineEffector(engine: engine)
        #expect(try await e.apply(.reclaimGuestMemory(targetBytes: nil)).status == .unsupported)
        engine.reclaimOutcome = .reclaimed(bytes: 123, detail: "balloon")
        let r = try await e.apply(.reclaimGuestMemory(targetBytes: 5))
        #expect(r.status == .applied && r.reclaimedBytes == 123)
        #expect(try await e.apply(.thaw).status == .noop)
        #expect(try await e.apply(.freeze).status == .applied)
        #expect(try await e.apply(.freeze).status == .noop)
        #expect(try await e.apply(.thaw).status == .applied)
        #expect(try await e.apply(.hibernate).status == .applied)
        #expect(try await e.apply(.hibernate).status == .noop)
        #expect(try await e.apply(.resume).status == .applied)
        #expect(engine.calls == ["reclaim(max)", "reclaim(5)", "freeze", "thaw", "hibernate", "resume"])
        #expect(try await e.apply(.killBackground(packages: [])).status == .unsupported)
    }

    @Test func propagatesEngineErrors() async {
        let engine = FakeEngineControl(instanceID: testID)
        engine.failNext(.freeze, with: .console("KO"))
        await #expect(throws: EmuuError.console("KO")) { try await EngineEffector(engine: engine).apply(.freeze) }
    }

    @Test func routerAndMaintenanceRunner() async throws {
        let shell = FakeDeviceShell()
        shell.onShell("cmd activity help 2>&1", reply: .ok(activityHelpFixture))
        shell.onShell("cmd package help 2>&1", reply: .ok(packageHelpFixture))
        shell.onShell(prefix: "for d in /proc/[0-9]*", reply: .ok(processListFixture))
        shell.onShell(prefix: "while read -r k v u", reply: .ok("avail 100\n@@run\n@@done\navail 300\n"))
        shell.onShell(prefix: "cmd package trim-caches", reply: .error(.adb("device offline")))
        let engine = FakeEngineControl(instanceID: testID)
        let g = GuestEffector(shell: shell)
        let router = EffectorRouter([g, EngineEffector(engine: engine)])
        #expect(router.handles(.freeze) && router.handles(.trimCaches(desiredFreeBytes: 1)))
        #expect(try await router.apply(.freeze).status == .applied)
        try await engine.thaw()
        let report = await MaintenanceRunner(guest: g, engine: router).run(
            MaintenancePlan(steps: MaintenanceStep.allCases, trimCachesDesiredFreeBytes: gib, reason: "test"))
        #expect(report.steps.map(\.step) == MaintenanceStep.allCases)
        #expect(report.steps[2].error != nil)          // trim-caches failed, later steps still ran
        #expect(report.steps[3].outcome?.status == .applied)
        #expect(report.reclaimUnsupported)
        #expect(report.summary.contains("killCached: applied"))
        #expect(EffectorRouter([]).handles(.freeze) == false)
        #expect(try await EffectorRouter([]).apply(.freeze).status == .unsupported)
    }
}
