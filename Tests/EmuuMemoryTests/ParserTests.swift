import Foundation
import Testing
import EmuuBase
import EmuuTestSupport
@testable import EmuuMemory

/// Real output captured from emulator-5580 (android-36.1 google_apis_playstore arm64, kernel 6.12),
/// trimmed: as the shell uid, /proc/pressure/memory is *not readable* (Permission denied), so the
/// psi section is empty.
let deviceSampleFixture = """
@@meminfo
MemTotal:        2017768 kB
MemFree:           67980 kB
MemAvailable:     768448 kB
Buffers:            3636 kB
Cached:           826540 kB
SwapCached:         9964 kB
Active:           460964 kB
SwapTotal:       1513320 kB
SwapFree:         836336 kB
Committed_AS:   152882836 kB
VmallocTotal:   261087232 kB
CmaTotal:          16384 kB
@@psi
@@vmstat
workingset_refault_anon 263729
workingset_refault_file 1135424
pswpin 547761
pswpout 869682
allocstall_dma32 0
allocstall_normal 110
allocstall_movable 1833
pgmajfault 628390
@@procs
fg com.google.android.apps.nexuslauncher
cached 30
@@end
"""

@Suite struct GuestParserTests {
    @Test func meminfoParsesKilobytesAndSkipsJunk() {
        let m = GuestParsers.meminfo("MemTotal:  2017768 kB\ngarbage line\nHugePages_Total:       0\nBad: x kB\n\nMemAvailable: 10 kB")
        #expect(m["MemTotal"] == 2017768 * 1024)
        #expect(m["HugePages_Total"] == 0)
        #expect(m["Bad"] == nil)
        #expect(m["MemAvailable"] == 10240)
    }

    @Test func guestMemoryFallsBackWithoutMemAvailable() {
        let g = GuestParsers.guestMemory(meminfo: ["MemTotal": 1000, "MemFree": 100, "Cached": 200, "Buffers": 50])
        #expect(g?.availableBytes == 350)
        #expect(GuestParsers.guestMemory(meminfo: ["MemFree": 1]) == nil)
    }

    @Test func pressureStallParsesBothLines() throws {
        let psi = try #require(GuestParsers.pressureStall("""
        some avg10=1.25 avg60=0.50 avg300=0.10 total=12345
        full avg10=0.30 avg60=0.20 avg300=0.00 total=99
        """))
        #expect(psi.someAvg10 == 1.25)
        #expect(psi.someAvg300 == 0.10)
        #expect(psi.fullAvg10 == 0.30)
    }

    @Test func pressureStallToleratesMissingOrDenied() {
        #expect(GuestParsers.pressureStall("") == nil)
        #expect(GuestParsers.pressureStall("cat: /proc/pressure/memory: Permission denied") == nil)
        let onlySome = GuestParsers.pressureStall("some avg10=3.00 avg60=2.00 avg300=1.00 total=1")
        #expect(onlySome?.someAvg10 == 3)
        #expect(onlySome?.fullAvg10 == 0)
    }

    @Test func vmstatSkipsNonNumeric() {
        let v = GuestParsers.vmstat("pgmajfault 12\nnr_free_pages abc\nweird\npswpin 3")
        #expect(v == ["pgmajfault": 12, "pswpin": 3])
    }

    @Test func processScanAndPackageNames() {
        let s = GuestParsers.processScan("fg com.game.x\nfg com.game.x\nfg  \ncached 7\n")
        #expect(s.foreground == ["com.game.x"])
        #expect(s.cachedCount == 7)
        #expect(GuestParsers.packageName(fromProcessName: "com.foo.bar:remote") == "com.foo.bar")
        #expect(GuestParsers.packageName(fromProcessName: "/system/bin/surfaceflinger") == nil)
        #expect(GuestParsers.packageName(fromProcessName: "zygote64") == nil)
        #expect(GuestParsers.packageName(fromProcessName: "[kworker/0:1]") == nil)
    }

    @Test func processEntries() {
        let e = GuestParsers.processEntries("905 com.a\n0 com.launcher\nbad\n-800 system_server\n910 com.b:svc\r\n")
        #expect(e.map(\.adj) == [905, 0, -800, 910])
        #expect(e.last?.name == "com.b:svc")
    }

    @Test func dumpsysCompact() {
        let text = """
        time,123,456
        proc,fore,com.game.x,1234,250000,N/A,e
        proc,cch,com.old.app,555,40000,N/A,e
        proc,native,surfaceflinger,99,30000,N/A,e
        oom,fore,250000
        """
        let apps = GuestParsers.dumpsysMeminfoCompact(text)
        #expect(apps.count == 3)
        #expect(apps[0].packageName == "com.game.x")
        #expect(apps[0].isForeground)
        #expect(apps[0].pssBytes == 250000 * 1024)
        #expect(apps[1].isForeground == false)
    }

    @Test func sectionsHandleCRLF() {
        let s = GuestParsers.sections("junk\r\n@@a\r\n1\r\n2\r\n@@b\r\n@@c\r\nx")
        #expect(s["a"] == "1\n2")
        #expect(s["b"] == "")
        #expect(s["c"] == "x")
        #expect(s["junk"] == nil)
    }

    @Test func parseRealDeviceSample() throws {
        let snap = try GuestSampler.parse(deviceSampleFixture)
        #expect(snap.memory.totalBytes == 2017768 * 1024)
        #expect(snap.memory.availableBytes == 768448 * 1024)
        #expect(snap.memory.swapUsedBytes == (1513320 - 836336) * 1024)
        #expect(snap.memory.pressureStall == nil)
        #expect(snap.memory.cachedProcessCount == 30)
        #expect(snap.foregroundPackages == ["com.google.android.apps.nexuslauncher"])
        #expect(snap.vmCounters["pgmajfault"] == 628390)
        #expect(abs(snap.memory.availableFraction - 0.3808) < 0.001)
    }

    @Test func parseThrowsWithoutMeminfo() {
        #expect(throws: EmuuError.processFailed(command: "adb shell <guest sample>", exitCode: 1, stderr: "error: device offline")) {
            try GuestSampler.parse("", exitCode: 1, stderr: "error: device offline")
        }
        #expect(throws: EmuuError.self) { try GuestSampler.parse("garbage", exitCode: 0) }
    }

    @Test func vmRates() throws {
        let a: [String: UInt64] = ["pgmajfault": 100, "pswpout": 10, "workingset_refault_anon": 5, "workingset_refault_file": 5]
        let b: [String: UInt64] = ["pgmajfault": 200, "pswpout": 30, "workingset_refault_anon": 15, "workingset_refault_file": 25]
        let r = try #require(GuestSampler.rates(from: a, to: b, seconds: 10))
        #expect(r.majorFaultsPerSec == 10)
        #expect(r.swapOutPagesPerSec == 2)
        #expect(r.refaultsPerSec == 3)
        // Counter reset (guest reboot) → nil.
        #expect(GuestSampler.rates(from: b, to: a, seconds: 10) == nil)
        #expect(GuestSampler.rates(from: a, to: b, seconds: 0) == nil)
    }

    @Test func samplerUsesOneShellCallAndComputesRates() async throws {
        let shell = FakeDeviceShell(serial: .emulator(consolePort: 5580))
        let second = deviceSampleFixture.replacingOccurrences(of: "pgmajfault 628390", with: "pgmajfault 628490")
        shell.onShell(prefix: "echo @@meminfo", reply: .ok(deviceSampleFixture), .ok(second))
        let clock = FakeClock()
        let sampler = GuestSampler(shell: shell, clock: clock)
        let s1 = try await sampler.sample()
        #expect(s1.vmRates == nil)
        clock.advance(by: .seconds(10))
        let s2 = try await sampler.sample()
        #expect(s2.vmRates?.majorFaultsPerSec == 10)
        #expect(shell.shellCommands.count == 2)
        #expect(shell.shellCommands[0] == GuestSampler.combinedCommand)
        #expect(!GuestSampler.combinedCommand.contains("dumpsys"))
    }

    @Test func appBreakdownUsesDumpsysOnDemand() async throws {
        let shell = FakeDeviceShell()
        shell.onShell("dumpsys meminfo -c", reply: .ok("proc,fore,com.x,1,100,N/A,e"))
        let apps = try await GuestSampler(shell: shell).appBreakdown()
        #expect(apps.first?.packageName == "com.x")
    }
}
