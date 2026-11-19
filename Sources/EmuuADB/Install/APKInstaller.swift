import Foundation
import EmuuBase

/// PackageManager install flags.
public struct InstallOptions: Sendable, Hashable {
    /// `-r`: replace an existing installation, keeping its data.
    public var replaceExisting = true
    /// `-d`: allow a lower versionCode (debuggable apps only on user builds).
    public var allowDowngrade = false
    /// `-g`: grant all runtime permissions at install time (saves permission prompts in games).
    public var grantRuntimePermissions = true
    /// `-t`: allow test-only APKs.
    public var allowTestPackages = true
    /// `--bypass-low-target-sdk-block` (Android 14+): install apps targeting very old SDKs.
    public var bypassLowTargetSDKBlock = false
    /// Copy OBB expansion files from XAPK bundles to `/sdcard/Android/obb/<package>/`.
    public var copyExpansionFiles = true
    /// Keep extracted bundle contents in the cache (debugging); normally removed after install.
    public var keepExtractedFiles = false

    public init() {}

    var packageManagerFlags: [String] {
        var f: [String] = []
        if replaceExisting { f.append("-r") }
        if allowDowngrade { f.append("-d") }
        if grantRuntimePermissions { f.append("-g") }
        if allowTestPackages { f.append("-t") }
        if bypassLowTargetSDKBlock { f.append("--bypass-low-target-sdk-block") }
        return f
    }
}

public enum InstallStage: String, Sendable, Hashable, Codable {
    case inspecting, extracting, uploading, committing, copyingExpansionFiles, finished
}

public struct InstallProgress: Sendable, Hashable {
    public var stage: InstallStage
    public var currentFile: String?
    /// Bytes done / total for the current stage (uploading: all APKs; copyingExpansionFiles: all OBBs).
    public var bytesDone: UInt64
    public var bytesTotal: UInt64

    public init(stage: InstallStage, currentFile: String? = nil, bytesDone: UInt64 = 0, bytesTotal: UInt64 = 0) {
        self.stage = stage
        self.currentFile = currentFile
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
    }

    public var fraction: Double? { bytesTotal == 0 ? nil : min(1, Double(bytesDone) / Double(bytesTotal)) }
}

public typealias InstallProgressHandler = @Sendable (InstallProgress) -> Void

/// Installs APKs, split-APK sets, `.xapk`, `.apks` and `.apkm` bundles.
///
/// - Single APKs are streamed straight into `cmd package install -S <size>` over the adb `exec:` service:
///   no copy to `/data/local/tmp`, no extra disk use on the device, bounded memory on the host.
/// - Split sets use a PackageManager session (`install-create`, one streamed `install-write` per split,
///   `install-commit`), abandoning the session if anything fails.
/// - Bundles are inspected with `unzip`, only the splits matching the device's ABI/density/language are
///   extracted (to `~/.emuu/cache`, removed afterwards), and XAPK OBB files are pushed one at a time to
///   `/sdcard/Android/obb/<package>/` and deleted locally after each push, so a multi-GB game needs at most
///   one OBB's worth of scratch space.
/// - When the native protocol is unavailable it falls back to `adb install` / `adb install-multiple`.
///
/// PackageManager rejections come back as `InstallResult(status: .failed(code:message:))` with a
/// human-readable message; infrastructure failures (device gone, adb missing, I/O) are thrown.
public final class APKInstaller: Sendable {
    public let client: ADBClient
    public let zip: ZipTool
    public let cacheDirectory: URL
    private let log = EmuuLogger(category: "install")

    public init(client: ADBClient, cacheDirectory: URL = EmuuPaths.default().cacheDirectory, zip: ZipTool? = nil) {
        self.client = client
        self.cacheDirectory = cacheDirectory
        self.zip = zip ?? ZipTool(runner: client.runner)
    }

    /// Detects the kind from the file extension and installs.
    public func install(file: URL, options: InstallOptions = InstallOptions(), progress: InstallProgressHandler? = nil) async throws -> InstallResult {
        guard let source = InstallSource.detect(fileURL: file) else {
            throw EmuuError.unsupported("Unknown package type '.\(file.pathExtension)'. Supported: .apk, .xapk, .apks, .apkm.")
        }
        return try await install(source, options: options, progress: progress)
    }

    public func install(_ source: InstallSource, options: InstallOptions = InstallOptions(), progress: InstallProgressHandler? = nil) async throws -> InstallResult {
        let started = ContinuousClock.now
        var result: InstallResult
        do {
            for url in source.localFiles where !FileManager.default.fileExists(atPath: url.path) {
                throw EmuuError.io(path: url.path, message: "file not found")
            }
            switch source {
            case .apk(let url):
                result = try await installPlainAPKs([url], source: source, options: options, progress: progress)
            case .splitAPKs(let urls):
                guard !urls.isEmpty else { throw EmuuError.invalidConfiguration("split APK set is empty") }
                result = try await installPlainAPKs(urls, source: source, options: options, progress: progress)
            case .xapk(let url), .apks(let url), .apkm(let url):
                result = try await installBundle(url, source: source, options: options, progress: progress)
            case .playStore(let pkg):
                try await PlayStore(shell: client).openListing(packageName: pkg)
                result = InstallResult(source: source, packageName: pkg, status: .openedInPlayStore)
            }
        } catch EmuuError.install(let code, let message) {
            // Problems with the package itself (bad archive, no matching ABI) are results, not exceptions.
            result = InstallResult(source: source, packageName: nil, status: .failed(code: code, message: message))
        }
        result.duration = ContinuousClock.now - started
        progress?(InstallProgress(stage: .finished))
        switch result.status {
        case .installed: log.notice("installed \(result.packageName ?? "?") from \(source) in \(result.duration)")
        case .openedInPlayStore: log.notice("opened Play Store for \(result.packageName ?? "?")")
        case .failed(let code, _): log.warning("install of \(source) failed: \(code)")
        }
        return result
    }

    // MARK: Plain APKs

    private func installPlainAPKs(_ urls: [URL], source: InstallSource, options: InstallOptions, progress: InstallProgressHandler?) async throws -> InstallResult {
        progress?(InstallProgress(stage: .inspecting, currentFile: urls.first?.lastPathComponent))
        let spec = try await DeviceSpec.query(client)
        var manifest: APKManifest?
        var appABIs: [String] = []
        for url in urls {
            let entries = try await zip.list(url)
            guard entries.contains("AndroidManifest.xml") else {
                throw EmuuError.install(code: "INSTALL_PARSE_FAILED_NOT_APK", message: InstallFailureCatalog.explain(code: "INSTALL_PARSE_FAILED_NOT_APK", detail: url.lastPathComponent))
            }
            for abi in SplitSelector.nativeABIs(inAPKEntries: entries) where !appABIs.contains(abi) { appABIs.append(abi) }
            // Prefer the base APK's manifest (no `split` attribute) for the package name.
            if manifest == nil || manifest?.splitName != nil {
                if let m = try? await readManifest(url), manifest == nil || m.splitName == nil { manifest = m }
            }
        }
        try precheckABIs(appABIs: appABIs, spec: spec)
        let outcome = try await installFiles(urls, options: options, progress: progress)
        return makeResult(source: source, packageName: manifest?.packageName, outcome: outcome, apkCount: urls.count, appABIs: appABIs, spec: spec)
    }

    // MARK: Bundles

    private func installBundle(_ archive: URL, source: InstallSource, options: InstallOptions, progress: InstallProgressHandler?) async throws -> InstallResult {
        progress?(InstallProgress(stage: .inspecting, currentFile: archive.lastPathComponent))
        let entries = try await zip.list(archive)
        let spec = try await DeviceSpec.query(client)

        var bundle: BundleManifest?
        if case .xapk = source, let data = try await zip.read("manifest.json", from: archive) {
            bundle = try BundleManifest.parseXAPK(data)
        } else if case .apkm = source, let data = try await zip.read("info.json", from: archive) {
            bundle = BundleManifest.parseAPKMInfo(data)
        }

        let apkEntries = try Self.chooseAPKEntries(entries: entries, listed: bundle?.apkFiles ?? [], spec: spec)
        guard !apkEntries.isEmpty else {
            throw EmuuError.install(code: "EMUU_NO_APKS_IN_BUNDLE", message: "\(archive.lastPathComponent) does not contain any APK files.")
        }
        log.info("bundle \(archive.lastPathComponent): installing \(apkEntries.joined(separator: ", "))")

        let workDir = cacheDirectory.appendingPathComponent("install-\(UUID().uuidString)", isDirectory: true)
        defer {
            if !options.keepExtractedFiles { try? FileManager.default.removeItem(at: workDir) }
        }
        progress?(InstallProgress(stage: .extracting, currentFile: archive.lastPathComponent))
        let apkURLs = try await zip.extract(apkEntries, from: archive, to: workDir)

        var appABIs: [String] = []
        var packageName = bundle?.packageName
        for url in apkURLs {
            if let abiEntries = try? await zip.list(url) {
                for abi in SplitSelector.nativeABIs(inAPKEntries: abiEntries) where !appABIs.contains(abi) { appABIs.append(abi) }
            }
        }
        if packageName == nil {
            for url in apkURLs where SplitSelector.classify(fileName: url.lastPathComponent) == .other {
                if let m = try? await readManifest(url), m.splitName == nil { packageName = m.packageName; break }
            }
        }
        try precheckABIs(appABIs: appABIs, spec: spec)

        let outcome = try await installFiles(apkURLs, options: options, progress: progress)
        var result = makeResult(source: source, packageName: packageName, outcome: outcome, apkCount: apkURLs.count, appABIs: appABIs, spec: spec)
        // Free the extracted APKs before copying (possibly huge) OBBs.
        if !options.keepExtractedFiles { for url in apkURLs { try? FileManager.default.removeItem(at: url) } }

        guard result.succeeded, options.copyExpansionFiles else { return result }
        let expansions = Self.expansionFiles(entries: entries, bundle: bundle)
        guard !expansions.isEmpty else { return result }
        // The package name comes from the bundle's own manifest.json; it becomes part of a device path, so
        // a crafted one ("x/../../data/...") must not steer the OBB push elsewhere.
        guard let pkg = packageName, PlayStore.isValidPackageName(pkg) else {
            result.status = .failed(code: "EMUU_OBB_COPY_FAILED", message: packageName == nil
                ? "The app was installed, but its expansion (OBB) files were not copied because the package name is unknown."
                : "The app was installed, but its expansion (OBB) files were not copied because the bundle names an invalid package ('\(packageName!)').")
            return result
        }
        do {
            result.obbCount = try await copyExpansions(expansions, packageName: pkg, archive: archive, workDir: workDir, options: options, progress: progress)
        } catch let error as EmuuError {
            if case .deviceNotReady = error { throw error }
            result.status = .failed(code: "EMUU_OBB_COPY_FAILED", message: "The app was installed, but copying its game data (OBB) failed: \(error.localizedDescription) The game may not start until the data is copied; try installing again.")
        }
        return result
    }

    /// Chooses which APK entries of a bundle to install.
    /// - `.apks` from bundletool: `splits/*.apk` (filtered), else `universal.apk`, else the best `standalones/*.apk`.
    /// - `.xapk`: `split_apks` from manifest.json when present, else all `.apk` entries (filtered).
    /// - `.apkm` / SAI `.apks`: all `.apk` entries (filtered).
    static func chooseAPKEntries(entries: [String], listed: [String], spec: DeviceSpec) throws -> [String] {
        let apks = entries.filter { $0.lowercased().hasSuffix(".apk") && !$0.hasPrefix("Android/obb/") }
        if !listed.isEmpty {
            let present = listed.filter { entries.contains($0) }
            if !present.isEmpty { return try SplitSelector.select(present, for: spec).selected }
        }
        let splits = apks.filter { $0.hasPrefix("splits/") }
        if !splits.isEmpty { return try SplitSelector.select(splits, for: spec).selected }
        if apks.contains("universal.apk") { return ["universal.apk"] }
        let flat = apks.filter { !$0.hasPrefix("standalones/") }
        if !flat.isEmpty { return try SplitSelector.select(flat, for: spec).selected }
        let standalones = apks.filter { $0.hasPrefix("standalones/") }
        for abi in spec.abis {
            let token = abi.replacingOccurrences(of: "-", with: "_")
            if let match = standalones.first(where: { $0.contains(token) }) { return [match] }
        }
        if !standalones.isEmpty {
            throw EmuuError.install(code: "INSTALL_FAILED_NO_MATCHING_ABIS", message: InstallFailureCatalog.noMatchingABIsText(appABIs: [], deviceABIs: spec.abis))
        }
        return []
    }

    static func expansionFiles(entries: [String], bundle: BundleManifest?) -> [BundleManifest.Expansion] {
        if let listed = bundle?.expansions, !listed.isEmpty {
            return listed.filter { entries.contains($0.file) }
        }
        return entries.filter { $0.hasPrefix("Android/obb/") && $0.lowercased().hasSuffix(".obb") }
            .map { BundleManifest.Expansion(file: $0, installPath: $0) }
    }

    private func copyExpansions(_ expansions: [BundleManifest.Expansion], packageName: String, archive: URL, workDir: URL, options: InstallOptions, progress: InstallProgressHandler?) async throws -> Int {
        var copied = 0
        for exp in expansions {
            try Task.checkCancellation()
            progress?(InstallProgress(stage: .extracting, currentFile: (exp.file as NSString).lastPathComponent))
            guard let local = try await zip.extract([exp.file], from: archive, to: workDir).first else { continue }
            defer { try? FileManager.default.removeItem(at: local) }
            guard let remote = Self.remoteExpansionPath(exp, packageName: packageName) else {
                throw EmuuError.install(code: "EMUU_UNSAFE_ARCHIVE", message: "Expansion file '\(exp.file)' has an unsafe install path '\(exp.installPath)'.")
            }
            try await client.push(local, to: remote, idleTimeout: .seconds(120)) { p in
                progress?(InstallProgress(stage: .copyingExpansionFiles, currentFile: p.name, bytesDone: p.bytesTransferred, bytesTotal: p.totalBytes))
            }
            copied += 1
        }
        return copied
    }

    /// `/sdcard/<install_path>` when it points into this package's own `Android/obb/<pkg>/`, else
    /// `/sdcard/Android/obb/<pkg>/<file name>`. Nil when no safe destination exists (invalid package name,
    /// unusable file name). The result never leaves `/sdcard/Android/obb/<pkg>/`.
    static func remoteExpansionPath(_ exp: BundleManifest.Expansion, packageName: String) -> String? {
        guard PlayStore.isValidPackageName(packageName) else { return nil }
        let ownDir = "Android/obb/\(packageName)/"
        let path = String(exp.installPath.drop(while: { $0 == "/" }))
        if path.hasPrefix(ownDir), path.count > ownDir.count, ZipTool.isSafeEntryName(path),
           !path.split(separator: "/").contains(".") {
            return "/sdcard/" + path
        }
        let name = (exp.file as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return nil }
        return "/sdcard/" + ownDir + name
    }

    // MARK: PackageManager transport

    private func precheckABIs(appABIs: [String], spec: DeviceSpec) throws {
        guard !appABIs.isEmpty, Set(appABIs).isDisjoint(with: spec.abis) else { return }
        throw EmuuError.install(code: "INSTALL_FAILED_NO_MATCHING_ABIS", message: InstallFailureCatalog.noMatchingABIsText(appABIs: appABIs, deviceABIs: spec.abis))
    }

    private func readManifest(_ apk: URL) async throws -> APKManifest? {
        guard let data = try await zip.read("AndroidManifest.xml", from: apk) else { return nil }
        return try APKManifest.parse(binaryXML: data)
    }

    private func makeResult(source: InstallSource, packageName: String?, outcome: InstallFailureCatalog.Outcome, apkCount: Int, appABIs: [String], spec: DeviceSpec) -> InstallResult {
        switch outcome {
        case .success:
            return InstallResult(source: source, packageName: packageName, status: .installed, apkCount: apkCount)
        case .failure(let code, let detail):
            return InstallResult(source: source, packageName: packageName,
                                 status: .failed(code: code, message: InstallFailureCatalog.explain(code: code, detail: detail, appABIs: appABIs, deviceABIs: spec.abis)),
                                 apkCount: apkCount)
        }
    }

    /// Streams one or more APK files into PackageManager.
    func installFiles(_ urls: [URL], options: InstallOptions, progress: InstallProgressHandler?) async throws -> InstallFailureCatalog.Outcome {
        let sizes = try urls.map(ADBClient.fileSize)
        let total = sizes.reduce(0, +)
        let flags = options.packageManagerFlags.joined(separator: " ")
        if client.transport != .binary {
            do {
                if urls.count == 1 {
                    let output = try await client.execStreaming(
                        "cmd package install \(flags) -S \(sizes[0])", uploading: urls[0],
                        progress: uploadProgress(offset: 0, total: total, progress)
                    )
                    progress?(InstallProgress(stage: .committing))
                    return InstallFailureCatalog.parse(output)
                }
                return try await installSession(urls, sizes: sizes, total: total, flags: flags, progress: progress)
            } catch EmuuError.unsupported(let why) {
                log.info("streamed install unavailable (\(why)); falling back to adb install")
            }
        }
        progress?(InstallProgress(stage: .uploading, currentFile: urls.first?.lastPathComponent, bytesDone: 0, bytesTotal: total))
        let args = (urls.count == 1 ? ["install"] : ["install-multiple"]) + options.packageManagerFlags + urls.map(\.path)
        let result = try await client.adb(args, timeout: nil)
        return InstallFailureCatalog.parse(result.stdoutString + "\n" + result.stderrString)
    }

    private func installSession(_ urls: [URL], sizes: [UInt64], total: UInt64, flags: String, progress: InstallProgressHandler?) async throws -> InstallFailureCatalog.Outcome {
        let create = try await client.shell("cmd package install-create \(flags) -S \(total)", timeout: .seconds(60))
        let createText = create.stdoutString + create.stderrString
        guard let session = Self.parseSessionID(createText) else {
            if case .failure(let code, let detail) = InstallFailureCatalog.parse(createText) { return .failure(code: code, detail: detail) }
            throw EmuuError.parse("install-create returned no session id: \(createText.prefix(300))")
        }
        var committed = false
        do {
            var offset: UInt64 = 0
            for (index, url) in urls.enumerated() {
                try Task.checkCancellation()
                let name = "\(index)_" + Self.sanitizeSplitName(url.lastPathComponent)
                let output = try await client.execStreaming(
                    "cmd package install-write -S \(sizes[index]) \(session) \(name) -", uploading: url,
                    progress: uploadProgress(offset: offset, total: total, progress)
                )
                offset += sizes[index]
                if case .failure(let code, let detail) = InstallFailureCatalog.parse(output) {
                    await abandon(session)
                    return .failure(code: code, detail: detail)
                }
            }
            progress?(InstallProgress(stage: .committing, bytesDone: total, bytesTotal: total))
            committed = true
            let commit = try await client.shell("cmd package install-commit \(session)", timeout: .seconds(900))
            return InstallFailureCatalog.parse(commit.stdoutString + "\n" + commit.stderrString)
        } catch {
            if !committed { await abandon(session) }
            throw error
        }
    }

    private func abandon(_ session: Int) async {
        _ = try? await client.shell("cmd package install-abandon \(session)", timeout: .seconds(30))
    }

    private func uploadProgress(offset: UInt64, total: UInt64, _ progress: InstallProgressHandler?) -> TransferProgressHandler? {
        guard let progress else { return nil }
        return { p in
            progress(InstallProgress(stage: .uploading, currentFile: p.name, bytesDone: offset + p.bytesTransferred, bytesTotal: total))
        }
    }

    /// `Success: created install session [1234567]` → 1234567.
    static func parseSessionID(_ text: String) -> Int? {
        guard let open = text.range(of: "session ["), let close = text[open.upperBound...].firstIndex(of: "]") else { return nil }
        return Int(text[open.upperBound..<close])
    }

    static func sanitizeSplitName(_ name: String) -> String {
        String(name.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "." || $0 == "_" || $0 == "-" ? $0 : "_" })
    }
}

extension InstallSource {
    /// Local files this source reads.
    var localFiles: [URL] {
        switch self {
        case .apk(let u), .xapk(let u), .apks(let u), .apkm(let u): return [u]
        case .splitAPKs(let us): return us
        case .playStore: return []
        }
    }
}
