import Foundation

/// Incremental byte-to-line splitter. Handles `\n` and `\r\n`, decodes UTF-8 lossily, and caps
/// line length so a process that never prints a newline cannot grow memory without bound.
public struct LineSplitter: Sendable {
    public let maxLineBytes: Int
    private var buffer = Data()

    public init(maxLineBytes: Int = 64 * 1024) {
        self.maxLineBytes = maxLineBytes
    }

    /// Feeds bytes; returns every complete line (without terminators).
    public mutating func feed(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer[buffer.startIndex..<nl]
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            lines.append(String(decoding: lineData, as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        while buffer.count > maxLineBytes {
            let chunk = buffer.prefix(maxLineBytes)
            lines.append(String(decoding: chunk, as: UTF8.self))
            buffer.removeFirst(maxLineBytes)
        }
        if buffer.isEmpty { buffer = Data() } // re-base indices
        return lines
    }

    /// Flushes a trailing partial line at EOF.
    public mutating func finish() -> String? {
        guard !buffer.isEmpty else { return nil }
        var rest = buffer
        if rest.last == 0x0D { rest = rest.dropLast() }
        buffer = Data()
        return String(decoding: rest, as: UTF8.self)
    }
}
