import Foundation
import Testing
import EmuuBase
import EmuuTestSupport
@testable import EmuuADB

@Suite("PackageManager and Play Store")
struct PackageAndPlayStoreTests {
    @Test func listParsing() {
        let text = """
        package:/data/app/~~Zx9Q==/com.example.game-ab1==/base.apk=com.example.game versionCode:1234 uid:10150 installer=com.android.vending
        package:/data/app/~~Ab==/org.sideload-cd==/base.apk=org.sideload versionCode:7 uid:10151 installer=null
        package:com.nopath versionCode:1
        not a package line
        """
        let p = PackageManager.parseList(text)
        #expect(p.count == 3)
        #expect(p[0].info.packageName == "com.example.game")
        #expect(p[0].info.apkPaths == ["/data/app/~~Zx9Q==/com.example.game-ab1==/base.apk"])
        #expect(p[0].info.versionCode == 1234)
        #expect(p[0].uid == 10150)
        #expect(p[0].info.isFromPlayStore)
        #expect(p[1].info.installerPackage == nil)
        #expect(p[2].info.packageName == "com.nopath")
    }

    @Test func listPackagesWithDetails() async throws {
        let shell = FakeDeviceShell(serial: testSerial)
        shell.onShell(prefix: "pm list packages -f -U -i --show-versioncode -3", reply: .ok("""
        package:/data/app/~~a==/com.example.game-b==/base.apk=com.example.game versionCode:1234 uid:10150 installer=com.android.vending
        package:/data/app/~~c==/org.off-d==/base.apk=org.off versionCode:2 uid:10151 installer=null
        @@EMUU@@
        package:org.off
        @@EMUU@@
        package:com.example.game
        package:org.off

        """))
        shell.onShell(prefix: "echo '@@P' com.example.game", reply: .ok("""
        @@P com.example.game
            versionName=1.2.3
        52340\t/data/app/~~a==/com.example.game-b==
        @@P org.off
            versionName=0.1
        """))
        let list = try await PackageManager(shell: shell).listPackages()
        #expect(list.map(\.info.packageName) == ["com.example.game", "org.off"])
        #expect(list[0].info.versionName == "1.2.3")
        #expect(list[0].codeBytes == 52340 * 1024)
        #expect(list[0].info.isEnabled && !list[0].info.isSystem)
        #expect(list[1].info.isEnabled == false)
        #expect(list[1].codeBytes == nil)
    }

    @Test func dumpsysPackageParsing() {
        let text = """
        Packages:
          Package [com.example.game] (abc):
            userId=10150
            pkg=Package{abc com.example.game}
            codePath=/data/app/~~a==/com.example.game-b==
            versionCode=1234 minSdk=24 targetSdk=34
            versionName=1.2.3
            pkgFlags=[ HAS_CODE ALLOW_CLEAR_USER_DATA ]
            installerPackageName=com.android.vending
            User 0: ceDataInode=1 installed=true hidden=false suspended=false distractionFlags=0 stopped=false notLaunched=false enabled=3 instant=false virtual=false
        """
        let info = PackageManager.parseDumpsysPackage(text, packageName: "com.example.game")
        #expect(info?.versionName == "1.2.3")
        #expect(info?.versionCode == 1234)
        #expect(info?.installerPackage == "com.android.vending")
        #expect(info?.isSystem == false)
        #expect(info?.isEnabled == false)
        #expect(info?.apkPaths == ["/data/app/~~a==/com.example.game-b=="])
        #expect(PackageManager.parseDumpsysPackage("Unable to find package: x", packageName: "x") == nil)
    }

    @Test func launchResolvesLauncherActivity() async throws {
        let shell = FakeDeviceShell(serial: testSerial)
        shell.onShell(prefix: "cmd package resolve-activity", reply: .ok("priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=false\ncom.example.game/.MainActivity\n"))
        shell.onShell(prefix: "am start", reply: .ok("Starting: Intent { act=android.intent.action.MAIN cat=[android.intent.category.LAUNCHER] cmp=com.example.game/.MainActivity }\n"))
        try await PackageManager(shell: shell).launch("com.example.game")
        #expect(shell.shellCommands.last == "am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n com.example.game/.MainActivity")

        shell.onShell(prefix: "am start", reply: .ok("Starting: Intent {}\nError type 3\nError: Activity class {com.example.game/.MainActivity} does not exist.\n"))
        await #expect(throws: EmuuError.self) { try await PackageManager(shell: shell).launch("com.example.game") }

        shell.onShell(prefix: "cmd package resolve-activity", reply: .ok("No activity found\n"))
        shell.onShell(prefix: "monkey", reply: .ok("Events injected: 1\n"))
        try await PackageManager(shell: shell).launch("com.example.game")
        #expect(shell.shellCommands.last?.hasPrefix("monkey -p com.example.game") == true)
    }

    @Test func packageActions() async throws {
        let shell = FakeDeviceShell(serial: testSerial)
        shell.onShell(prefix: "pm uninstall", reply: .ok("Success\n"))
        shell.onShell(prefix: "pm clear", reply: .ok("Success\n"))
        shell.onShell(prefix: "pm grant", reply: .ok(""))
        shell.onShell(prefix: "am force-stop", reply: .ok(""))
        shell.onShell(prefix: "pm path", reply: .ok("package:/data/app/x/base.apk\npackage:/data/app/x/split_config.arm64_v8a.apk\n"))
        let pm = PackageManager(shell: shell)
        #expect(try await pm.uninstall("com.a.b", keepData: true))
        try await pm.clearData("com.a.b")
        try await pm.grant("android.permission.CAMERA", to: "com.a.b")
        try await pm.forceStop("com.a.b")
        #expect(try await pm.isInstalled("com.a.b"))
        #expect(try await pm.apkPaths(of: "com.a.b").count == 2)
        #expect(shell.shellCommands.contains("pm uninstall -k com.a.b"))
        #expect(shell.shellCommands.contains("pm grant com.a.b android.permission.CAMERA"))
        shell.onShell(prefix: "pm uninstall", reply: .ok("Failure [DELETE_FAILED_INTERNAL_ERROR]\n"))
        #expect(try await pm.uninstall("com.a.b") == false)
    }

    @Test func accountHeuristic() {
        #expect(PlayStore.parseAccounts("  Accounts: 2\n    Account {name=*, type=com.google}\n    Account {name=*, type=com.example}\n") == .signedIn(googleAccounts: 1))
        #expect(PlayStore.parseAccounts("  Accounts: 0\n") == .signedOut)
        #expect(PlayStore.parseAccounts("Permission Denial: can't dump") == .unknown(reason: "dumpsys account is not permitted on this device"))
        if case .unknown = PlayStore.parseAccounts("") {} else { Issue.record("empty output must be unknown") }
    }

    @Test func accountStateRedactsOnDevice() async throws {
        let shell = FakeDeviceShell(serial: testSerial)
        shell.onShell(prefix: "dumpsys account", reply: .ok("  Accounts: 1\n    Account {name=*, type=com.google}\n"))
        #expect(try await PlayStore(shell: shell).accountState() == .signedIn(googleAccounts: 1))
        #expect(shell.shellCommands[0].contains("sed -E 's/name=[^,]*,/name=*,/'"))
    }

    @Test func storeStatusAndDeepLink() async throws {
        let shell = FakeDeviceShell(serial: testSerial)
        shell.onShell(prefix: "pm list packages -e com.android.vending", reply: .ok("""
        package:com.android.vending
        @@EMUU@@
            versionCode=84012345 minSdk=21 targetSdk=34
            versionName=40.1.23-31 [0] [PR] 123
        @@EMUU@@
        package:com.android.vending
        @@EMUU@@
            versionName=24.20.13 (190400-123)
        """))
        let status = try await PlayStore(shell: shell).status()
        #expect(status.storeInstalled && status.storeEnabled)
        #expect(status.storeVersionCode == 84012345)
        #expect(status.storeVersionName == "40.1.23-31 [0] [PR] 123")
        #expect(status.servicesInstalled)

        shell.onShell(prefix: "pm path com.android.vending", reply: .ok("package:/product/priv-app/Phonesky/Phonesky.apk\n"))
        shell.onShell(prefix: "am start -a android.intent.action.VIEW", reply: .ok("Starting: Intent { act=android.intent.action.VIEW dat=market://details/... pkg=com.android.vending }\n"))
        try await PlayStore(shell: shell).openListing(packageName: "com.supercell.clashofclans")
        #expect(shell.shellCommands.last == "am start -a android.intent.action.VIEW -d 'market://details?id=com.supercell.clashofclans' -p com.android.vending")
        await #expect(throws: EmuuError.self) { try await PlayStore(shell: shell).openListing(packageName: "bad name; rm -rf /") }

        shell.onShell(prefix: "pm path com.android.vending", reply: .fail(1))
        await #expect(throws: EmuuError.self) { try await PlayStore(shell: shell).openListing(packageName: "com.a.b") }
    }

    @Test func storeAbsentStatus() {
        let s = PlayStore.parseStatus(["", "", "", ""])
        #expect(!s.storeInstalled && !s.storeEnabled && !s.servicesInstalled)
    }

    @Test func packageNameValidation() {
        #expect(PlayStore.isValidPackageName("com.supercell.clashofclans"))
        #expect(PlayStore.isValidPackageName("com.a_b.C1"))
        #expect(!PlayStore.isValidPackageName("single"))
        #expect(!PlayStore.isValidPackageName("com..x"))
        #expect(!PlayStore.isValidPackageName("com.1abc"))
        #expect(!PlayStore.isValidPackageName("com.x&y"))
    }

    @Test func inputTextEscaping() async throws {
        let fake = try FakeADBServer()
        let seen = Locked<[String]>([])
        fake.onShell { cmd in seen.withLock { $0.append(cmd) }; return .init() }
        let helpers = DeviceHelpers(client: makeClient(fake))
        try await helpers.inputText("hello world's & more")
        #expect(seen.current.last == "input text 'hello%sworld'\\''s%s&%smore'")
        await #expect(throws: EmuuError.self) { try await helpers.inputText("héllo") }
        try await helpers.keyEvent("KEYCODE_HOME")
        #expect(seen.current.last == "input keyevent KEYCODE_HOME")
        await #expect(throws: EmuuError.self) { try await helpers.keyEvent("3; reboot") }
    }

    @Test func clipboardDetection() {
        #expect(DeviceHelpers.clipboardSetCommand(fromHelp: "Clipboard service commands:\n  set-primary-clip TEXT\n") == "set-primary-clip")
        #expect(DeviceHelpers.clipboardSetCommand(fromHelp: "cmd: Can't find service: clipboard") == nil)
    }
}
