import Foundation
import Testing
import EmuuBase
import EmuuTestSupport
@testable import EmuuMemory

@Suite struct HostSamplerTests {
    @Test func ownProcessStats() throws {
        let stats = try #require(HostSampler.processTreeStats(root: getpid()))
        #expect(stats.footprintBytes > 1 * mib)
        #expect(stats.lifetimeMaxFootprintBytes >= stats.footprintBytes / 2)
        #expect(stats.residentBytes > 0)
        #expect(stats.cpuSeconds > 0)
        #expect(stats.processCount >= 1)
    }

    @Test func missingPIDGivesSystemOnly() {
        let s = HostSampler().sample(enginePID: 999_999)
        #expect(s.engine == nil)
        #expect(s.system.physicalBytes > 1 * gib)
        #expect(HostSampler().sample(enginePID: nil).engine == nil)
    }

    @Test func systemStatsAreSane() {
        let s = HostSampler.systemStats()
        #expect(s.physicalBytes == ProcessInfo.processInfo.physicalMemory)
        #expect(s.freeBytes > 0)
        #expect(s.freeBytes < s.physicalBytes)
        #expect(s.kernelPressureLevel != nil)
        #expect([1, 2, 4].contains(s.kernelPressureLevel!))
        #expect(HostSampler.pressureLevel(kernelLevel: 4) == .critical)
        #expect(HostSampler.pressureLevel(kernelLevel: 2) == .high)
        #expect(HostSampler.pressureLevel(kernelLevel: nil) == .normal)
    }

    @Test func pressureHintRaisesLevel() {
        let s = HostSampler(pressureHint: { .critical }).sample(enginePID: nil)
        #expect(s.system.pressure == .critical)
        #expect(s.hostMemory.systemPressure == .critical)
    }

    @Test func processTreeIncludesChildrenAndCPUPercent() async throws {
        // /bin/sh spawns a child `sleep`; the tree must count both.
        let runner = SystemProcessRunner()
        let proc = try await runner.spawn(ProcessRequest(executable: URL(fileURLWithPath: "/bin/sh"),
                                                         arguments: ["-c", "sleep 30 & wait"]))
        defer { proc.kill() }
        var tree: EngineProcessStats?
        for _ in 0..<50 {
            tree = HostSampler.processTreeStats(root: proc.pid)
            if (tree?.processCount ?? 0) >= 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(tree?.processCount == 2)
        #expect(HostSampler.childPIDs(of: proc.pid).count == 1)
        let clock = FakeClock()
        let sampler = HostSampler(clock: clock)
        #expect(sampler.sample(enginePID: proc.pid).engine?.cpuPercent == nil)
        clock.advance(by: .seconds(1))
        let second = sampler.sample(enginePID: proc.pid).engine
        #expect(second?.cpuPercent != nil)
        #expect((second?.cpuPercent ?? 100) < 50)
        for c in HostSampler.childPIDs(of: proc.pid) { kill(c, SIGKILL) }
    }
}

@Suite struct CSVLogTests {
    @Test func writesHeaderAndRotates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("emuu-csv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = SampleCSVLog(url: dir.appendingPathComponent("mem.csv"), maxBytes: 2048, maxFiles: 3)
        var p = HistoryPoint(timestamp: Date(timeIntervalSince1970: 1_800_000_000), monotonic: .seconds(12), level: .elevated, tier: .trim)
        p.guestAvailableBytes = 512 * mib
        p.engineFootprintBytes = 3 * gib
        p.sampleRoundTrip = .milliseconds(45)
        for _ in 0..<200 { try log.append(p) }
        log.close()
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(files == ["mem.1.csv", "mem.2.csv", "mem.csv"])
        for f in files {
            let size = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(f).path)[.size] as! UInt64
            #expect(size <= 2048 + 256)
            let text = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
            #expect(text.hasPrefix(HistoryPoint.csvHeader))
        }
        let row = p.csvRow.split(separator: ",", omittingEmptySubsequences: false)
        #expect(row.count == HistoryPoint.csvHeader.split(separator: ",").count)
        #expect(row[2] == "elevated")
        #expect(row[5] == "512.0")
        #expect(row[9] == "3072.0")
        #expect(row.last == "45")
    }
}
