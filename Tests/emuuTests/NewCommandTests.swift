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

@Suite struct CameraCommandTests {
    @Test func cameraSubcommandsParse() throws {
        let set = try #require(try EmuuCLI.parseAsRoot(["camera", "set", "phone", "--back", "virtualscene", "--front", "webcam:FaceTime HD"]) as? CameraSet)
        #expect(set.instance == "phone" && set.back == .virtualScene && set.front == .webcam("FaceTime HD"))
        #expect(throws: (any Error).self) { try EmuuCLI.parseAsRoot(["camera", "set", "phone"]) }
        #expect(throws: (any Error).self) { try EmuuCLI.parseAsRoot(["camera", "set", "phone", "--front", "virtualscene"]) }
        #expect(throws: (any Error).self) { try EmuuCLI.parseAsRoot(["camera", "set", "phone", "--back", "imagefile:/x.png"]) }
        let show = try #require(try EmuuCLI.parseAsRoot(["camera", "show", "phone", "qr.png", "--json"]) as? CameraShow)
        #expect(CameraCLI.instanceAndFile(show.args)! == ("phone", "qr.png") && show.json)
        let only = try #require(try EmuuCLI.parseAsRoot(["camera", "show", "qr.png"]) as? CameraShow)
        #expect(CameraCLI.instanceAndFile(only.args)!.instance == nil)
        #expect(throws: (any Error).self) { try EmuuCLI.parseAsRoot(["camera", "show", "phone", "qr.png", "--front"]) }
        #expect(throws: (any Error).self) { try EmuuCLI.parseAsRoot(["camera", "show"]) }
        _ = try #require(try EmuuCLI.parseAsRoot(["camera", "status", "phone", "--json"]) as? CameraStatus)
        _ = try #require(try EmuuCLI.parseAsRoot(["camera", "clear", "phone"]) as? CameraClear)
        _ = try #require(try EmuuCLI.parseAsRoot(["camera", "list-host", "--json"]) as? CameraListHost)
        let aim = try #require(try EmuuCLI.parseAsRoot(["camera", "aim", "phone", "--position", "1,2.5,-3"]) as? CameraAim)
        #expect(try CameraAim.triple(aim.position!) == [1, 2.5, -3])
        #expect(throws: (any Error).self) { try EmuuCLI.parseAsRoot(["camera", "aim", "--rotation", "1,2"]) }
    }

    @Test func createCameraOptions() throws {
        let c = try #require(try EmuuCLI.parseAsRoot(["create", "phone", "--camera-back", "emulated", "--camera-front", "none"]) as? Create)
        let config = try c.makeConfig(id: InstanceID(rawValue: "phone")!, image: .playStoreDefault)
        #expect(config.camera == CameraConfig(back: .emulated, front: .none))
        let plain = try #require(try EmuuCLI.parseAsRoot(["create", "phone"]) as? Create)
        #expect(try plain.makeConfig(id: InstanceID(rawValue: "phone")!, image: .playStoreDefault).camera == .newInstanceDefault)
        let bad = try #require(try EmuuCLI.parseAsRoot(["create", "phone", "--camera-front", "virtualscene"]) as? Create)
        #expect(throws: (any Error).self) { try bad.makeConfig(id: InstanceID(rawValue: "phone")!, image: .playStoreDefault) }
    }
}
