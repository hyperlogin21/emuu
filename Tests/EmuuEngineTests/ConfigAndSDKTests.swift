import Foundation
import Testing
import EmuuBase
@testable import EmuuEngine

@Suite struct IniFileTests {
    @Test func parsesBothSpacingStylesCommentsAndDuplicates() {
        let ini = IniFile(parsing: "# c\nhw.ramSize = 2048\r\n; x\n\nvm.heapSize=512\nhw.ramSize=4096\nnovalue\n=bad\n")
        #expect(ini["hw.ramSize"] == "4096")
        #expect(ini["vm.heapSize"] == "512")
        #expect(ini.keys == ["hw.ramSize", "vm.heapSize"])
    }

    @Test func setReplaceRemoveKeepOrder() {
        var ini = IniFile()
        ini["a"] = "1"; ini["b"] = "2"; ini["a"] = "3"; ini["c"] = ""
        #expect(ini.serialized() == "a=3\nb=2\nc=\n")
        ini["b"] = nil
        #expect(ini.serialized() == "a=3\nc=\n")
        #expect(IniFile(parsing: ini.serialized()) == ini)
    }
}

@Suite struct SDKLocatorTests {
    @Test func locatesSDKFromEnvironmentAndReadsVersion() throws {
        let w = try TempWorld()
        let sdk = try SDKLocator(environment: ["ANDROID_HOME": w.sdk.root.path], home: w.root).locate()
        #expect(sdk.root.standardizedFileURL == w.sdk.root.standardizedFileURL)
        #expect(sdk.emulatorVersion == "36.4.9")
        #expect(sdk.adb.lastPathComponent == "adb")
    }

    @Test func reportsSearchedRootsWhenMissing() throws {
        let w = try TempWorld()
        let bogus = w.root.appendingPathComponent("nope").path
        #expect {
            try SDKLocator(environment: ["ANDROID_HOME": bogus], home: w.root).locate()
        } throws: { error in
            guard case .sdkNotFound(let searched) = error as? EmuuError else { return false }
            return searched.contains(bogus) && searched.contains { $0.hasSuffix("Library/Android/sdk") }
        }
    }

    @Test func ranksPlayStoreArm64HighestAndParsesPackageXMLFallback() throws {
        let w = try TempWorld()
        let root = w.sdk.root
        try TempWorld.makeImage(sdkRoot: root, api: "android-35", tag: "google_apis", abi: "arm64-v8a",
                                properties: "AndroidVersion.ApiLevel=35\nPkg.Revision=9\n")
        try TempWorld.makeImage(sdkRoot: root, api: "android-36", tag: "google_apis_playstore", abi: "x86_64",
                                properties: "AndroidVersion.ApiLevel=36\n")
        try TempWorld.makeImage(sdkRoot: root, api: "android-34", tag: "default", abi: "arm64-v8a", properties: nil, packageXML: """
            <ns2:repository><license>major 99 <major>99</major></license>
            <localPackage path="system-images;android-34;default;arm64-v8a">
            <type-details><api-level>34</api-level><tag><id>default</id><display>Default Android System Image</display></tag><abi>arm64-v8a</abi></type-details>
            <revision><major>14</major></revision><display-name>ARM 64 v8a System Image</display-name>
            <dependencies><dependency path="emulator"><min-revision><major>35</major><minor>4</minor></min-revision></dependency></dependencies>
            </localPackage></ns2:repository>
            """)
        let images = SDKLocator.installedImages(in: w.sdk)
        #expect(images.map(\.ref.sdkManagerPackage) == [
            "system-images;android-36.1;google_apis_playstore;arm64-v8a",
            "system-images;android-35;google_apis;arm64-v8a",
            "system-images;android-34;default;arm64-v8a",
            "system-images;android-36;google_apis_playstore;x86_64",
        ])
        let fallback = try #require(images.first { $0.ref.apiDirectory == "android-34" })
        #expect(fallback.apiLevel == "34")
        #expect(fallback.revision == "14")
        #expect(fallback.tagDisplay == "Default Android System Image")
        #expect(SDKLocator.preferredImage(in: w.sdk)?.ref == .playStoreDefault)
        #expect(images[0].tagDisplay == "Google Play")
    }

    @Test func adviceNamesSdkmanagerPackageWhenNoPlayStoreImage() throws {
        let w = try TempWorld(withPlayStoreImage: false)
        #expect(SDKLocator.preferredImage(in: w.sdk) == nil)
        let advice = SDKLocator.missingImageAdvice(sdk: w.sdk)
        #expect(advice.contains("\"system-images;android-36.1;google_apis_playstore;arm64-v8a\""))
        #expect(advice.contains("sdkmanager"))
    }

    @Test func packageXMLMinorApiLevel() {
        let f = PackageXML.parse("<localPackage><api-level>36</api-level><minor-api-level>1</minor-api-level><revision><major>4</major><minor>1</minor><micro>0</micro></revision></localPackage>")
        #expect(f.apiLevel == "36.1")
        #expect(f.revision == "4.1.0")
    }
}

@Suite struct AVDConfigTests {
    let id = InstanceID(rawValue: "emuu-test")!

    @Test func presetsMatchSpec() {
        let std = InstancePreset.standard.makeConfig(id: id)
        #expect(std.ramMB == 2048 && std.cores == 4 && std.memoryProfile == .balanced)
        let lite = InstancePreset.lite.makeConfig(id: id)
        #expect(lite.ramMB == 1536 && lite.cores == 2 && lite.memoryProfile == .frugal)
        for p in InstancePreset.allCases { #expect(throws: Never.self) { try p.makeConfig(id: id).validate() } }
    }

    @Test func configIniIsMemoryTuned() {
        var config = InstancePreset.standard.makeConfig(id: id, displayName: "Test Phone")
        config.audioOutput = false
        let ini = AVDConfigGenerator.configIni(for: config, tagDisplay: "Google Play")
        #expect(ini["AvdId"] == "emuu-test")
        #expect(ini["avd.ini.displayname"] == "Test Phone")
        #expect(ini["PlayStore.enabled"] == "true")
        #expect(ini["hw.ramSize"] == "2048")
        #expect(ini["hw.cpu.ncore"] == "4")
        #expect(ini["hw.cpu.arch"] == "arm64")
        #expect(ini["vm.heapSize"] == "256")
        #expect(ini["disk.dataPartition.size"] == "6144M")
        #expect(ini["hw.audioInput"] == "no")
        #expect(ini["hw.audioOutput"] == "no")
        #expect(ini["hw.camera.back"] == "none" && ini["hw.camera.front"] == "none")
        #expect(ini["hw.sdCard"] == "no")
        #expect(ini["hw.sensors.light"] == "no" && ini["hw.sensors.proximity"] == "no")
        #expect(ini["hw.accelerometer"] == "yes" && ini["hw.gyroscope"] == "yes")
        #expect(ini["hw.lcd.width"] == "720" && ini["hw.lcd.height"] == "1600" && ini["hw.lcd.density"] == "320")
        #expect(ini["hw.gpu.mode"] == "host")
        #expect(ini["image.sysdir.1"] == "system-images/android-36.1/google_apis_playstore/arm64-v8a/")
        #expect(ini["tag.id"] == "google_apis_playstore")
        #expect(ini["fastboot.forceFastBoot"] == "yes" && ini["fastboot.forceColdBoot"] == "no")
    }

    @Test func everyHardwareKeyExistsInEngineHardwareProperties() throws {
        // The real engine's list of hardware keys; skipped where the SDK is absent.
        guard let sdk = try? SDKLocator().locate() else { return }
        let text = try String(contentsOf: sdk.root.appendingPathComponent("emulator/lib/hardware-properties.ini"), encoding: .utf8)
        let known = Set(text.split(separator: "\n").compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("name") , let eq = t.firstIndex(of: "=") else { return nil }
            return t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        })
        // Metadata keys avdmanager writes that are not hardware properties.
        let metadata: Set<String> = ["avd.ini.encoding", "AvdId", "avd.ini.displayname", "abi.type", "image.sysdir.1",
                                     "tag.id", "tag.ids", "tag.display", "tag.displaynames", "target", "showDeviceFrame",
                                     "fastboot.forceFastBoot", "fastboot.forceChosenSnapshotBoot", "fastboot.chosenSnapshotFile",
                                     "runtime.network.latency", "runtime.network.speed"]
        let ini = AVDConfigGenerator.configIni(for: InstancePreset.standard.makeConfig(id: id))
        let unknown = ini.keys.filter { !known.contains($0) && !metadata.contains($0) }
        #expect(unknown.isEmpty, "keys not in hardware-properties.ini: \(unknown)")
    }

    @Test func pointerIniHasAbsolutePathAndNoPathRel() {
        let config = InstancePreset.lite.makeConfig(id: id)
        let ini = AVDConfigGenerator.pointerIni(for: config, avdDirectory: URL(fileURLWithPath: "/x/avd/emuu-test.avd"))
        #expect(ini["path"] == "/x/avd/emuu-test.avd")
        #expect(ini["path.rel"] == nil)
        #expect(ini["target"] == "android-36.1")
    }
}
