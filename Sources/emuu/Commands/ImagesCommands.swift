import Darwin
import Foundation
import ArgumentParser
import EmuuBase
import EmuuEngine

/// `emuu images list|install|remove`: the Android versions (Google Play arm64 system images) instances run.
struct Images: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List, install and remove Android versions (Google Play arm64 system images).",
        discussion: """
        Each instance runs the Android version it was created with (`emuu create <name> --android 35`); it cannot be \
        changed later. Emuu supports \(SystemImageCatalog.supported.map(\.version.number).joined(separator: ", ")); \
        new instances get \(SystemImageCatalog.defaultVersion.number) when it is installed.
        """,
        subcommands: [ImagesList.self, ImagesInstall.self, ImagesRemove.self],
        defaultSubcommand: ImagesList.self)
}

/// Runs `sdkmanager`.
enum SDKManagerTool {
    static func executable(_ sdk: AndroidSDK) -> (URL, [String]) {
        let path = sdk.sdkManagerPath
        if path.hasPrefix("/") { return (URL(fileURLWithPath: path), ["--sdk_root=\(sdk.root.path)"]) }
        return (URL(fileURLWithPath: "/usr/bin/env"), ["sdkmanager", "--sdk_root=\(sdk.root.path)"])
    }

    /// `sdkmanager --list` output (network; nil on failure).
    static func list(_ sdk: AndroidSDK) async -> String? {
        let (exe, base) = executable(sdk)
        guard let r = try? await SystemProcessRunner().run(ProcessRequest(executable: exe, arguments: base + ["--list"], timeout: .seconds(120))),
              r.succeeded else { return nil }
        return r.stdoutString
    }

    enum Licences { case acceptAll, askOnTerminal, declineAll }

    /// Runs sdkmanager with the terminal attached (its own progress bar). Licence prompts are answered "y" only
    /// with `.acceptAll`, left to the user on a terminal, or answered by EOF (= declined) otherwise.
    static func runAttached(_ sdk: AndroidSDK, _ args: [String], licences: Licences) throws -> Int32 {
        let (exe, base) = executable(sdk)
        let p = Process()
        p.executableURL = exe
        p.arguments = base + args
        p.standardOutput = FileHandle.standardError    // progress on stderr keeps stdout clean for scripts
        p.standardError = FileHandle.standardError
        var feeder: Pipe?
        switch licences {
        case .askOnTerminal: p.standardInput = FileHandle.standardInput
        case .declineAll: p.standardInput = FileHandle.nullDevice
        case .acceptAll:
            let pipe = Pipe()
            p.standardInput = pipe
            feeder = pipe
        }
        try p.run()
        if let feeder {
            // One "y" per licence prompt; sdkmanager reads them only when it asks. Written on a background thread
            // so a full pipe never blocks us; closing ends the input.
            let handle = feeder.fileHandleForWriting
            Thread.detachNewThread {
                for _ in 0..<32 { if (try? handle.write(contentsOf: Data("y\n".utf8))) == nil { break } }
                try? handle.close()
            }
        }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

struct ImagesList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "Installed and installable Android versions, with sizes and the instances using each.", aliases: ["ls"])

    @Flag(help: "Do not ask sdkmanager which versions it offers (no network; the built-in list is used).") var offline = false
    @Flag(help: "JSON output.") var json = false

    func run() async throws {
        let ctx = try CLIContext.live()
        var available: [(version: AndroidVersion, apiDirectory: String)]?
        if !offline {
            if !json { Out.progress("Asking sdkmanager which versions it offers…") }
            available = await SDKManagerTool.list(ctx.sdk).map(SystemImageCatalog.parseSDKManagerList)
            if !json { Out.endProgress() }
        }
        let rows = SystemImageCatalog.rows(installed: ctx.engines.installedImages, available: available,
                                           instances: ctx.store.list(), sizeOnDisk: SystemImageCatalog.diskUsage)
        if json { return try Out.json(rows) }
        Out.line(Self.render(rows))
        if available == nil && !offline { Out.line("(sdkmanager could not be queried; showing Emuu's built-in list only)") }
    }

    /// Text table (pure; unit-tested).
    static func render(_ rows: [SystemImageCatalog.Row]) -> String {
        let table = Fmt.table(["VERSION", "ANDROID", "STATUS", "SIZE", "INSTANCES", "NOTE"], rows.map { r in
            [r.version + (r.isDefault ? " (default)" : ""), r.name,
             r.installed ? "installed" + (r.revision.map { " r\($0)" } ?? "") : (r.supported ? "available" : "offered"),
             r.sizeBytes.map { (r.installed ? "" : "≈") + ByteCount.format($0) + (r.installed ? "" : " download") } ?? "-",
             r.instances.isEmpty ? "-" : r.instances.joined(separator: ", "),
             r.note ?? ""]
        })
        return table + "\nInstall: emuu images install <version>   Create: emuu create <name> --android <version>"
    }
}

struct ImagesInstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Download and install an Android version with sdkmanager.",
        discussion: """
        Installs system-images;android-<version>;google_apis_playstore;arm64-v8a (about 1.5-2 GB). Google's licence \
        must be accepted: sdkmanager asks on a terminal, or pass --accept-licenses to accept it without a prompt.
        """)

    @Argument(help: "Android version (API level), e.g. 35, 34, 36.1.") var version: String
    @Flag(name: .customLong("accept-licenses"), help: "Accept the SDK licences sdkmanager asks about (you agree to Google's Android SDK licence terms).") var acceptLicenses = false
    @Flag(help: "Allow a version Emuu does not list as supported.") var allowUnsupported = false

    func run() async throws {
        let ctx = try CLIContext.live()
        guard let v = AndroidVersion(version) else { throw CLIError(SystemImageCatalog.ResolveError.unparsable(version).errorDescription ?? version) }
        if let have = ctx.engines.playStoreImages.first(where: { $0.ref.androidVersion == v }) {
            Out.line("\(v.label) is already installed (\(have.ref.sdkManagerPackage)).")
            return
        }
        let entry = SystemImageCatalog.entry(for: v)
        guard entry != nil || allowUnsupported else {
            throw CLIError("Emuu does not support \(v.label) (supported: \(SystemImageCatalog.supported.map(\.version.number).joined(separator: ", "))). Pass --allow-unsupported to install it anyway.")
        }
        var dir = entry?.apiDirectory
        if dir == nil {
            Out.progress("Asking sdkmanager for \(v.label)…")
            let offered = await SDKManagerTool.list(ctx.sdk).map(SystemImageCatalog.parseSDKManagerList) ?? []
            Out.endProgress()
            guard let hit = offered.first(where: { $0.version == v }) else { throw CLIError("sdkmanager does not offer a Google Play arm64 image for \(v.label).") }
            dir = hit.apiDirectory
        }
        let ref = SystemImageRef.playStore(v, apiDirectory: dir)
        let licences: SDKManagerTool.Licences = acceptLicenses ? .acceptAll : (isatty(STDIN_FILENO) != 0 ? .askOnTerminal : .declineAll)
        Out.err("Installing \(ref.sdkManagerPackage)\(entry.map { " (about \(ByteCount.format($0.downloadBytes)) download)" } ?? "")…")
        let status = try SDKManagerTool.runAttached(ctx.sdk, [ref.sdkManagerPackage], licences: licences)
        // Verify from the disk, not the exit status: sdkmanager exits 0 when a licence is declined.
        let installed = SystemImageCatalog.installed(in: ctx.sdk).first { $0.ref == ref }
        guard let installed else {
            let hint = licences == .declineAll ? " The licence could not be accepted without a terminal; rerun with --accept-licenses to accept it." : ""
            throw CLIError("\(ref.sdkManagerPackage) was not installed (sdkmanager exit status \(status)).\(hint)")
        }
        guard AndroidVersion(installed.apiLevel) == v else {
            throw CLIError("Installed image reports API \(installed.apiLevel), expected \(v.number) (\(installed.directory.path)).")
        }
        let size = SystemImageCatalog.diskUsage(installed.directory).map { ByteCount.format($0) } ?? "?"
        Out.line("Installed \(v.label): \(installed.directory.path) (\(size), revision \(installed.revision ?? "?")).")
        Out.line("Create an instance with it: emuu create <name> --android \(v.number)")
    }
}

struct ImagesRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Uninstall an Android version (refused while instances of this EMUU_HOME use it).",
        discussion: "Android Studio AVDs and instances under another EMUU_HOME are not checked.",
        aliases: ["rm"])

    @Argument(help: "Android version (API level), e.g. 35.") var version: String
    @Flag(name: [.short, .long], help: "Do not ask for confirmation.") var yes = false

    func run() async throws {
        let ctx = try CLIContext.live()
        guard let v = AndroidVersion(version) else { throw CLIError(SystemImageCatalog.ResolveError.unparsable(version).errorDescription ?? version) }
        guard let img = ctx.engines.playStoreImages.first(where: { $0.ref.androidVersion == v }) else {
            throw CLIError("\(v.label) is not installed.")
        }
        let users = SystemImageCatalog.users(of: img.ref, in: ctx.store.list())
        guard users.isEmpty else {
            throw CLIError("\(v.label) is used by \(users.map(\.rawValue).joined(separator: ", ")); delete those instances first (an instance cannot move to another Android version).")
        }
        if !yes {
            guard isatty(STDIN_FILENO) != 0 else { throw CLIError("Refusing to remove \(v.label) without --yes (stdin is not a terminal).") }
            FileHandle.standardError.write(Data("Remove \(img.ref.sdkManagerPackage) from \(ctx.sdk.root.path)? [y/N] ".utf8))
            guard readLine()?.lowercased().hasPrefix("y") == true else { throw CLIError("Not removed.") }
        }
        let status = try SDKManagerTool.runAttached(ctx.sdk, ["--uninstall", img.ref.sdkManagerPackage], licences: .declineAll)
        guard !FileManager.default.fileExists(atPath: img.directory.appendingPathComponent("system.img").path) else {
            throw CLIError("\(img.ref.sdkManagerPackage) is still installed (sdkmanager exit status \(status)).")
        }
        Out.line("Removed \(v.label).")
    }
}
