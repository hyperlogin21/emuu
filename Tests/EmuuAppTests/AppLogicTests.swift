import Foundation
import Testing
import CoreGraphics
import EmuuBase
@testable import EmuuApp

@Suite struct SingleInstancePolicyTests {
    let alive: (Int32) -> Bool = { _ in true }

    @Test func firstInstanceRuns() {
        #expect(SingleInstancePolicy.decide(selfPID: 10, lockAcquired: true, lockOwnerPID: nil, others: [],
                                            bundleIdentifier: "dev.emuu.app", isAlive: alive) == .proceed)
    }

    @Test func secondInstanceHandsOffToLockOwner() {
        let others = [RunningAppInfo(pid: 5, bundleIdentifier: "dev.emuu.app", launchDate: Date(timeIntervalSince1970: 1))]
        #expect(SingleInstancePolicy.decide(selfPID: 10, lockAcquired: false, lockOwnerPID: 5, others: others,
                                            bundleIdentifier: "dev.emuu.app", isAlive: alive) == .handOff(to: 5))
    }

    @Test func staleOwnerPidFallsBackToOldestSameBundleProcess() {
        let others = [
            RunningAppInfo(pid: 10, bundleIdentifier: "dev.emuu.app", launchDate: Date(timeIntervalSince1970: 0)),   // self
            RunningAppInfo(pid: 7, bundleIdentifier: "dev.emuu.app", launchDate: Date(timeIntervalSince1970: 50)),
            RunningAppInfo(pid: 6, bundleIdentifier: "dev.emuu.app", launchDate: Date(timeIntervalSince1970: 20)),
            RunningAppInfo(pid: 3, bundleIdentifier: "com.other", launchDate: Date(timeIntervalSince1970: 1)),
        ]
        let d = SingleInstancePolicy.decide(selfPID: 10, lockAcquired: false, lockOwnerPID: 99, others: others,
                                            bundleIdentifier: "dev.emuu.app", isAlive: { $0 != 99 })
        #expect(d == .handOff(to: 6))
    }

    @Test func lockHeldByUnknownStartingProcessStillHandsOff() {
        let d = SingleInstancePolicy.decide(selfPID: 10, lockAcquired: false, lockOwnerPID: 42, others: [],
                                            bundleIdentifier: nil, isAlive: { _ in false })
        #expect(d == .handOff(to: 42))
        #expect(SingleInstancePolicy.decide(selfPID: 10, lockAcquired: false, lockOwnerPID: nil, others: [],
                                            bundleIdentifier: nil, isAlive: alive) == .proceed)
    }

    @Test func forwardsOnlyExistingInstallFiles() {
        let args = ["/Applications/Emuu.app/Contents/MacOS/Emuu", "-NSDocumentRevisionsDebugMode", "YES",
                    "/tmp/a.apk", "/tmp/missing.xapk", "/tmp/notes.txt", "/tmp/b.APKM"]
        let files = SingleInstancePolicy.forwardableFiles(arguments: args, fileExists: { $0 != "/tmp/missing.xapk" })
        #expect(files == ["/tmp/a.apk", "/tmp/b.APKM"])
    }
}

@Suite struct WindowGeometryTests {
    let phone = CGSize(width: 720, height: 1600)

    @Test func contentIsScreenPlusStrip() {
        let s = InstanceWindowGeometry.contentSize(displayHeight: 800, aspect: phone)
        #expect(s == CGSize(width: 360 + InstanceWindowGeometry.stripWidth, height: 800))
    }

    @Test func resizeKeepsAspectAndMinimum() {
        let current = InstanceWindowGeometry.contentSize(displayHeight: 800, aspect: phone)
        // Dragging the bottom edge: height drives.
        let taller = InstanceWindowGeometry.constrain(proposed: CGSize(width: current.width, height: 900), current: current, aspect: phone)
        #expect(taller == CGSize(width: 405 + InstanceWindowGeometry.stripWidth, height: 900))
        // Dragging the side: width drives, the strip is not stretched.
        let wider = InstanceWindowGeometry.constrain(proposed: CGSize(width: 450 + InstanceWindowGeometry.stripWidth, height: 800), current: current, aspect: phone)
        #expect(wider == CGSize(width: 450 + InstanceWindowGeometry.stripWidth, height: 1000))
        // Never below the minimum screen height.
        let tiny = InstanceWindowGeometry.constrain(proposed: CGSize(width: 100, height: 100), current: current, aspect: phone)
        #expect(tiny.height == InstanceWindowGeometry.minDisplayHeight)
    }

    @Test func idealSizeFitsScreen() {
        let s = InstanceWindowGeometry.idealContentSize(aspect: phone, visible: CGSize(width: 1440, height: 875))
        #expect(s.height <= 875 * 0.85 + 1)
        let landscape = InstanceWindowGeometry.idealContentSize(aspect: CGSize(width: 1600, height: 720), visible: CGSize(width: 1000, height: 875))
        #expect(landscape.width <= 800 + 1)
        #expect(abs((landscape.width - InstanceWindowGeometry.stripWidth) / landscape.height - 1600.0 / 720.0) < 0.02)
    }
}

@Suite struct AndroidVersionChoicesTests {
    @Test func installableExcludesInstalledAndTitlesMarkDefault() {
        let v35 = SystemImageRef.playStore(AndroidVersion(major: 35))
        let c = AndroidVersionChoices(installed: [.playStoreDefault, v35], defaultImage: .playStoreDefault)
        #expect(c.installable.map(\.version.number) == ["36", "34"])
        #expect(c.installable.first?.command == "emuu images install 36")
        #expect(AndroidVersionChoices.title(.playStoreDefault, isDefault: true) == "Android 16 QPR2 (API 36.1) — default")
        #expect(AndroidVersionChoices.title(v35, isDefault: false) == "Android 15 (API 35)")
    }
}
