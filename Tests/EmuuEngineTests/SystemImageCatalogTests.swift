import Foundation
import Testing
import EmuuBase
@testable import EmuuEngine

@Suite struct AndroidVersionTests {
    @Test func parsesWhatUsersType() {
        #expect(AndroidVersion("35") == AndroidVersion(major: 35))
        #expect(AndroidVersion(" 36.1 ") == AndroidVersion(major: 36, minor: 1))
        #expect(AndroidVersion("android-34") == AndroidVersion(major: 34))
        #expect(AndroidVersion("API 35") == AndroidVersion(major: 35))
        #expect(AndroidVersion("api35") == AndroidVersion(major: 35))
        #expect(AndroidVersion("Android 36.1") == AndroidVersion(major: 36, minor: 1))
        #expect(AndroidVersion("37.0") == AndroidVersion("37"))
        for bad in ["", "x", "35-ext15", "36.1.2", "-1", "0", "Baklava", "35.", ".1", "３５"] {
            #expect(AndroidVersion(bad) == nil, "\(bad)")
        }
    }

    @Test func directoriesAndNames() {
        #expect(AndroidVersion(apiDirectory: "android-36.1") == AndroidVersion(major: 36, minor: 1))
        #expect(AndroidVersion(apiDirectory: "android-35-ext15") == nil)
        #expect(AndroidVersion(apiDirectory: "Baklava") == nil)
        #expect(AndroidVersion(major: 35).label == "Android 15 (API 35)")
        #expect(AndroidVersion(major: 34).marketingName == "Android 14")
        #expect(AndroidVersion(major: 36, minor: 1).label == "Android 16 QPR2 (API 36.1)")
        #expect(AndroidVersion(major: 36, minor: 1).defaultAPIDirectory == "android-36.1")
        #expect(AndroidVersion(major: 35) < AndroidVersion(major: 36))
        #expect(AndroidVersion(major: 36) < AndroidVersion(major: 36, minor: 1))
        #expect(SystemImageRef.playStoreDefault.androidVersion == AndroidVersion(major: 36, minor: 1))
        #expect(SystemImageRef.playStore(AndroidVersion(major: 35)).sdkManagerPackage == "system-images;android-35;google_apis_playstore;arm64-v8a")
    }
}

@Suite struct SystemImageCatalogTests {
    static func img(_ dir: String, tag: String = "google_apis_playstore", abi: String = "arm64-v8a", api: String? = nil) -> InstalledSystemImage {
        InstalledSystemImage(ref: SystemImageRef(apiDirectory: dir, tag: tag, abi: abi), directory: URL(fileURLWithPath: "/sdk/system-images/\(dir)/\(tag)/\(abi)"),
                             apiLevel: api ?? String(dir.dropFirst("android-".count)), revision: "1", displayName: nil, tagDisplay: nil)
    }

    @Test func onlyPlainPlayStoreArm64ImagesCount() {
        let all = [Self.img("android-35"), Self.img("android-36.1"), Self.img("android-35", tag: "google_apis_playstore_ps16k"),
                   Self.img("android-35-ext15"), Self.img("android-34", tag: "google_apis"), Self.img("android-34", abi: "x86_64")]
        #expect(SystemImageCatalog.installed(from: all).map(\.ref.apiDirectory) == ["android-36.1", "android-35"])
    }

    @Test func defaultIsThirtySixOneWhenInstalledElseNewestSupported() {
        #expect(SystemImageCatalog.defaultImage(installed: [Self.img("android-35"), Self.img("android-36.1"), Self.img("android-37.0")])?.ref.apiDirectory == "android-36.1")
        // 36.1 absent: newest supported, not the unsupported 37.
        #expect(SystemImageCatalog.defaultImage(installed: [Self.img("android-34"), Self.img("android-35"), Self.img("android-37.0")])?.ref.apiDirectory == "android-35")
        #expect(SystemImageCatalog.defaultImage(installed: [Self.img("android-37.0")])?.ref.apiDirectory == "android-37.0")
        #expect(SystemImageCatalog.defaultImage(installed: [Self.img("android-35", tag: "google_apis")]) == nil)
    }

    @Test func resolveVersionText() throws {
        let installed = [Self.img("android-35"), Self.img("android-36.1")]
        #expect(try SystemImageCatalog.resolve("35", installed: installed).ref.apiDirectory == "android-35")
        #expect(try SystemImageCatalog.resolve("android-36.1", installed: installed).ref.apiDirectory == "android-36.1")
        #expect(try SystemImageCatalog.resolve(nil, installed: installed).ref.apiDirectory == "android-36.1")
        #expect(throws: SystemImageCatalog.ResolveError.notInstalled(AndroidVersion(major: 34), supported: true)) {
            try SystemImageCatalog.resolve("34", installed: installed)
        }
        #expect(throws: SystemImageCatalog.ResolveError.notInstalled(AndroidVersion(major: 30), supported: false)) {
            try SystemImageCatalog.resolve("30", installed: installed)
        }
        #expect(throws: SystemImageCatalog.ResolveError.unparsable("pie")) { try SystemImageCatalog.resolve("pie", installed: installed) }
        #expect(throws: SystemImageCatalog.ResolveError.noImageInstalled) { try SystemImageCatalog.resolve(nil, installed: []) }
        let message = SystemImageCatalog.ResolveError.notInstalled(AndroidVersion(major: 34), supported: true).errorDescription ?? ""
        #expect(message.contains("emuu images install 34"))
    }

    @Test func parsesSDKManagerList() {
        let out = """
        Installed packages:
          Path                                                   | Version | Description                         | Location
          system-images;android-36.1;google_apis_playstore;arm64-v8a | 4       | Google Play ARM 64 v8a System Image | system-images/android-36.1/google_apis_playstore/arm64-v8a

        Available Packages:
          system-images;android-34;google_apis_playstore;arm64-v8a                        | 14                | Google Play ARM 64 v8a System Image
          system-images;android-34-ext12;google_apis_playstore;arm64-v8a                  | 1                 | Google Play ARM 64 v8a System Image
          system-images;android-35;google_apis_playstore;arm64-v8a                        | 9                 | Google Play ARM 64 v8a System Image
          system-images;android-35;google_apis_playstore_ps16k;arm64-v8a                  | 5                 | 16 KB Page Size Google Play ARM 64 v8a System Image
          system-images;android-35;google_apis_playstore_tablet;arm64-v8a                 | 9                 | Google Play Tablet ARM 64 v8a System Image
          system-images;android-35;google_apis;x86_64                                     | 9                 | Google APIs
          system-images;android-37.0;google_apis_playstore;arm64-v8a                      | 8                 | Google Play ARM 64 v8a System Image
          system-images;android-37.1;google_apis_playstore_ps16k;arm64-v8a                | 9                 | 16 KB Page Size Google Play ARM 64 v8a System Image
          platforms;android-35 | 2 | Android SDK Platform 35
        """
        let parsed = SystemImageCatalog.parseSDKManagerList(out)
        #expect(parsed.map(\.version.number) == ["37", "36.1", "35", "34"])
        #expect(parsed.first?.apiDirectory == "android-37.0")
    }

    @Test func rowsMergeInstalledAvailableAndUsers() throws {
        let installed = [Self.img("android-35"), Self.img("android-36.1")]
        var a = InstancePreset.standard.makeConfig(id: InstanceID(rawValue: "a")!, systemImage: .playStore(AndroidVersion(major: 35)))
        let b = InstancePreset.standard.makeConfig(id: InstanceID(rawValue: "b")!)
        let rows = SystemImageCatalog.rows(installed: installed, available: [(AndroidVersion(major: 37), "android-37.0")],
                                           instances: [a, b], sizeOnDisk: { _ in 4_000 })
        #expect(rows.map(\.version) == ["37", "36.1", "36", "35", "34"])
        let r35 = try #require(rows.first { $0.version == "35" })
        #expect(r35.installed && r35.instances == ["a"] && r35.sizeBytes == 4_000 && !r35.isDefault)
        let r361 = try #require(rows.first { $0.version == "36.1" })
        #expect(r361.isDefault && r361.instances == ["b"])
        let r34 = try #require(rows.first { $0.version == "34" })
        #expect(!r34.installed && r34.supported && r34.sizeBytes == 1_550_000_000)
        let r37 = try #require(rows.first { $0.version == "37" })
        #expect(!r37.supported && r37.package == "system-images;android-37.0;google_apis_playstore;arm64-v8a")
        a.id = InstanceID(rawValue: "a2")!
        #expect(SystemImageCatalog.users(of: .playStore(AndroidVersion(major: 35)), in: [a, b]).map(\.rawValue) == ["a2"])
    }
}

@Suite struct AndroidVersionStoreTests {
    @Test func createWithOlderVersionAndRefuseInPlaceChange() throws {
        let w = try TempWorld()
        try TempWorld.makeImage(sdkRoot: w.sdk.root, api: "android-35", tag: "google_apis_playstore", abi: "arm64-v8a",
                                properties: "AndroidVersion.ApiLevel=35\nPkg.Revision=9\nSystemImage.TagDisplay=Google Play\n")
        let env = try EngineEnvironment(paths: w.paths, sdk: w.sdk)
        #expect(env.playStoreImages.map(\.ref.apiDirectory) == ["android-36.1", "android-35"])
        #expect(env.preferredImage?.ref == .playStoreDefault)
        let id = InstanceID(rawValue: "old")!
        let v35 = SystemImageRef.playStore(AndroidVersion(major: 35))
        let created = try env.createInstance(id: id, image: v35)
        #expect(created.systemImage == v35)
        let ini = try IniFile(contentsOf: w.paths.avdDirectory(for: id).appendingPathComponent("config.ini"))
        #expect(ini["image.sysdir.1"] == "system-images/android-35/google_apis_playstore/arm64-v8a/")
        #expect(ini["target"] == "android-35")
        #expect(try env.store.load(id).systemImage == v35)

        // In place: refused by update, updatePreferences and clone.
        var changed = created
        changed.systemImage = .playStoreDefault
        #expect(throws: EmuuError.self) { try env.store.update(changed) }
        #expect(throws: EmuuError.self) { try env.store.updatePreferences(id) { $0.systemImage = .playStoreDefault } }
        #expect(throws: EmuuError.self) {
            try env.store.clone(id, to: InstanceID(rawValue: "c1")!) { $0.systemImage = .playStoreDefault }
        }
        #expect(!env.store.exists(InstanceID(rawValue: "c1")!))
        // Other changes still work, and a clone keeps the source's version.
        changed = created
        changed.cores = 2
        #expect(try env.store.update(changed).systemImage == v35)
        #expect(try env.store.clone(id, to: InstanceID(rawValue: "c2")!).systemImage == v35)

        do {
            try InstanceStore.checkSameImage(existing: v35, requested: .playStoreDefault)
            Issue.record("expected a refusal")
        } catch let EmuuError.invalidConfiguration(message) {
            #expect(message.contains("Android 15 (API 35)") && message.contains("--android 36.1"))
        }
    }

    @Test func defaultFallsBackWhenThirtySixOneIsMissing() throws {
        let w = try TempWorld(withPlayStoreImage: false)
        try TempWorld.makeImage(sdkRoot: w.sdk.root, api: "android-35", tag: "google_apis_playstore", abi: "arm64-v8a",
                                properties: "AndroidVersion.ApiLevel=35\n")
        let env = try EngineEnvironment(paths: w.paths, sdk: w.sdk)
        #expect(env.missingPlayStoreImageAdvice == nil)
        let config = try env.createInstance(id: InstanceID(rawValue: "p")!)
        #expect(config.systemImage.androidVersion == AndroidVersion(major: 35))
    }
}
