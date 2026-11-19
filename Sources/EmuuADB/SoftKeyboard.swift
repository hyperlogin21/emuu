import Foundation
import EmuuBase

/// What the guest's input method is doing right now.
public struct SoftKeyboardState: Sendable, Hashable {
    /// The soft keyboard (IME window) is on screen (`mInputShown=true`).
    public var imeShown: Bool
    /// A text editor has input focus (`curEditorInfo` with a non-zero `inputType`).
    public var editorFocused: Bool

    public init(imeShown: Bool, editorFocused: Bool) {
        self.imeShown = imeShown
        self.editorFocused = editorFocused
    }
}

/// Result of `SoftKeyboard.apply`.
public enum SoftKeyboardOutcome: Sendable, Hashable {
    /// The keyboard was hidden and is now shown (the focused text field was tapped).
    case shown
    /// The keyboard was on screen and is now hidden (BACK, which only closes the IME).
    case hidden
    /// Nothing to do on screen right now; the preference applies to the next text field.
    case noTextField
    /// Already in the requested state.
    case unchanged
}

/// Device commands and parsers for the on-screen keyboard (pure; unit-tested).
///
/// Empirical findings on the android-36.1 Play Store image (non-root `shell`, Gboard, `hw.keyboard=yes`):
/// * Gboard shows its keyboard when a text field gains focus, whatever `show_ime_with_hard_keyboard` says
///   and even after key events from the emulator's own hardware keyboard (`qwerty2`). Key events injected
///   through the display (hardware key events) do not hide it either, so Mac typing and the soft keyboard
///   coexist.
/// * There is no shell command to show or hide the IME (`cmd input_method` only offers `ime` and `tracing`;
///   `ime disable` just falls back to the voice IME). What works: BACK while the IME is shown closes only the
///   IME (focus stays), and tapping the focused field brings it back.
/// * `dumpsys input_method` (≈0.1 s) tells both facts: `mInputShown=` and the `curEditorInfo` input type.
/// * `uiautomator dump` returns the focused node's bounds (≈1 s), used only when the button asks to show it.
/// `show_ime_with_hard_keyboard` (Settings › Physical keyboard › "Use on-screen keyboard") is still kept in
/// sync with the preference, so Android's own setting agrees and devices that honour it behave the same.
public enum SoftKeyboardCommands {
    public static let state = "dumpsys input_method | grep -E -A1 'mInputShown=|curEditorInfo:'"
    public static func setting(show: Bool) -> String { "settings put secure show_ime_with_hard_keyboard \(show ? 1 : 0)" }
    public static let readSetting = "settings get secure show_ime_with_hard_keyboard"
    /// KEYCODE_BACK; only sent while the IME is shown, when it closes the IME and nothing else.
    public static let hide = "input keyevent 4"
    public static let dumpUI = "uiautomator dump /dev/tty"
    public static func tap(x: Int, y: Int) -> String { "input tap \(x) \(y)" }

    public static func parseState(_ text: String) -> SoftKeyboardState {
        var shown = false
        var editor = false
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        for (i, line) in lines.enumerated() {
            if line.hasPrefix("mInputShown=") { shown = shown || line == "mInputShown=true" }
            if line.hasPrefix("curEditorInfo:"), i + 1 < lines.count {
                let next = lines[i + 1]
                if let r = next.range(of: "inputType=0x") {
                    let hex = next[r.upperBound...].prefix { $0.isHexDigit }
                    if let v = UInt32(hex, radix: 16), v != 0 { editor = true }
                }
            }
        }
        return SoftKeyboardState(imeShown: shown, editorFocused: editor)
    }

    /// Center of the focused editable node in a `uiautomator dump`, in device pixels.
    public static func focusedEditableCenter(uiXML: String) -> (x: Int, y: Int)? {
        var candidates: [(editable: Bool, x: Int, y: Int)] = []
        var rest = uiXML[...]
        while let start = rest.range(of: "<node ") {
            let tail = rest[start.upperBound...]
            guard let end = tail.firstIndex(of: ">") else { break }
            let node = tail[..<end]
            rest = tail[end...]
            guard node.contains("focused=\"true\""), let bounds = attribute("bounds", in: node),
                  let c = center(of: bounds) else { continue }
            let cls = attribute("class", in: node) ?? ""
            candidates.append((cls.contains("EditText") || cls.contains("AutoCompleteTextView"), c.x, c.y))
        }
        let best = candidates.first { $0.editable } ?? candidates.last
        return best.map { ($0.x, $0.y) }
    }

    private static func attribute(_ name: String, in node: Substring) -> String? {
        guard let r = node.range(of: " \(name)=\"") else { return nil }
        let v = node[r.upperBound...].prefix { $0 != "\"" }
        return String(v)
    }

    /// "[96,667][624,784]" → (360, 725)
    static func center(of bounds: String) -> (x: Int, y: Int)? {
        let nums = bounds.split(whereSeparator: { "[],".contains($0) }).compactMap { Int($0) }
        guard nums.count == 4, nums[2] > nums[0], nums[3] > nums[1] else { return nil }
        return ((nums[0] + nums[2]) / 2, (nums[1] + nums[3]) / 2)
    }
}

/// Shows/hides the guest's on-screen keyboard and keeps it in line with the user's preference.
public struct SoftKeyboard: Sendable {
    public let shell: any DeviceShell

    public init(shell: any DeviceShell) { self.shell = shell }

    public func state() async throws -> SoftKeyboardState {
        let r = try await shell.shell(SoftKeyboardCommands.state, timeout: .seconds(10))
        return SoftKeyboardCommands.parseState(r.stdoutString)
    }

    /// Applies the preference: persists Android's "use on-screen keyboard" setting, then shows the keyboard
    /// for a focused text field (`show`) or hides a visible one (`!show`).
    /// - Parameter lastTap: where the user last tapped (device pixels). Compose text fields often do not report
    ///   `focused="true"` in `uiautomator dump` (measured with Contacts on android-36.1), so when no focused
    ///   node is found the field the user tapped is tapped again.
    @discardableResult
    public func apply(show: Bool, lastTap: (x: Int, y: Int)? = nil) async throws -> SoftKeyboardOutcome {
        try await shell.shell(SoftKeyboardCommands.setting(show: show), timeout: .seconds(10)).checked()
        let st = try await state()
        if show {
            if st.imeShown { return .unchanged }
            guard st.editorFocused else { return .noTextField }
            let dump = try await shell.shell(SoftKeyboardCommands.dumpUI, timeout: .seconds(20))
            guard let c = SoftKeyboardCommands.focusedEditableCenter(uiXML: dump.stdoutString) ?? lastTap else { return .noTextField }
            try await shell.shell(SoftKeyboardCommands.tap(x: c.x, y: c.y), timeout: .seconds(10)).checked()
            return .shown
        } else {
            guard st.imeShown else { return st.editorFocused ? .unchanged : .noTextField }
            try await shell.shell(SoftKeyboardCommands.hide, timeout: .seconds(10)).checked()
            return .hidden
        }
    }

    /// With the keyboard turned off: closes the IME if a tap just brought it up. Returns true if it hid it.
    @discardableResult
    public func enforceHidden() async throws -> Bool {
        guard try await state().imeShown else { return false }
        try await shell.shell(SoftKeyboardCommands.hide, timeout: .seconds(10)).checked()
        return true
    }
}
