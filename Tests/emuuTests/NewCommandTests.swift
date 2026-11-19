import Foundation
import Testing
import ArgumentParser
import EmuuBase
import EmuuMemory
@testable import emuu

@Suite struct NewCommandTests {
    @Test func recordParsesInstanceOutputAndDuration() throws {
        let r = try #require(try EmuuCLI.parseAsRoot(["record", "phone", "out.mp4", "--duration", "10"]) as? Record)
        #expect(Positionals.split(r.args)! == ("phone", "out.mp4"))
        #expect(r.duration == 10)
        let only = try #require(try EmuuCLI.parseAsRoot(["record", "out.mp4"]) as? Record)
        #expect(Positionals.split(only.args)!.instance == nil)
        #expect(throws: (any Error).self) { try EmuuCLI.parseAsRoot(["record", "a", "b", "c"]) }
        #expect(throws: (any Error).self) { try EmuuCLI.parseAsRoot(["record", "x.mp4", "--duration", "0"]) }
    }

    @Test func automationAndKeyboardSwitches() throws {
        let a = try #require(try EmuuCLI.parseAsRoot(["automation", "on", "phone"]) as? Automation)
        #expect(Switch.parse(a.args)! == ("phone", .on))
        let b = try #require(try EmuuCLI.parseAsRoot(["automation", "phone", "off"]) as? Automation)
        #expect(Switch.parse(b.args)! == ("phone", .off))
        #expect(throws: (any Error).self) { try EmuuCLI.parseAsRoot(["automation", "phone", "maybe"]) }
        let k = try #require(try EmuuCLI.parseAsRoot(["keyboard", "status"]) as? Keyboard)
        #expect(Switch.parse(k.args)! == (nil, .status))
    }

    @Test func startAutomationIsPassedToDetachedChildAndGovernor() throws {
        let s = try #require(try EmuuCLI.parseAsRoot(["start", "phone", "--detach", "--automation", "--profile", "lite"]) as? Start)
        #expect(s.automation)
        #expect(s.childArguments(id: try InstanceID(validating: "phone")).contains("--automation"))
        var o = GovernorOptions(profile: .frugal, guestRAMMB: 2048, headless: true, idleFreezeAfter: .minutes(1))
        #expect(!o.config().automationMode)
        o.automation = true
        #expect(o.config().automationMode)
    }

    @Test func statusHintAndListRAM() {
        #expect(Status.adbHint(serial: "emulator-5554") == "adb -s emulator-5554 shell")
        #expect(List.ramText(effective: 2048, configured: 2048) == "2048 MB")
        #expect(List.ramText(effective: 2048, configured: 1536) == "2048 MB (set 1536)")
    }

    @Test func automationControlRequestRoundTrips() throws {
        let data = try JSONEncoder().encode(ControlRequest(command: .automation, enabled: true))
        let back = try JSONDecoder().decode(ControlRequest.self, from: data)
        #expect(back.command == .automation && back.enabled == true)
        // Older status files without the new governor keys still decode.
        let old = #"{"enabled":true,"profile":"lite","level":"normal","tier":"none","tierNumber":0,"disabledTiers":[],"creepActive":false,"samplesTaken":1,"actionsApplied":0,"actionsFailed":0,"maintenanceRuns":0,"consecutiveGuestSampleFailures":0}"#
        let g = try JSONDecoder().decode(SupervisorStatus.Governor.self, from: Data(old.utf8))
        #expect(g.automationMode == nil)
    }

    @Test func videoDecoderCommandAndOptions() throws {
        let set = try #require(try EmuuCLI.parseAsRoot(["video-decoder", "software", "phone"]) as? VideoDecoder)
        #expect(VideoDecoder.parse(set.args)! == ("phone", .software))
        let swapped = try #require(try EmuuCLI.parseAsRoot(["video-decoder", "phone", "host-software"]) as? VideoDecoder)
        #expect(VideoDecoder.parse(swapped.args)! == ("phone", .hostSoftware))
        let status = try #require(try EmuuCLI.parseAsRoot(["video-decoder", "status"]) as? VideoDecoder)
        #expect(VideoDecoder.parse(status.args)! == (nil, nil))
        #expect(throws: (any Error).self) { try EmuuCLI.parseAsRoot(["video-decoder", "fast"]) }

        let create = try #require(try EmuuCLI.parseAsRoot(["create", "phone", "--video-decoder", "hardware"]) as? Create)
        let config = try create.makeConfig(id: InstanceID(rawValue: "phone")!, image: .playStoreDefault)
        #expect(config.videoDecoder == .hardware)
        let plain = try #require(try EmuuCLI.parseAsRoot(["create", "phone"]) as? Create)
        #expect(try plain.makeConfig(id: InstanceID(rawValue: "phone")!, image: .playStoreDefault).videoDecoder == nil)
        let start = try #require(try EmuuCLI.parseAsRoot(["start", "phone", "--video-decoder", "software"]) as? Start)
        #expect(start.videoDecoder == .software)
    }
}
