import Darwin
import Foundation
import EmuuBase

/// Thin wrapper over `/usr/bin/unzip` (Info-ZIP 6.00 with Zip64 + large-file support on macOS),
/// run through `ProcessRunner`. Extraction streams to disk, so multi-GB archives never sit in memory.
public struct ZipTool: Sendable {
    public let runner: any ProcessRunner
    public let unzip: URL

    public init(runner: any ProcessRunner, unzip: URL = URL(fileURLWithPath: "/usr/bin/unzip")) {
        self.runner = runner
        self.unzip = unzip
    }

    /// Entry names (files only, directories skipped).
    public func list(_ archive: URL) async throws -> [String] {
        let result = try await runner.run(ProcessRequest(executable: unzip, arguments: ["-Z1", archive.path], timeout: .seconds(120)))
        guard result.succeeded else { throw Self.error(result, archive: archive) }
        return result.stdoutString.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasSuffix("/") }
    }

    /// Reads one (small) entry into memory. nil if the entry does not exist.
    public func read(_ entry: String, from archive: URL, maxBytes: Int = 16 * 1024 * 1024) async throws -> Data? {
        let result = try await runner.run(ProcessRequest(
            executable: unzip, arguments: ["-p", archive.path, Self.literalPattern(entry)], timeout: .seconds(120)
        ))
        if result.exitCode == 11 { return nil }  // "filename not matched"
        guard result.succeeded else { throw Self.error(result, archive: archive) }
        guard result.stdout.count <= maxBytes else { throw EmuuError.io(path: archive.path, message: "\(entry) is larger than \(maxBytes) bytes") }
        return result.stdout
    }

    /// Extracts `entries` into `directory` (keeping their relative paths) and returns the extracted file URLs
    /// in the same order. Entry names that would escape `directory` are rejected, and so is anything that is
    /// not a plain file once on disk: Info-ZIP recreates symlink entries as real symlinks, and pushing such a
    /// "file" to the device would upload whatever host file it points at (e.g. `~/.ssh/id_ed25519`).
    public func extract(_ entries: [String], from archive: URL, to directory: URL) async throws -> [URL] {
        guard !entries.isEmpty else { return [] }
        for e in entries where !Self.isSafeEntryName(e) {
            throw EmuuError.install(code: "EMUU_UNSAFE_ARCHIVE", message: "Archive entry '\(e)' has an unsafe path; refusing to extract.")
        }
        // Refuse before writing anything if a requested entry, or one of its parent paths, is a symlink entry.
        let links = try await symlinkEntries(archive)
        if !links.isEmpty {
            for e in entries {
                let components = e.split(separator: "/").map(String.init)
                for i in 1...components.count where links.contains(components[0..<i].joined(separator: "/")) {
                    throw Self.unsafeLink(e, archive: archive)
                }
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = try await runner.run(ProcessRequest(
            executable: unzip,
            arguments: ["-o", "-qq", archive.path] + entries.map(Self.literalPattern) + ["-d", directory.path],
            timeout: nil
        ))
        // 0 = ok, 1 = warnings only.
        guard result.exitCode == 0 || result.exitCode == 1 else { throw Self.error(result, archive: archive) }
        let urls = entries.map { directory.appendingPathComponent($0, isDirectory: false) }
        for (entry, url) in zip(entries, urls) {
            switch Self.plainFileCheck(entry, in: directory) {
            case .ok: continue
            case .missing:
                throw EmuuError.io(path: url.path, message: "unzip did not produce this file (\(result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)))")
            case .notPlain:
                // Remove what was extracted so nothing else can follow it.
                for u in urls { try? FileManager.default.removeItem(at: u) }
                throw Self.unsafeLink(entry, archive: archive)
            }
        }
        return urls
    }

    enum PlainFileCheck: Equatable { case ok, missing, notPlain }

    /// lstat of every path component below `directory`: parents must be real directories, the entry a
    /// regular file. Nothing is followed.
    static func plainFileCheck(_ entry: String, in directory: URL) -> PlainFileCheck {
        var path = directory.path
        let components = entry.split(separator: "/").map(String.init)
        for (i, c) in components.enumerated() {
            path += "/" + c
            var st = stat()
            guard lstat(path, &st) == 0 else { return .missing }
            let type = st.st_mode & S_IFMT
            if i == components.count - 1 { return type == S_IFREG ? .ok : .notPlain }
            if type != S_IFDIR { return .notPlain }
        }
        return .missing
    }

    /// Names of symlink entries, from `zipinfo -s` (mode column starting with `l`). The name is everything after
    /// the eight fixed columns (it may contain spaces).
    public func symlinkEntries(_ archive: URL) async throws -> Set<String> {
        let result = try await runner.run(ProcessRequest(executable: unzip, arguments: ["-Z", "-s", archive.path], timeout: .seconds(120)))
        guard result.succeeded else { throw Self.error(result, archive: archive) }
        return Self.symlinkEntries(inZipinfo: result.stdoutString)
    }

    static func symlinkEntries(inZipinfo text: String) -> Set<String> {
        var out: Set<String> = []
        for line in text.split(whereSeparator: \.isNewline) where line.first == "l" {
            let fields = line.split(maxSplits: 8, omittingEmptySubsequences: true, whereSeparator: { $0 == " " })
            guard fields.count == 9 else { continue }
            var name = String(fields[8])
            while name.hasSuffix("/") { name.removeLast() }
            out.insert(name)
        }
        return out
    }

    static func unsafeLink(_ entry: String, archive: URL) -> EmuuError {
        .install(code: "EMUU_UNSAFE_ARCHIVE", message: "\(archive.lastPathComponent) stores '\(entry)' as a symbolic link (or below one); refusing to install from it, because the link could point at files on this Mac.")
    }

    /// unzip treats member names as wildcard patterns; bracket-escape the metacharacters.
    static func literalPattern(_ name: String) -> String {
        var out = ""
        for ch in name {
            switch ch {
            case "[": out += "[[]"
            case "*": out += "[*]"
            case "?": out += "[?]"
            default: out.append(ch)
            }
        }
        return out
    }

    static func isSafeEntryName(_ name: String) -> Bool {
        if name.isEmpty || name.hasPrefix("/") || name.hasPrefix("\\") { return false }
        return !name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains("..")
    }

    static func error(_ result: ProcessResult, archive: URL) -> EmuuError {
        let text = (result.stderrString + result.stdoutString).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.localizedCaseInsensitiveContains("password") || text.localizedCaseInsensitiveContains("encrypted") {
            return .install(code: "EMUU_ENCRYPTED_ARCHIVE", message: "\(archive.lastPathComponent) is encrypted (for example an APKMirror-encrypted .apkm). Emuu cannot decrypt it; download the unencrypted bundle instead.")
        }
        if result.exitCode == 9 || text.contains("End-of-central-directory signature not found") {
            return .install(code: "EMUU_NOT_A_ZIP", message: "\(archive.lastPathComponent) is not a valid ZIP archive (it may be truncated or corrupt).")
        }
        return .io(path: archive.path, message: "unzip failed (exit \(result.exitCode)): \(String(text.suffix(500)))")
    }
}
