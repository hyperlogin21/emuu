import Darwin
import Foundation
import Testing
import EmuuBase
import EmuuEngine
@testable import EmuuFarm

@Suite struct CloneNamingTests {
    @Test func suggestsCopyNamesThatAreFree() {
        #expect(CloneNaming.suggestedDisplayName(source: "phone", existingDisplayNames: ["phone"], existingIDs: ["phone"]) == "phone copy")
        #expect(CloneNaming.suggestedDisplayName(source: "phone", existingDisplayNames: ["phone", "phone copy"], existingIDs: ["phone", "phone_copy"])
                == "phone copy 2")
        // the derived id is taken even though no display name matches
        #expect(CloneNaming.suggestedDisplayName(source: "phone", existingDisplayNames: ["phone"], existingIDs: ["phone", "phone_copy"])
                == "phone copy 2")
    }

    @Test func instanceIDFromTypedName() throws {
        #expect(try CloneNaming.instanceID(forDisplayName: "  phone copy ", existingIDs: []).rawValue == "phone_copy")
        #expect(try CloneNaming.instanceID(forDisplayName: "phone copy", existingIDs: ["phone_copy"]).rawValue == "phone_copy-2")
        #expect(try CloneNaming.instanceID(forDisplayName: "phone copy", existingIDs: ["phone_copy", "phone_copy-2"]).rawValue == "phone_copy-3")
        #expect(throws: EmuuError.self) { try CloneNaming.instanceID(forDisplayName: "!!!", existingIDs: []) }
        let long = String(repeating: "a", count: 64)
        let id = try CloneNaming.instanceID(forDisplayName: long, existingIDs: [long])
        #expect(id.rawValue.count == 64 && id.rawValue.hasSuffix("-2"))
    }

    @Test func explicitNamesAreValidated() {
        #expect(CloneNaming.problem(with: "phone2", existingIDs: ["phone"]) == nil)
        #expect(CloneNaming.problem(with: "phone", existingIDs: ["phone"])?.contains("exists") == true)
        #expect(CloneNaming.problem(with: "my phone", existingIDs: [])?.contains("not a valid") == true)
        #expect(CloneNaming.problem(with: "-x", existingIDs: []) != nil)
    }
}

@Suite struct ClonePortTests {
    @Test func explicitPortMustBeInADBRangeFreeAndUnclaimed() throws {
        #expect(try ClonePorts.choose(requested: 5584, source: nil, fixedByOthers: [], isFree: { _ in true })?.console == 5584)
        #expect(throws: EmuuError.self) { try ClonePorts.choose(requested: 5600, source: nil, fixedByOthers: [], isFree: { _ in true }) }
        #expect(throws: EmuuError.self) { try ClonePorts.choose(requested: 5583, source: nil, fixedByOthers: [], isFree: { _ in true }) }
        #expect(throws: EmuuError.self) { try ClonePorts.choose(requested: 5584, source: nil, fixedByOthers: [5584], isFree: { _ in true }) }
        // adb port of the pair is bound
        #expect(throws: EmuuError.self) { try ClonePorts.choose(requested: 5584, source: nil, fixedByOthers: [], isFree: { $0 != 5585 }) }
    }

    @Test func followsTheSource() throws {
        // source picks a free pair at each start → so does the clone
        #expect(try ClonePorts.choose(requested: nil, source: nil, fixedByOthers: [5554], isFree: { _ in true }) == nil)
        // source has a fixed port → the clone gets its own, never the source's or another instance's
        let src = try InstancePorts(console: 5554)
        let p = try ClonePorts.choose(requested: nil, source: src, fixedByOthers: [5554, 5556], isFree: { $0 != 5558 })
        #expect(p?.console == 5560)
        #expect(p?.console ?? 0 <= 5584)
    }

    @Test func runsOut() throws {
        let src = try InstancePorts(console: 5554)
        #expect(throws: EmuuError.self) {
            try ClonePorts.choose(requested: nil, source: src, fixedByOthers: Set(FarmPorts.consolePorts), isFree: { _ in true })
        }
    }
}

@Suite struct CloneSourcePlanTests {
    @Test func stoppedAndHibernatedAreCopiedAsTheyAre() {
        #expect(CloneSourcePlan.decide(state: .stopped, mayPause: false, name: "phone") == .copyNow)
        #expect(CloneSourcePlan.decide(state: .hibernated, mayPause: false, name: "phone") == .copyNow)
    }

    @Test func runningNeedsConsent() {
        guard case .refuse(let why) = CloneSourcePlan.decide(state: .running, mayPause: false, name: "phone") else {
            Issue.record("a running source must not be copied without consent"); return
        }
        #expect(why.contains("--stop-source"))
        #expect(CloneSourcePlan.decide(state: .running, mayPause: true, name: "phone") == .hibernateCopyResume(refreeze: false))
        #expect(CloneSourcePlan.decide(state: .frozen, mayPause: true, name: "phone") == .hibernateCopyResume(refreeze: true))
    }

    @Test func refusesTransitionsCrashesAndForeignOwners() {
        for s: InstanceState in [.booting, .stopping, .hibernating, .crashed(reason: "x")] {
            if case .refuse = CloneSourcePlan.decide(state: s, mayPause: true, name: "phone") {} else { Issue.record("\(s) must be refused") }
        }
        guard case .refuse(let why) = CloneSourcePlan.decide(state: .running, mayPause: true, foreignOwner: "the emuu CLI", name: "phone") else {
            Issue.record("a source governed elsewhere must be refused"); return
        }
        #expect(why.contains("the emuu CLI"))
        // a stopped source is fine whoever last ran it
        #expect(CloneSourcePlan.decide(state: .stopped, mayPause: false, foreignOwner: "the emuu CLI", name: "phone") == .copyNow)
    }
}

@Suite struct InstanceClonerTests {
    final class World: @unchecked Sendable {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("emuu-clone-tests-\(UUID().uuidString)")
        let paths: EmuuPaths
        let store: InstanceStore
        init() throws {
            paths = EmuuPaths(root: root)
            try paths.ensureDirectories()
            store = try InstanceStore(paths: paths, sdk: nil)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    let src = InstanceID(rawValue: "phone")!
    let dst = InstanceID(rawValue: "phone_copy")!

    /// A source that looks like a hibernated instance: qcow2 overlays, encryption key, modem state, a quick-boot
    /// snapshot whose hardware.ini names the source, and per-launch leftovers.
    func makeSource(_ w: World, snapshot: Bool = true, ports: InstancePorts? = nil) throws -> URL {
        var config = InstancePreset.standard.makeConfig(id: src, displayName: "phone")
        config.ports = ports
        config.goldenSource = "base"
        try w.store.create(config)
        let dir = w.paths.avdDirectory(for: src)
        for f in ["userdata-qemu.img", "userdata-qemu.img.qcow2", "encryptionkey.img", "encryptionkey.img.qcow2", "cache.img.qcow2",
                  "multiinstance.lock", "hardware-qemu.ini", "emu-launch-params.txt"] {
            try Data("data of \(f)".utf8).write(to: dir.appendingPathComponent(f))
        }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("modem_simulator/iccprofile_for_sim0.xml"), withIntermediateDirectories: true)
        if snapshot {
            let snap = dir.appendingPathComponent("snapshots/default_boot")
            try FileManager.default.createDirectory(at: snap, withIntermediateDirectories: true)
            try Data(count: Int(EngineInstance.minimumRAMSnapshotBytes)).write(to: snap.appendingPathComponent("ram.bin"))
            try Data("pb".utf8).write(to: snap.appendingPathComponent("snapshot.pb"))
            try Data("disk.dataPartition.path = \(dir.standardizedFileURL.path)/userdata-qemu.img\navd.name = phone\navd.id = phone\n".utf8)
                .write(to: snap.appendingPathComponent("hardware.ini"))
        }
        // the engine's own config.ini after a first boot (6 GiB userdata, a key Emuu does not generate)
        try Data("AvdId = phone\navd.ini.displayname = phone\ndisk.dataPartition.size = 6442450944\nhw.engine.extra = yes\n".utf8)
            .write(to: dir.appendingPathComponent("config.ini"))
        return dir
    }

    @Test func clonesEverythingWithItsOwnIdentityAndFiles() throws {
        let w = try World()
        let srcDir = try makeSource(w)
        let r = try InstanceCloner(store: w.store).clone(src, to: dst, displayName: "phone copy", ports: try InstancePorts(console: 5584))
        let dstDir = w.paths.avdDirectory(for: dst)
        #expect(r.carriedSnapshot)
        #expect(r.config.id == dst && r.config.displayName == "phone copy" && r.config.ports?.console == 5584)
        #expect(r.config.goldenSource == nil && r.config.discardStateOnExit == nil)
        #expect(try w.store.load(dst) == r.config)
        // user data came along byte for byte
        for f in ["userdata-qemu.img", "userdata-qemu.img.qcow2", "encryptionkey.img", "encryptionkey.img.qcow2", "cache.img.qcow2"] {
            #expect(FileManager.default.contentsEqual(atPath: srcDir.appendingPathComponent(f).path, andPath: dstDir.appendingPathComponent(f).path), "\(f)")
        }
        #expect(FileManager.default.fileExists(atPath: dstDir.appendingPathComponent("modem_simulator/iccprofile_for_sim0.xml").path))
        // per-launch files of the source's engine did not
        for f in ["multiinstance.lock", "hardware-qemu.ini", "emu-launch-params.txt"] {
            #expect(!FileManager.default.fileExists(atPath: dstDir.appendingPathComponent(f).path), "\(f)")
        }
        // fix-ups: the snapshot and config.ini name the clone; the engine's config.ini keys are kept
        let hw = try String(contentsOf: dstDir.appendingPathComponent("snapshots/default_boot/hardware.ini"), encoding: .utf8)
        #expect(hw.contains("\(dstDir.standardizedFileURL.path)/userdata-qemu.img") && hw.contains("avd.name = phone_copy") && !hw.contains("phone.avd"))
        let ini = try IniFile(contentsOf: dstDir.appendingPathComponent("config.ini"))
        #expect(ini["AvdId"] == "phone_copy" && ini["avd.ini.displayname"] == "phone copy" && ini["disk.dataPartition.size"] == "6442450944")
        // the source is untouched
        #expect(try String(contentsOf: srcDir.appendingPathComponent("snapshots/default_boot/hardware.ini"), encoding: .utf8).contains("avd.name = phone"))
        #expect(try IniFile(contentsOf: srcDir.appendingPathComponent("config.ini"))["AvdId"] == "phone")
        // no writable file is shared: every file of the clone is its own inode
        #expect(InstanceCloner.sharedFiles(srcDir, dstDir).isEmpty)
        try Data("clone writes".utf8).write(to: dstDir.appendingPathComponent("userdata-qemu.img.qcow2"))
        #expect(try String(contentsOf: srcDir.appendingPathComponent("userdata-qemu.img.qcow2"), encoding: .utf8) == "data of userdata-qemu.img.qcow2")
    }

    @Test func coldBootCloneDropsTheSnapshot() throws {
        let w = try World()
        try _ = makeSource(w)
        let r = try InstanceCloner(store: w.store).clone(src, to: dst, displayName: nil, ports: nil, keepSnapshot: false)
        #expect(!r.carriedSnapshot)
        #expect(!FileManager.default.fileExists(atPath: w.paths.avdDirectory(for: dst).appendingPathComponent("snapshots").path))
        #expect(r.config.displayName == "phone_copy" && r.config.ports == nil)
    }

    @Test func stubSnapshotIsNotCarried() throws {
        let w = try World()
        let dir = try makeSource(w)
        try Data(count: 10).write(to: dir.appendingPathComponent("snapshots/default_boot/ram.bin"))
        let r = try InstanceCloner(store: w.store).clone(src, to: dst, displayName: nil, ports: nil)
        #expect(!r.carriedSnapshot)
    }

    @Test func refusesARunningSourceAndAnExistingTarget() throws {
        let w = try World()
        let dir = try makeSource(w)
        let fd = open(dir.appendingPathComponent("multiinstance.lock").path, O_RDWR)
        flock(fd, LOCK_EX)
        #expect(throws: EmuuError.invalidStateTransition(from: .running, action: "clone")) {
            try InstanceCloner(store: w.store).clone(src, to: dst, displayName: nil, ports: nil)
        }
        flock(fd, LOCK_UN)
        close(fd)
        #expect(!w.store.exists(dst))
        _ = try InstanceCloner(store: w.store).clone(src, to: dst, displayName: nil, ports: nil)
        #expect(throws: EmuuError.instanceAlreadyExists(dst)) {
            try InstanceCloner(store: w.store).clone(src, to: dst, displayName: nil, ports: nil)
        }
    }

    @Test func sharedFileDetectionFindsHardLinksAndSymlinks() throws {
        let w = try World()
        let a = w.root.appendingPathComponent("a"), b = w.root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: a.appendingPathComponent("disk.qcow2"))
        try Data("y".utf8).write(to: a.appendingPathComponent("own"))
        try FileManager.default.linkItem(at: a.appendingPathComponent("disk.qcow2"), to: b.appendingPathComponent("disk.qcow2"))
        try FileManager.default.createSymbolicLink(atPath: b.appendingPathComponent("link").path, withDestinationPath: a.appendingPathComponent("own").path)
        try InstanceStoreCloneProbe.clonefile(a.appendingPathComponent("own"), b.appendingPathComponent("own"))
        #expect(InstanceCloner.sharedFiles(a, b) == ["disk.qcow2", "link"])
    }
}

/// clonefile(2) in a test (falls back to a copy on non-APFS temp volumes).
enum InstanceStoreCloneProbe {
    static func clonefile(_ src: URL, _ dst: URL) throws {
        if Darwin.clonefile(src.path, dst.path, 0) != 0 { try FileManager.default.copyItem(at: src, to: dst) }
    }
}
