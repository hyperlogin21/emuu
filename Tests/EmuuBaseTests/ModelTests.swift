import Foundation
import Testing
@testable import EmuuBase

@Suite struct PathsTests {
    let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    @Test func defaultRootIsDotEmuu() {
        let p = EmuuPaths.default(environment: [:], home: home)
        #expect(p.root.path == "/Users/tester/.emuu")
        #expect(p.avdHome.path == "/Users/tester/.emuu/avd")
        #expect(p.logsDirectory.path == "/Users/tester/.emuu/logs")
    }

    @Test func emuuHomeOverride() {
        let p = EmuuPaths.default(environment: ["EMUU_HOME": "/tmp/x/emuu"], home: home)
        #expect(p.root.path == "/tmp/x/emuu")
        let empty = EmuuPaths.default(environment: ["EMUU_HOME": ""], home: home)
        #expect(empty.root.path == "/Users/tester/.emuu")
    }

    @Test func instanceFiles() throws {
        let p = EmuuPaths(root: URL(fileURLWithPath: "/r"))
        let id = try InstanceID(validating: "pixel")
        #expect(p.avdDirectory(for: id).path == "/r/avd/pixel.avd")
        #expect(p.avdIniFile(for: id).path == "/r/avd/pixel.ini")
        #expect(p.instanceConfigFile(for: id).path == "/r/instances/pixel.json")
        #expect(p.engineLogFile(for: id).path == "/r/logs/engine-pixel.log")
        #expect(p.pidFile(for: id).path == "/r/run/pixel.pid")
    }

    @Test func ensureDirectoriesCreatesLayout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("emuu-paths-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let p = EmuuPaths(root: root)
        try p.ensureDirectories()
        try p.ensureDirectories() // idempotent
        for dir in p.allDirectories {
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue)
        }
    }

    @Test func sdkCandidateOrderAndDedup() {
        let roots = SDKDiscovery.candidateRoots(
            environment: ["ANDROID_HOME": "/sdk/a", "ANDROID_SDK_ROOT": "/sdk/a"], home: home)
        #expect(roots.map(\.path) == ["/sdk/a", "/Users/tester/Library/Android/sdk"])
        let roots2 = SDKDiscovery.candidateRoots(environment: ["ANDROID_SDK_ROOT": "/sdk/b"], home: home)
        #expect(roots2.map(\.path) == ["/sdk/b", "/Users/tester/Library/Android/sdk"])
        #expect(SDKDiscovery.emulatorBinary(in: URL(fileURLWithPath: "/s")).path == "/s/emulator/emulator")
        #expect(SDKDiscovery.adbBinary(in: URL(fileURLWithPath: "/s")).path == "/s/platform-tools/adb")
    }
}

@Suite struct InstanceModelTests {
    @Test func instanceIDValidation() {
        #expect(InstanceID(rawValue: "Pixel_7.a-1") != nil)
        #expect(InstanceID(rawValue: "") == nil)
        #expect(InstanceID(rawValue: "-lead") == nil)
        #expect(InstanceID(rawValue: "has space") == nil)
        #expect(InstanceID(rawValue: "ü") == nil)
        #expect(InstanceID(rawValue: String(repeating: "a", count: 65)) == nil)
        #expect(throws: EmuuError.invalidInstanceID("a/b")) { try InstanceID(validating: "a/b") }
    }

    @Test func instanceIDSanitize() {
        #expect(InstanceID.sanitized(from: "My Phone!")?.rawValue == "My_Phone")
        #expect(InstanceID.sanitized(from: "  __game box  ")?.rawValue == "game_box")
        #expect(InstanceID.sanitized(from: "!!!") == nil)
    }

    @Test func instanceIDCodableRejectsInvalid() throws {
        let data = try JSONEncoder().encode(["x y"])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([InstanceID].self, from: data) }
        let ok = try JSONDecoder().decode([InstanceID].self, from: JSONEncoder().encode(["ok"]))
        #expect(ok.first?.rawValue == "ok")
    }

    @Test func configDefaultsFollowProfile() throws {
        let id = try InstanceID(validating: "a")
        let frugal = InstanceConfig(id: id, memoryProfile: .frugal)
        #expect(frugal.ramMB == 2048 && frugal.vmHeapMB == 228)
        let perf = InstanceConfig(id: id, memoryProfile: .performance)
        #expect(perf.ramMB == 4096 && perf.vmHeapMB == 512)
        let custom = InstanceConfig(id: id, memoryProfile: .frugal, ramMB: 1536)
        #expect(custom.ramMB == 1536)
        #expect(frugal.systemImage == .playStoreDefault)
        #expect(frugal.systemImage.hasPlayStore)
        #expect(frugal.displayName == "a")
        for profile in MemoryProfile.allCases {
            try InstanceConfig(id: id, memoryProfile: profile).validate()
        }
    }

    @Test func configValidationReportsAllProblems() throws {
        var c = InstanceConfig(id: try InstanceID(validating: "a"))
        c.ramMB = 512
        c.cores = 0
        c.display.density = 10
        do {
            try c.validate()
            Issue.record("expected failure")
        } catch let EmuuError.invalidConfiguration(msg) {
            #expect(msg.contains("ramMB"))
            #expect(msg.contains("cores"))
            #expect(msg.contains("density"))
        }
    }

    @Test func configCodableRoundTrip() throws {
        let c = InstanceConfig(id: try InstanceID(validating: "rt"), memoryProfile: .performance, ports: try InstancePorts(console: 5560), gpu: .swiftshaderIndirect, createdAt: Date(timeIntervalSince1970: 1000))
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let data = try enc.encode(c)
        let back = try JSONDecoder().decode(InstanceConfig.self, from: data)
        #expect(back == c)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"gpu\":\"swiftshader_indirect\""))
        #expect(json.contains("\"id\":\"rt\""))
    }

    @Test func ports() throws {
        let p = try InstancePorts(console: 5556)
        #expect(p.adb == 5557)
        #expect(p.serial.rawValue == "emulator-5556")
        #expect(p.portsArgument == "5556,5557")
        #expect(throws: EmuuError.self) { try InstancePorts(console: 5555) }
        #expect(throws: EmuuError.self) { try InstancePorts(console: 5700) }
        let bad = Data(#"{"console":5555}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(InstancePorts.self, from: bad) }
    }

    @Test func serial() {
        #expect(DeviceSerial.emulator(consolePort: 5554).consolePort == 5554)
        #expect(DeviceSerial(rawValue: "R58M123").consolePort == nil)
        #expect(DeviceSerial(rawValue: "emulator-x").consolePort == nil)
    }

    @Test func systemImageRef() {
        let ref = SystemImageRef.playStoreDefault
        #expect(ref.sdkRelativePath == "system-images/android-36.1/google_apis_playstore/arm64-v8a/")
        #expect(ref.sdkManagerPackage == "system-images;android-36.1;google_apis_playstore;arm64-v8a")
        #expect(!SystemImageRef(apiDirectory: "android-36", tag: "google_apis", abi: "arm64-v8a").hasPlayStore)
    }

    @Test func instanceStateCodableAndFlags() throws {
        let states: [InstanceState] = [.stopped, .booting, .running, .frozen, .hibernating, .hibernated, .stopping, .crashed(reason: "sig 11")]
        let back = try JSONDecoder().decode([InstanceState].self, from: JSONEncoder().encode(states))
        #expect(back == states)
        #expect(InstanceState.frozen.isRunningEngine)
        #expect(!InstanceState.hibernated.isRunningEngine)
    }
}

@Suite struct VideoDecoderModeTests {
    @Test func olderConfigsFollowTheDefault() throws {
        // A config written before the setting existed has no "videoDecoder" key.
        let config = InstanceConfig(id: InstanceID(rawValue: "old")!)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as! [String: Any]
        json.removeValue(forKey: "videoDecoder")
        let decoded = try JSONDecoder().decode(InstanceConfig.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.videoDecoder == nil)
        #expect(decoded.effectiveVideoDecoder(environment: [:]) == VideoDecoderMode.resolvedDefault)
        #expect(VideoDecoderMode.resolvedDefault != .auto)
    }

    @Test func settingRoundTripsAndEnvironmentOverrides() throws {
        var config = InstanceConfig(id: InstanceID(rawValue: "vd")!)
        config.videoDecoder = .hardware
        let back = try JSONDecoder().decode(InstanceConfig.self, from: JSONEncoder().encode(config))
        #expect(back.videoDecoder == .hardware)
        #expect(back.effectiveVideoDecoder(environment: [:]) == .hardware)
        #expect(back.effectiveVideoDecoder(environment: ["EMUU_VIDEO_DECODER": "software"]) == .software)
        #expect(back.effectiveVideoDecoder(environment: ["EMUU_VIDEO_DECODER": "auto"]) == VideoDecoderMode.resolvedDefault)
        // Empty or unknown values are ignored.
        #expect(back.effectiveVideoDecoder(environment: ["EMUU_VIDEO_DECODER": ""]) == .hardware)
        #expect(back.effectiveVideoDecoder(environment: ["EMUU_VIDEO_DECODER": "bogus"]) == .hardware)
    }

    @Test func argumentsAndAliases() {
        #expect(VideoDecoderMode(argument: "host-software") == .hostSoftware)
        #expect(VideoDecoderMode(argument: "Hardware") == .hardware)
        #expect(VideoDecoderMode(argument: "host") == .hardware)
        #expect(VideoDecoderMode(argument: "guest") == .software)
        #expect(VideoDecoderMode(argument: "nope") == nil)
        #expect(VideoDecoderMode.software.usesHostCodecs == false)
        #expect(VideoDecoderMode.hardware.usesHostCodecs && VideoDecoderMode.hostSoftware.usesHostCodecs)
        #expect(VideoDecoderMode.auto.resolved == VideoDecoderMode.resolvedDefault)
    }
}

@Suite struct MemoryModelTests {
    @Test func pressureOrdering() {
        #expect(MemoryPressureLevel.normal < .elevated)
        #expect(MemoryPressureLevel.allCases.max() == .critical)
        #expect(GovernorTier.trim < .hibernate)
    }

    @Test func actionTiers() {
        #expect(GovernorAction.trimMemory(level: .background, packages: []).tier == .trim)
        #expect(GovernorAction.trimCaches(desiredFreeBytes: 1).tier == .trim)
        #expect(GovernorAction.killBackground(packages: []).tier == .killBackground)
        #expect(GovernorAction.reclaimGuestMemory(targetBytes: nil).tier == .reclaim)
        #expect(GovernorAction.freeze.tier == .freeze)
        #expect(GovernorAction.hibernate.tier == .hibernate)
        #expect(GovernorAction.thaw.isReversal && GovernorAction.resume.isReversal)
        #expect(!GovernorAction.freeze.isReversal)
        #expect(GovernorAction.reclaimGuestMemory(targetBytes: ByteCount.mib(512)).description == "reclaimGuestMemory(512 MiB)")
    }

    @Test func guestMemoryDerived() {
        let g = GuestMemory(totalBytes: 4000, freeBytes: 500, availableBytes: 1000, swapTotalBytes: 100, swapFreeBytes: 30)
        #expect(g.availableFraction == 0.25)
        #expect(g.usedBytes == 3000)
        #expect(g.swapUsedBytes == 70)
        #expect(GuestMemory(totalBytes: 0, freeBytes: 0, availableBytes: 0).availableFraction == 0)
    }

    @Test func eventCodableRoundTrip() throws {
        let id = try InstanceID(validating: "ev")
        let sample = MemorySample(instanceID: id, timestamp: Date(timeIntervalSince1970: 5), monotonic: .seconds(5),
                                  guest: GuestMemory(totalBytes: 10, freeBytes: 1, availableBytes: 2,
                                                     pressureStall: PressureStall(someAvg10: 1, someAvg60: 2, someAvg300: 3, fullAvg10: 0, fullAvg60: 0, fullAvg300: 0),
                                                     apps: [AppMemoryUsage(packageName: "p", pssBytes: 9)]),
                                  host: HostMemory(engineFootprintBytes: 99, systemPressure: .high))
        let events = [
            GovernorEvent(instanceID: id, timestamp: Date(timeIntervalSince1970: 1), kind: .sampled(sample)),
            GovernorEvent(instanceID: id, timestamp: Date(timeIntervalSince1970: 2), kind: .actionApplied(.freeze, .applied("ok", reclaimedBytes: 3))),
            GovernorEvent(instanceID: id, timestamp: Date(timeIntervalSince1970: 3), kind: .creepDetected(bytesPerHour: -5, window: .hours(2))),
            GovernorEvent(instanceID: id, timestamp: Date(timeIntervalSince1970: 4), kind: .tierChanged(from: .none, to: .trim, reason: "r")),
        ]
        let back = try JSONDecoder().decode([GovernorEvent].self, from: JSONEncoder().encode(events))
        #expect(back == events)
    }

    @Test func ringBufferSinkIsBounded() throws {
        let id = try InstanceID(validating: "r")
        let sink = RingBufferEventSink(capacity: 3)
        for i in 0..<10 {
            sink.record(GovernorEvent(instanceID: id, timestamp: Date(timeIntervalSince1970: Double(i)), kind: .maintenanceRan(summary: "\(i)")))
        }
        #expect(sink.events.count == 3)
        #expect(sink.events.first?.timestamp == Date(timeIntervalSince1970: 7))
    }

    @Test func byteFormatting() {
        #expect(ByteCount.format(512) == "512 B")
        #expect(ByteCount.format(ByteCount.mib(300)) == "300 MiB")
        #expect(ByteCount.format(ByteCount.gib + ByteCount.gib / 2) == "1.50 GiB")
        #expect(ByteCount.format(signed: -Int64(ByteCount.mib(2))) == "-2 MiB")
        #expect(Duration.fromTimeInterval(1.5).timeInterval == 1.5)
    }
}

@Suite struct PackageModelTests {
    @Test func detectSource() {
        #expect(InstallSource.detect(fileURL: URL(fileURLWithPath: "/a/b.APK")) == .apk(URL(fileURLWithPath: "/a/b.APK")))
        #expect(InstallSource.detect(fileURL: URL(fileURLWithPath: "/a/b.xapk")) == .xapk(URL(fileURLWithPath: "/a/b.xapk")))
        #expect(InstallSource.detect(fileURL: URL(fileURLWithPath: "/a/b.apks")) == .apks(URL(fileURLWithPath: "/a/b.apks")))
        #expect(InstallSource.detect(fileURL: URL(fileURLWithPath: "/a/b.apkm")) == .apkm(URL(fileURLWithPath: "/a/b.apkm")))
        #expect(InstallSource.detect(fileURL: URL(fileURLWithPath: "/a/b.zip")) == nil)
    }

    @Test func installResult() {
        let ok = InstallResult(source: .playStore(packageName: "x"), packageName: "x", status: .openedInPlayStore)
        #expect(ok.succeeded)
        let bad = InstallResult(source: .apk(URL(fileURLWithPath: "/a.apk")), packageName: nil, status: .failed(code: "INSTALL_FAILED_NO_MATCHING_ABIS", message: "m"))
        #expect(!bad.succeeded)
        #expect(PackageInfo(packageName: "g", installerPackage: "com.android.vending").isFromPlayStore)
    }

    @Test func errorDescriptions() {
        #expect(EmuuError.processFailed(command: "adb", exitCode: 1, stderr: " boom \n").localizedDescription == "adb exited with status 1: boom")
        #expect(EmuuError.instanceNotFound(InstanceID(rawValue: "z")!).localizedDescription == "Instance 'z' not found.")
    }

    @Test func shellQuoting() {
        #expect(DeviceShellQuoting.quote("com.example.app") == "com.example.app")
        #expect(DeviceShellQuoting.quote("a b") == "'a b'")
        #expect(DeviceShellQuoting.quote("it's") == "'it'\\''s'")
        #expect(DeviceShellQuoting.quote("") == "''")
        #expect(DeviceShellQuoting.quote("$(reboot)") == "'$(reboot)'")
        #expect(DeviceShellQuoting.join(["am", "start", "-d", "market://details?id=x"]) == "am start -d 'market://details?id=x'")
    }
}
