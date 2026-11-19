import Darwin
import Foundation
import Testing
import EmuuBase
@testable import EmuuEngine

@Suite struct InstanceStoreTests {
    let id = InstanceID(rawValue: "phone1")!

    @Test func createWritesAVDFilesAndRecord() throws {
        let w = try TempWorld()
        let store = try InstanceStore(paths: w.paths, sdk: w.sdk)
        let config = try store.create(InstancePreset.standard.makeConfig(id: id, displayName: "Phone One"))
        let ini = try IniFile(contentsOf: w.paths.avdDirectory(for: id).appendingPathComponent("config.ini"))
        #expect(ini["AvdId"] == "phone1")
        #expect(ini["tag.display"] == "Google Play") // read from the image's source.properties
        let pointer = try IniFile(contentsOf: w.paths.avdIniFile(for: id))
        #expect(pointer["path"] == w.paths.avdDirectory(for: id).standardizedFileURL.path)
        #expect(try store.load(id) == config)
        #expect(store.list().map(\.id) == [id])
        #expect(!store.isRunning(id))
    }

    @Test func rejectsDuplicatesInvalidConfigsAndMissingImages() throws {
        let w = try TempWorld()
        let store = try InstanceStore(paths: w.paths, sdk: w.sdk)
        try store.create(InstancePreset.lite.makeConfig(id: id))
        #expect(throws: EmuuError.instanceAlreadyExists(id)) { try store.create(InstancePreset.lite.makeConfig(id: id)) }
        var bad = InstancePreset.lite.makeConfig(id: InstanceID(rawValue: "bad")!)
        bad.ramMB = 100
        #expect(throws: EmuuError.self) { try store.create(bad) }
        let missing = InstancePreset.lite.makeConfig(id: InstanceID(rawValue: "noimg")!,
                                                      systemImage: SystemImageRef(apiDirectory: "android-99", tag: "google_apis_playstore", abi: "arm64-v8a"))
        #expect { try store.create(missing) } throws: { ($0 as? EmuuError).map { if case .systemImageMissing = $0 { true } else { false } } ?? false }
        // Nothing half-created for the failed ones.
        #expect(!FileManager.default.fileExists(atPath: w.paths.avdDirectory(for: InstanceID(rawValue: "noimg")!).path))
        #expect(store.list().count == 1)
    }

    @Test func refusesToUseUserAndroidHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(throws: EmuuError.self) {
            try InstanceStore.assertNotUserAndroidHome(home.appendingPathComponent(".android/avd"))
        }
        #expect(throws: Never.self) {
            try InstanceStore.assertNotUserAndroidHome(home.appendingPathComponent(".emuu/avd"))
        }
    }

    @Test func updateKeepsUserdataAndRefusesWhileLocked() throws {
        let w = try TempWorld()
        let store = try InstanceStore(paths: w.paths, sdk: w.sdk)
        var config = InstancePreset.standard.makeConfig(id: id)
        try store.create(config)
        let avdDir = w.paths.avdDirectory(for: id)
        let userdata = avdDir.appendingPathComponent("userdata-qemu.img.qcow2")
        try Data("user data".utf8).write(to: userdata)
        config.ramMB = 3072
        try store.update(config)
        #expect(try IniFile(contentsOf: avdDir.appendingPathComponent("config.ini"))["hw.ramSize"] == "3072")
        #expect(try String(contentsOf: userdata, encoding: .utf8) == "user data")

        // Simulate a running engine holding the lock (flock conflicts across open file descriptions).
        let lockPath = AVDLockProbe.lockFile(in: avdDir).path
        FileManager.default.createFile(atPath: lockPath, contents: nil)
        let fd = open(lockPath, O_RDWR)
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        defer { close(fd) }
        #expect(store.isRunning(id))
        #expect(throws: EmuuError.invalidStateTransition(from: .running, action: "reconfigure")) { try store.update(config) }
        #expect(throws: EmuuError.invalidStateTransition(from: .running, action: "delete")) { try store.delete(id) }
        #expect(throws: EmuuError.invalidStateTransition(from: .running, action: "clone")) {
            try store.clone(id, to: InstanceID(rawValue: "copy")!)
        }
        flock(fd, LOCK_UN)
        #expect(!store.isRunning(id))
    }

    @Test func cloneCopiesDataSkipsRuntimeFilesAndSnapshots() throws {
        let w = try TempWorld()
        let store = try InstanceStore(paths: w.paths, sdk: w.sdk)
        try store.create(InstancePreset.standard.makeConfig(id: id, ports: try InstancePorts(console: 5580)))
        let src = w.paths.avdDirectory(for: id)
        try Data("qcow".utf8).write(to: src.appendingPathComponent("userdata-qemu.img.qcow2"))
        try Data("raw".utf8).write(to: src.appendingPathComponent("userdata-qemu.img"))
        try Data("1".utf8).write(to: src.appendingPathComponent("hardware-qemu.ini.lock"))
        try Data().write(to: src.appendingPathComponent("multiinstance.lock"))
        try Data("x".utf8).write(to: src.appendingPathComponent("hardware-qemu.ini"))
        try FileManager.default.createDirectory(at: src.appendingPathComponent("snapshots/default_boot"), withIntermediateDirectories: true)

        let target = InstanceID(rawValue: "phone2")!
        let cloned = try store.clone(id, to: target, displayName: "Second")
        #expect(cloned.id == target && cloned.displayName == "Second" && cloned.ports == nil)
        let dst = w.paths.avdDirectory(for: target)
        let items = Set(try FileManager.default.contentsOfDirectory(atPath: dst.path))
        #expect(items == ["config.ini", "userdata-qemu.img.qcow2", "userdata-qemu.img"])
        #expect(try IniFile(contentsOf: dst.appendingPathComponent("config.ini"))["AvdId"] == "phone2")
        #expect(try IniFile(contentsOf: w.paths.avdIniFile(for: target))["path"] == dst.standardizedFileURL.path)
        #expect(store.list().map(\.id) == [id, target])
    }

    @Test func deleteRemovesEverything() throws {
        let w = try TempWorld()
        let store = try InstanceStore(paths: w.paths, sdk: w.sdk)
        try store.create(InstancePreset.lite.makeConfig(id: id))
        try Data("1".utf8).write(to: w.paths.pidFile(for: id))
        try HibernationMarker.set(for: id, paths: w.paths, at: Date())
        try store.delete(id)
        for url in [w.paths.avdDirectory(for: id), w.paths.avdIniFile(for: id), w.paths.instanceConfigFile(for: id),
                    w.paths.pidFile(for: id), HibernationMarker.url(for: id, paths: w.paths)] {
            #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) left behind")
        }
        #expect(throws: EmuuError.instanceNotFound(id)) { try store.delete(id) }
    }

    @Test func listSkipsCorruptRecords() throws {
        let w = try TempWorld()
        let store = try InstanceStore(paths: w.paths, sdk: w.sdk)
        try store.create(InstancePreset.lite.makeConfig(id: id))
        try Data("{nope".utf8).write(to: w.paths.instancesDirectory.appendingPathComponent("broken.json"))
        #expect(store.list().map(\.id) == [id])
    }

    @Test func staleLockCleanupOnlyWhenUnlocked() throws {
        let w = try TempWorld()
        let dir = w.paths.avdDirectory(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in ["hardware-qemu.ini.lock", "snapshot.lock.lock", "multiinstance.lock", "config.ini"] {
            try Data().write(to: dir.appendingPathComponent(f))
        }
        let fd = open(AVDLockProbe.lockFile(in: dir).path, O_RDWR)
        flock(fd, LOCK_EX)
        #expect(AVDLockProbe.cleanStaleLocks(avdDirectory: dir).isEmpty)
        flock(fd, LOCK_UN)
        close(fd)
        let removed = AVDLockProbe.cleanStaleLocks(avdDirectory: dir).map(\.lastPathComponent).sorted()
        #expect(removed == ["hardware-qemu.ini.lock", "snapshot.lock.lock"])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.ini").path))
    }
}
