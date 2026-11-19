import Foundation
import ArgumentParser
import EmuuBase
import EmuuADB
import EmuuDisplay

/// Turns command-line paths into install jobs (pure; unit-tested).
enum InstallPlanner {
    struct Problem: Error, Equatable { var message: String }

    /// * A file is installed by its extension (.apk, .xapk, .apks, .apkm).
    /// * A directory that looks like one app's split set (contains `base.apk`, or `split_*.apk` /
    ///   `config.*.apk` files) becomes one split install; otherwise every package file in it is installed
    ///   on its own.
    /// * `splitSet` treats all the given .apk files as one split set.
    static func plan(_ paths: [String], splitSet: Bool, fileManager: FileManager = .default) throws -> [InstallSource] {
        var sources: [InstallSource] = []
        var looseAPKs: [URL] = []
        for raw in paths {
            let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else {
                throw Problem(message: "\(raw): no such file or directory")
            }
            if isDir.boolValue {
                let items = try fileManager.contentsOfDirectory(atPath: url.path)
                    .map { url.appendingPathComponent($0, isDirectory: false) }
                    .filter { InstallSource.detect(fileURL: $0) != nil }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                guard !items.isEmpty else { throw Problem(message: "\(raw): no .apk/.xapk/.apks/.apkm files inside") }
                let apks = items.filter { $0.pathExtension.lowercased() == "apk" }
                let others = items.filter { $0.pathExtension.lowercased() != "apk" }
                if splitSet || looksLikeSplitSet(apks) {
                    if !apks.isEmpty { sources.append(apks.count == 1 ? .apk(apks[0]) : .splitAPKs(baseFirst(apks))) }
                } else {
                    sources += apks.map { .apk($0) }
                }
                sources += others.compactMap { InstallSource.detect(fileURL: $0) }
            } else {
                guard let source = InstallSource.detect(fileURL: url) else {
                    throw Problem(message: "\(raw): unsupported file type (use .apk, .xapk, .apks or .apkm)")
                }
                if splitSet, case .apk(let u) = source { looseAPKs.append(u) } else { sources.append(source) }
            }
        }
        if !looseAPKs.isEmpty {
            sources.insert(looseAPKs.count == 1 ? .apk(looseAPKs[0]) : .splitAPKs(baseFirst(looseAPKs)), at: 0)
        }
        return sources
    }

    static func looksLikeSplitSet(_ apks: [URL]) -> Bool {
        guard apks.count > 1 else { return false }
        return apks.contains { n in
            let name = n.lastPathComponent.lowercased()
            return name == "base.apk" || name.hasPrefix("split_") || name.hasPrefix("config.")
        }
    }

    static func baseFirst(_ apks: [URL]) -> [URL] {
        apks.sorted { a, b in
            let ab = a.lastPathComponent.lowercased() == "base.apk", bb = b.lastPathComponent.lowercased() == "base.apk"
            if ab != bb { return ab }
            return a.lastPathComponent < b.lastPathComponent
        }
    }
}

/// Flat JSON form of an `InstallResult` for `emuu install --json`.
struct InstallRecord: Codable, Sendable, Hashable {
    var source: String
    var files: [String]
    var packageName: String?
    var status: String
    var code: String?
    var message: String?
    var apkCount: Int
    var obbCount: Int
    var seconds: Double

    init(_ r: InstallResult) {
        source = r.source.description
        switch r.source {
        case .apk(let u), .xapk(let u), .apks(let u), .apkm(let u): files = [u.path]
        case .splitAPKs(let us): files = us.map(\.path)
        case .playStore: files = []
        }
        packageName = r.packageName
        switch r.status {
        case .installed: status = "installed"
        case .openedInPlayStore: status = "openedInPlayStore"
        case .failed(let c, let m): status = "failed"; code = c; message = m
        }
        apkCount = r.apkCount
        obbCount = r.obbCount
        seconds = r.duration.timeInterval
    }
}

struct Install: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install apps and games: .apk, split APK sets (directory), .xapk (with OBB data), .apks, .apkm.")

    @Argument(help: "Files or directories.")
    var paths: [String]

    @OptionGroup var target: InstanceOption

    @Flag(help: "Treat all given .apk files (or a directory's .apk files) as one app's split set.")
    var split = false

    @Flag(help: "Allow installing an older version over a newer one.")
    var allowDowngrade = false

    @Flag(help: "Do not grant runtime permissions at install time.")
    var noGrant = false

    @Flag(help: "Skip copying OBB expansion files from .xapk bundles.")
    var noObb = false

    @Flag(help: "JSON output (one result per package).")
    var json = false

    func run() async throws {
        let ctx = try CLIContext.live()
        let config = try ctx.resolveInstance(target.instance)
        let sources: [InstallSource]
        do { sources = try InstallPlanner.plan(paths, splitSet: split) } catch let p as InstallPlanner.Problem { throw CLIError(p.message) }
        let client = try await ctx.readyDevice(config)
        let installer = APKInstaller(client: client, cacheDirectory: ctx.paths.cacheDirectory)
        var options = InstallOptions()
        options.allowDowngrade = allowDowngrade
        options.grantRuntimePermissions = !noGrant
        options.copyExpansionFiles = !noObb
        var results: [InstallResult] = []
        var failures = 0
        for source in sources {
            let label = source.description
            let result = try await installer.install(source, options: options) { p in
                var text = "\(label): \(p.stage.rawValue)"
                if let f = p.currentFile { text += " \(f)" }
                if let fr = p.fraction { text += String(format: " %.0f%%", fr * 100) }
                Out.progress(text)
            }
            Out.endProgress()
            results.append(result)
            if !json {
                switch result.status {
                case .installed:
                    var s = "Installed \(result.packageName ?? "?") from \(label) in \(Fmt.seconds(result.duration))"
                    if result.apkCount > 1 { s += " (\(result.apkCount) APKs)" }
                    if result.obbCount > 0 { s += " + \(result.obbCount) OBB file(s)" }
                    Out.line(s + ".")
                case .openedInPlayStore:
                    Out.line("Opened the Play Store listing for \(result.packageName ?? "?").")
                case .failed(let code, let message):
                    failures += 1
                    Out.err("Failed \(label): \(code): \(message)")
                }
            } else if !result.succeeded { failures += 1 }
        }
        if json { try Out.json(results.map(InstallRecord.init)) }
        if failures > 0 { throw ExitCode(1) }
    }
}

struct Apps: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List installed apps (user apps by default).")

    @OptionGroup var target: InstanceOption

    @Flag(help: "Include system apps.")
    var system = false

    @Flag(help: "JSON output.")
    var json = false

    func run() async throws {
        let ctx = try CLIContext.live()
        let client = try await ctx.readyDevice(try ctx.resolveInstance(target.instance))
        let packages = try await PackageManager(shell: client).listPackages(includeSystem: system, details: true)
            .sorted { $0.info.packageName < $1.info.packageName }
        if json { return try Out.json(packages) }
        if packages.isEmpty { return Out.line("No \(system ? "" : "user ")apps installed.") }
        Out.line(Fmt.table(["PACKAGE", "VERSION", "SIZE", "SOURCE"], packages.map { p in
            let source = p.info.isSystem ? "system" : p.info.isFromPlayStore ? "Play Store" : (p.info.installerPackage ?? "adb/sideload")
            return [p.info.packageName + (p.info.isEnabled ? "" : " (disabled)"), p.info.versionName ?? "-", Fmt.bytes(p.codeBytes), source]
        }))
    }
}

struct Launch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Launch an app by package name.")
    @Argument(help: "Package name, e.g. com.android.chrome.") var package: String
    @OptionGroup var target: InstanceOption

    func run() async throws {
        let ctx = try CLIContext.live()
        let client = try await ctx.readyDevice(try ctx.resolveInstance(target.instance))
        let pm = PackageManager(shell: client)
        guard try await pm.isInstalled(package) else { throw CLIError("\(package) is not installed. Try `emuu playstore \(package)`.") }
        try await pm.launch(package)
        Out.line("Launched \(package).")
    }
}

struct Uninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Uninstall an app.")
    @Argument(help: "Package name.") var package: String
    @Flag(help: "Keep the app's data and cache.") var keepData = false
    @OptionGroup var target: InstanceOption

    func run() async throws {
        let ctx = try CLIContext.live()
        let client = try await ctx.readyDevice(try ctx.resolveInstance(target.instance))
        guard try await PackageManager(shell: client).uninstall(package, keepData: keepData) else {
            throw CLIError("Uninstall of \(package) failed (not installed, or a system app).")
        }
        Out.line("Uninstalled \(package)\(keepData ? " (data kept)" : "").")
    }
}

struct Playstore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "playstore",
        abstract: "Open the Play Store (or an app's listing) and show store/account status.",
        discussion: """
        Sign in once inside the emulator (Play Store > Sign in). Emuu never handles Google credentials. \
        Headless, you need a screen to sign in: use `emuu start --window` or the Emuu app.
        """)

    @Argument(help: "Package name to open in the store (optional).") var package: String?
    @Option(help: "Open a store search instead.") var search: String?
    @Flag(help: "Open the add-Google-account screen.") var signIn = false
    @Flag(help: "Only print status; do not open anything.") var statusOnly = false
    @OptionGroup var target: InstanceOption

    func run() async throws {
        let ctx = try CLIContext.live()
        let client = try await ctx.readyDevice(try ctx.resolveInstance(target.instance))
        let store = PlayStore(shell: client)
        let status = try await store.status()
        guard status.storeInstalled else {
            throw CLIError("This image has no Play Store. Create the instance from the google_apis_playstore image (see `emuu doctor`).")
        }
        let account = try await store.accountState()
        let accountText: String
        switch account {
        case .signedIn(let n): accountText = "signed in (\(n) Google account\(n == 1 ? "" : "s"))"
        case .signedOut: accountText = "not signed in"
        case .unknown(let why): accountText = "unknown (\(why))"
        }
        Out.line("Play Store \(status.storeVersionName ?? "?")\(status.storeEnabled ? "" : " (disabled)"), Play services \(status.servicesVersionName ?? (status.servicesInstalled ? "?" : "missing")); account: \(accountText).")
        if statusOnly { return }
        if signIn {
            try await store.openAddGoogleAccount()
            Out.line("Opened the Google sign-in screen on the device.")
        } else if let package {
            guard PlayStore.isValidPackageName(package) else { throw CLIError("'\(package)' is not a valid package name.") }
            try await store.openListing(packageName: package)
            Out.line("Opened the listing for \(package). Tap Install on the device.")
        } else if let search {
            try await store.openSearch(search)
            Out.line("Opened a Play Store search for “\(search)”.")
        } else {
            try await store.open()
            Out.line("Opened the Play Store.")
        }
        if !account.isSignedIn && !signIn {
            Out.line("Tip: sign in on the device first (`emuu playstore --sign-in`, with `emuu start --window` or the app to see the screen).")
        }
    }
}

struct Screenshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Save a PNG screenshot of the device.",
        discussion: "Taken from the engine's own framebuffer, so secure screens (password fields, purchase sheets) are captured too; falls back to `adb screencap` when the engine has no gRPC endpoint.")
    @Argument(help: "Output file (.png).") var output: String
    @OptionGroup var target: InstanceOption

    func run() async throws {
        let ctx = try CLIContext.live()
        let config = try ctx.resolveInstance(target.instance)
        let client = try await ctx.readyDevice(config)
        let session = ctx.displaySession(config.id)
        let png: Data
        if let shot = try? await session.screenshotPNG() {
            png = shot
        } else {
            png = try await DeviceHelpers(client: client).screenshotPNG()
        }
        await session.stop()
        let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
        do { try png.write(to: url, options: .atomic) } catch { throw CLIError("cannot write \(url.path): \(describe(error))") }
        Out.line("Saved \(url.path) (\(ByteCount.format(UInt64(png.count)))).")
    }
}

struct Shell: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run an adb shell on the device (interactive without arguments).",
        discussion: "Example: emuu shell -- getprop ro.build.version.release")

    @OptionGroup var target: InstanceOption
    @Argument(parsing: .captureForPassthrough, help: "Command to run (after --).") var command: [String] = []

    func run() async throws {
        let ctx = try CLIContext.live()
        let serial = try await ctx.ensureRunning(try ctx.resolveInstance(target.instance))
        // Hand the terminal to adb itself (TTY, signals, exit status).
        let args = ["adb", "-s", serial.rawValue, "shell"] + command.drop { $0 == "--" }
        let cargs = args.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        execv(ctx.sdk.adb.path, cargs)
        throw CLIError("could not exec \(ctx.sdk.adb.path): \(String(cString: strerror(errno)))")
    }
}
