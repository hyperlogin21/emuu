import Foundation
import EmuuBase

/// Order-preserving `key=value` file as used by the engine (`config.ini`, `<name>.ini`,
/// `source.properties`, `hardware-qemu.ini`). Both `key=value` and `key = value` are accepted on read.
/// Lines starting with `#` or `;` and blank lines are ignored. Later duplicates win.
public struct IniFile: Sendable, Hashable {
    public private(set) var entries: [(key: String, value: String)]

    public init(entries: [(key: String, value: String)] = []) {
        self.entries = []
        for e in entries { self[e.key] = e.value }
    }

    public init(parsing text: String) {
        self.entries = []
        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";"),
                  let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            self[key] = value
        }
    }

    public init(contentsOf url: URL) throws {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            self.init(parsing: text)
        } catch {
            throw EmuuError.io(path: url.path, message: error.localizedDescription)
        }
    }

    public subscript(key: String) -> String? {
        get { entries.last(where: { $0.key == key })?.value }
        set {
            if let newValue {
                if let idx = entries.firstIndex(where: { $0.key == key }) {
                    entries[idx].value = newValue
                    // Drop later duplicates, keeping the first position.
                    var seen = false
                    entries.removeAll { e in
                        guard e.key == key else { return false }
                        defer { seen = true }
                        return seen
                    }
                } else {
                    entries.append((key, newValue))
                }
            } else {
                entries.removeAll { $0.key == key }
            }
        }
    }

    public var keys: [String] { entries.map(\.key) }

    /// `key=value` lines, in insertion order, newline-terminated (the format avdmanager writes).
    public func serialized() -> String {
        entries.map { "\($0.key)=\($0.value)\n" }.joined()
    }

    /// Atomic write (temp file + rename).
    public func write(to url: URL) throws {
        do {
            try Data(serialized().utf8).write(to: url, options: .atomic)
        } catch {
            throw EmuuError.io(path: url.path, message: error.localizedDescription)
        }
    }

    public static func == (lhs: IniFile, rhs: IniFile) -> Bool {
        lhs.entries.count == rhs.entries.count && zip(lhs.entries, rhs.entries).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    }

    public func hash(into hasher: inout Hasher) {
        for e in entries {
            hasher.combine(e.key)
            hasher.combine(e.value)
        }
    }
}
