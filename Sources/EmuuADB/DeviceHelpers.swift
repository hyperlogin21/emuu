import Foundation
import EmuuBase

/// Miscellaneous device helpers: screenshots, fallback input, clipboard, properties.
///
/// Input here goes through the `input` shell tool (one process per event on the device) and is a
/// fallback: the interactive path is the engine's gRPC input in EmuuDisplay.
public struct DeviceHelpers: Sendable {
    public let client: ADBClient

    public init(client: ADBClient) {
        self.client = client
    }

    static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    /// PNG screenshot via `exec-out screencap -p` (binary-safe, no pty mangling).
    public func screenshotPNG(timeout: Duration = .seconds(30)) async throws -> Data {
        let data = try await client.execOut("screencap -p", timeout: timeout)
        guard data.starts(with: Self.pngSignature) else {
            let text = String(decoding: data.prefix(200), as: UTF8.self)
            throw EmuuError.adb("screencap did not return a PNG\(text.isEmpty ? "" : ": \(text)")")
        }
        return data
    }

    // MARK: Input (fallback)

    /// Types ASCII text with `input text`. Spaces become `%s` (the tool's escape for space).
    public func inputText(_ text: String) async throws {
        guard text.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 && $0.value < 0x7F }) else {
            throw EmuuError.unsupported("`input text` only types printable ASCII; use the display's clipboard paste for other text")
        }
        guard !text.isEmpty else { return }
        let escaped = text.replacingOccurrences(of: " ", with: "%s")
        try await client.shell("input text \(DeviceShellQuoting.quote(escaped))", timeout: .seconds(30)).checked()
    }

    /// `input keyevent <code>` — numeric code or name (`KEYCODE_HOME`, `HOME`, `3`).
    public func keyEvent(_ key: String, longPress: Bool = false) async throws {
        guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
            throw EmuuError.invalidConfiguration("invalid key code '\(key)'")
        }
        try await client.shell("input keyevent \(longPress ? "--longpress " : "")\(key)", timeout: .seconds(15)).checked()
    }

    public func tap(x: Int, y: Int) async throws {
        try await client.shell("input tap \(x) \(y)", timeout: .seconds(15)).checked()
    }

    public func swipe(fromX: Int, fromY: Int, toX: Int, toY: Int, duration: Duration = .milliseconds(300)) async throws {
        let ms = Int(duration.timeInterval * 1000)
        try await client.shell("input swipe \(fromX) \(fromY) \(toX) \(toY) \(ms)", timeout: .seconds(15)).checked()
    }

    /// Wakes the screen and dismisses a non-secure keyguard.
    public func wakeAndUnlock() async throws {
        try await client.shell("input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard", timeout: .seconds(15)).checked()
    }

    // MARK: Clipboard

    /// Sets the device clipboard through `cmd clipboard`, when this Android version offers a
    /// set command in its shell interface. Throws `.unsupported` otherwise (EmuuDisplay can set the
    /// clipboard through the engine's gRPC clipboard instead).
    public func setClipboard(_ text: String) async throws {
        let help = try await client.shell("cmd clipboard help 2>&1", timeout: .seconds(10)).stdoutString
        guard let command = Self.clipboardSetCommand(fromHelp: help) else {
            throw EmuuError.unsupported("this Android version has no shell command to set the clipboard; use the display's clipboard sync (engine gRPC)")
        }
        let r = try await client.shell("cmd clipboard \(command) \(DeviceShellQuoting.quote(text))", timeout: .seconds(10))
        try r.checked()
    }

    /// Reads the clipboard when `cmd clipboard` offers a get command; nil otherwise.
    public func clipboard() async throws -> String? {
        let help = try await client.shell("cmd clipboard help 2>&1", timeout: .seconds(10)).stdoutString
        guard help.contains("get-primary-clip") else { return nil }
        return try await client.shell("cmd clipboard get-primary-clip", timeout: .seconds(10)).checked().stdoutString
    }

    static func clipboardSetCommand(fromHelp help: String) -> String? {
        help.contains("set-primary-clip") ? "set-primary-clip" : nil
    }

    // MARK: Properties

    /// All system properties (`getprop`), one round trip.
    public func properties() async throws -> [String: String] {
        Self.parseGetprop(try await client.shell("getprop", timeout: .seconds(15)).checked().stdoutString)
    }

    /// Parses `[key]: [value]` lines (values may contain `]`).
    static func parseGetprop(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r "))
            guard line.hasPrefix("["), let sep = line.range(of: "]: [") , line.hasSuffix("]") else { continue }
            let key = String(line[line.index(after: line.startIndex)..<sep.lowerBound])
            let value = String(line[sep.upperBound..<line.index(before: line.endIndex)])
            out[key] = value
        }
        return out
    }

    /// Commonly needed device facts.
    public struct Summary: Sendable, Hashable, Codable {
        public var model: String?
        public var androidVersion: String?
        public var sdkLevel: Int?
        public var abis: [String]
        public var bootCompleted: Bool
    }

    public func summary() async throws -> Summary {
        let p = try await properties()
        return Summary(model: p["ro.product.model"], androidVersion: p["ro.build.version.release"],
                       sdkLevel: p["ro.build.version.sdk"].flatMap { Int($0) },
                       abis: (p["ro.product.cpu.abilist"] ?? "").split(separator: ",").map(String.init),
                       bootCompleted: p["sys.boot_completed"] == "1")
    }
}
