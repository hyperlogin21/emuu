import Foundation
import ArgumentParser
import EmuuBase

struct Logs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show logs: engine (default), supervisor, Emuu's own log, or the governor's sample CSV.",
        discussion: "Unified logging has everything too: log stream --predicate 'subsystem == \"dev.emuu\"'")

    enum Source: String, EnumerableFlag {
        case engine, supervisor, app, samples
        static func help(for value: Source) -> ArgumentHelp? {
            switch value {
            case .engine: return "Engine stdout/stderr (logs/engine-<id>.log)."
            case .supervisor: return "A --detach'ed supervisor's output (logs/supervisor-<id>.log)."
            case .app: return "Emuu's own log (logs/emuu.log)."
            case .samples: return "Memory samples CSV written by the governor (logs/memory-<id>.csv)."
            }
        }
    }

    @OptionGroup var target: TargetInstance
    @Flag var source: Source = .engine
    @Option(name: [.customShort("n"), .long], help: "Number of lines to show.") var lines = 50
    @Flag(name: .shortAndLong, help: "Keep printing new lines.") var follow = false
    @Flag(help: "Print the log file path and exit.") var path = false

    func run() async throws {
        let ctx = try CLIContext.live()
        let url: URL
        switch source {
        case .app:
            url = ctx.paths.mainLogFile
        case .engine:
            url = ctx.paths.engineLogFile(for: try ctx.resolveInstance(target.explicit).id)
        case .supervisor:
            url = SupervisorRegistry(paths: ctx.paths).logFile(for: try ctx.resolveInstance(target.explicit).id)
        case .samples:
            url = SupervisorRegistry(paths: ctx.paths).samplesFile(for: try ctx.resolveInstance(target.explicit).id)
        }
        if path { return Out.line(url.path) }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError("\(url.path) does not exist yet.")
        }
        var offset = try LogTail.printLastLines(of: url, count: max(0, lines))
        guard follow else { return }
        while !Task.isCancelled {
            try await Task.sleep(for: .milliseconds(500))
            offset = LogTail.printNew(url: url, from: offset)
        }
    }
}

enum LogTail {
    /// The last `count` lines of `data` (pure).
    static func lastLines(_ data: Data, count: Int) -> String {
        guard count > 0 else { return "" }
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last == "" { lines.removeLast() }
        return lines.suffix(count).joined(separator: "\n")
    }

    /// Prints the tail (reading at most the last 1 MiB) and returns the end offset.
    static func printLastLines(of url: URL, count: Int) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        let start = end > 1_048_576 ? end - 1_048_576 : 0
        try handle.seek(toOffset: start)
        let data = try handle.readToEnd() ?? Data()
        let text = lastLines(data, count: count)
        if !text.isEmpty { Out.line(text) }
        return end
    }

    /// Prints bytes appended since `offset`; starts over when the file was rotated (shrank).
    static func printNew(url: URL, from offset: UInt64) -> UInt64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return offset }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return offset }
        let from = end < offset ? 0 : offset
        guard end > from else { return end }
        try? handle.seek(toOffset: from)
        if let data = try? handle.readToEnd(), !data.isEmpty {
            FileHandle.standardOutput.write(data)
        }
        return end
    }
}
