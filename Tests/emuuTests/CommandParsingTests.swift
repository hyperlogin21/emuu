import Foundation
import Testing
import ArgumentParser
import EmuuBase
import EmuuMemory
@testable import emuu

@Suite struct CommandParsingTests {
    @Test func startParsesModesAndProfiles() throws {
        let cmd = try EmuuCLI.parseAsRoot(["start", "pixel", "--window", "--profile", "lite", "--cold-boot"])
        let start = try #require(cmd as? Start)
        #expect(start.target.explicit == "pixel")
        #expect(start.window)
        #expect(start.profile == .lite)
        #expect(start.coldBoot)
        #expect(!start.detach)
    }

    @Test func startRejectsConflictingFlags() {
        #expect(throws: (any Error).self) { try EmuuCLI.parseAsRoot(["start", "x", "--headless", "--window"]) }
        #expect(throws: (any Error).self) { try EmuuCLI.parseAsRoot(["start", "x", "--window", "--detach"]) }
        #expect(throws: (any Error).self) { try EmuuCLI.parseAsRoot(["start", "x", "--idle-freeze", "0"]) }
        #expect(throws: (any Error).self) { try EmuuCLI.parseAsRoot(["start", "x", "--profile", "turbo"]) }
    }

    @Test func detachedChildGetsTheSameChoices() throws {
        let parent = try #require(try EmuuCLI.parseAsRoot(
            ["start", "-i", "pixel", "--detach", "--profile", "performance", "--no-governor", "--idle-freeze", "7", "--quiet", "--boot-timeout", "120"]) as? Start)
        let id = try InstanceID(validating: "pixel")
        let childArgs = parent.childArguments(id: id)
        #expect(!childArgs.contains("--detach"))
        let child = try #require(try EmuuCLI.parseAsRoot(childArgs) as? Start)
        #expect(child.superviseChild)
        #expect(child.target.explicit == "pixel")
        #expect(child.profile == .performance)
        #expect(child.noGovernor)
        #expect(child.idleFreeze == 7)
        #expect(child.quiet)
        #expect(child.bootTimeout == 120)
    }

    @Test func supervisorOptionsFollowFlagsAndInstance() throws {
        let start = try #require(try EmuuCLI.parseAsRoot(["start", "x", "--idle-freeze", "3"]) as? Start)
        let config = InstancePresetFixtures.config("x", profile: .performance, ramMB: 3072)
        let paths = EmuuPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("emuu-none-\(UUID())"))
        let o = start.supervisorOptions(for: config, paths: paths)
        #expect(o.mode == .headless)
        #expect(o.governorEnabled)
        #expect(o.governor.profile == .performance)   // instance profile when --profile is absent
        #expect(o.governor.guestRAMMB == 3072)
        #expect(o.governor.idleFreezeAfter == .minutes(3))
        #expect(o.launch.bootTimeout == .seconds(600))
    }

    @Test func memDefaultsToWatchAndTrimTakesLevels() throws {
        #expect(try EmuuCLI.parseAsRoot(["mem"]) is MemWatch)
        #expect(try EmuuCLI.parseAsRoot(["mem", "--json", "--once"]) is MemWatch)
        let trim = try #require(try EmuuCLI.parseAsRoot(["mem", "trim", "--level", "background", "--kill", "--caches-gb", "2"]) as? MemTrim)
        #expect(trim.level == .background)
        #expect(trim.kill)
        #expect(trim.cachesGb == 2)
        #expect(throws: (any Error).self) { try EmuuCLI.parseAsRoot(["mem", "trim", "--level", "SOMETIMES"]) }
        #expect(try EmuuCLI.parseAsRoot(["mem", "reclaim", "pixel"]) is MemReclaim)
    }

    @Test func shellPassesCommandThrough() throws {
        let shell = try #require(try EmuuCLI.parseAsRoot(["shell", "-i", "pixel", "--", "ls", "-l", "/sdcard"]) as? Shell)
        #expect(shell.target.instance == "pixel")
        #expect(Array(shell.command.drop { $0 == "--" }) == ["ls", "-l", "/sdcard"])
    }

    @Test func installAndLogsAndAliases() throws {
        let install = try #require(try EmuuCLI.parseAsRoot(["install", "a.apk", "b.xapk", "--split", "-i", "p"]) as? Install)
        #expect(install.paths == ["a.apk", "b.xapk"])
        #expect(install.split)
        let logs = try #require(try EmuuCLI.parseAsRoot(["logs", "p", "--supervisor", "-f", "-n", "5"]) as? Logs)
        #expect(logs.source == .supervisor)
        #expect(logs.follow)
        #expect(logs.lines == 5)
        #expect(try EmuuCLI.parseAsRoot(["ls"]) is List)
        #expect(try EmuuCLI.parseAsRoot(["rm", "p", "-y"]) is Delete)
    }

    @Test func createBuildsValidatedConfig() throws {
        let create = try #require(try EmuuCLI.parseAsRoot(
            ["create", "big", "--preset", "gaming", "--ram", "4096", "--cores", "6", "--screen", "1080x2400@420", "--gpu", "swiftshader_indirect", "--no-audio", "--port", "5580"]) as? Create)
        let config = try create.makeConfig(id: try InstanceID(validating: "big"), image: .playStoreDefault)
        #expect(config.ramMB == 4096)
        #expect(config.cores == 6)
        #expect(config.display == DisplaySpec(width: 1080, height: 2400, density: 420))
        #expect(config.gpu == .swiftshaderIndirect)
        #expect(!config.audioOutput)
        #expect(config.ports?.console == 5580)
        #expect(config.memoryProfile == .performance)

        let bad = try #require(try EmuuCLI.parseAsRoot(["create", "x", "--ram", "100"]) as? Create)
        #expect(throws: (any Error).self) { try bad.makeConfig(id: try InstanceID(validating: "x"), image: .playStoreDefault) }
        #expect(throws: (any Error).self) { try Create.parseScreen("720by1600") }
        #expect(throws: (any Error).self) {
            let c = try #require(try EmuuCLI.parseAsRoot(["create", "x", "--port", "5555"]) as? Create)
            _ = try c.makeConfig(id: try InstanceID(validating: "x"), image: .playStoreDefault)
        }
    }

    @Test func benchValidatesArguments() {
        #expect(throws: (any Error).self) { try EmuuCLI.parseAsRoot(["bench", "--minutes", "0"]) }
        #expect(throws: (any Error).self) { try EmuuCLI.parseAsRoot(["bench", "--sample-every", "0"]) }
    }
}

enum InstancePresetFixtures {
    static func config(_ name: String, profile: MemoryProfile = .balanced, ramMB: Int = 2048) -> InstanceConfig {
        InstanceConfig(id: InstanceID(rawValue: name)!, displayName: name, systemImage: .playStoreDefault, memoryProfile: profile,
                       ramMB: ramMB, cores: 4, vmHeapMB: 256, display: .lightweightPhone, dataPartitionMB: 6144,
                       ports: nil, gpu: .host, audioOutput: true, createdAt: Date(timeIntervalSince1970: 0))
    }
}
