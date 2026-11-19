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

@Suite struct CloneRewriteTests {
    let golden = InstanceID(rawValue: "gold")!
    let clone = InstanceID(rawValue: "farm-p-1")!

    @Test func snapshotHardwareIniIsRewrittenForTheClone() {
        let text = """
        hw.ramSize = 2048
        disk.cachePartition.path = /x/avd/gold.avd/cache.img
        disk.dataPartition.path = /x/avd/gold.avd/userdata-qemu.img
        kernel.path = /sdk/system-images/android-36.1/google_apis_playstore/arm64-v8a//kernel-ranchu
        avd.name = gold
        avd.id = gold
        android.avd.home = /x/avd
        """
        let out = InstanceStore.rewriteHardwareIni(text, fromAVD: "/x/avd/gold.avd", toAVD: "/x/avd/farm-p-1.avd", newID: "farm-p-1")
        #expect(out.contains("disk.cachePartition.path = /x/avd/farm-p-1.avd/cache.img"))
        #expect(out.contains("disk.dataPartition.path = /x/avd/farm-p-1.avd/userdata-qemu.img"))
        #expect(out.contains("avd.name = farm-p-1"))
        #expect(out.contains("avd.id = farm-p-1"))
        #expect(out.contains("kernel.path = /sdk/system-images/android-36.1/google_apis_playstore/arm64-v8a//kernel-ranchu"))
        #expect(out.contains("android.avd.home = /x/avd"))
        #expect(!out.contains("gold.avd"))
    }

    @Test func cloneWithSnapshotsRewritesEverythingPerInstance() throws {
        let w = try TempWorld()
        let store = try InstanceStore(paths: w.paths, sdk: w.sdk)
        try store.create(InstancePreset.lite.makeConfig(id: golden))
        let src = w.paths.avdDirectory(for: golden)
        let snap = src.appendingPathComponent("snapshots/default_boot")
        try FileManager.default.createDirectory(at: snap, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 4096).write(to: snap.appendingPathComponent("ram.bin"))
        let srcPath = src.standardizedFileURL.path
        try Data("disk.dataPartition.path = \(srcPath)/userdata-qemu.img\navd.name = gold\navd.id = gold\n".utf8)
            .write(to: snap.appendingPathComponent("hardware.ini"))
        try Data("qcow".utf8).write(to: src.appendingPathComponent("userdata-qemu.img.qcow2"))
        for leftover in ["multiinstance.lock", "hardware-qemu.ini", "hardware-qemu.ini.lock", "emu-launch-params.txt", "snapshot.lock.lock"] {
            try Data("x".utf8).write(to: src.appendingPathComponent(leftover))
        }
        let config = try store.clone(golden, to: clone, includeSnapshots: true) { c in
            c.ports = try? InstancePorts(console: 5560)
            c.discardStateOnExit = true
            c.goldenSource = "gold"
        }
        let dst = w.paths.avdDirectory(for: clone)
        #expect(config.id == clone && config.ports?.console == 5560 && config.discardStateOnExit == true)
        #expect(try IniFile(contentsOf: dst.appendingPathComponent("config.ini"))["AvdId"] == "farm-p-1")
        #expect(try IniFile(contentsOf: w.paths.avdIniFile(for: clone))["path"] == dst.standardizedFileURL.path)
        let hw = try String(contentsOf: dst.appendingPathComponent("snapshots/default_boot/hardware.ini"), encoding: .utf8)
        #expect(hw.contains("\(dst.standardizedFileURL.path)/userdata-qemu.img"))
        #expect(hw.contains("avd.name = farm-p-1"))
        // the golden's own snapshot metadata is untouched (the clone's file was replaced, not written through)
        #expect(try String(contentsOf: snap.appendingPathComponent("hardware.ini"), encoding: .utf8).contains("avd.name = gold"))
        #expect(FileManager.default.contentsEqual(atPath: snap.appendingPathComponent("ram.bin").path,
                                                  andPath: dst.appendingPathComponent("snapshots/default_boot/ram.bin").path))
        for leftover in ["multiinstance.lock", "hardware-qemu.ini", "hardware-qemu.ini.lock", "emu-launch-params.txt", "snapshot.lock.lock"] {
            #expect(!FileManager.default.fileExists(atPath: dst.appendingPathComponent(leftover).path), "\(leftover) copied")
        }
        #expect(try store.load(clone).goldenSource == "gold")
    }

    @Test func farmCommandLineEnforcesRAMAndDiscardsState() throws {
        var c = InstancePreset.lite.makeConfig(id: clone)
        c.ramMB = 1536
        c.guestRAMEnforced = true
        c.discardStateOnExit = true
        let args = EngineCommandLine.arguments(for: c, ports: try InstancePorts(console: 5556), options: EngineLaunchOptions(grpc: false))
        #expect(args.contains("-no-snapshot-save"))
        #expect(Array(args.suffix(3)) == ["-qemu", "-m", "1536"])
        #expect(!args.contains("-grpc"))
        let plain = EngineCommandLine.arguments(for: InstancePreset.lite.makeConfig(id: clone), ports: try InstancePorts(console: 5556),
                                                grpcPort: 8556, options: EngineLaunchOptions())
        #expect(!plain.contains("-qemu") && !plain.contains("-no-snapshot-save") && plain.contains("-grpc"))
    }
}
