import Foundation
import AppKit
import Carbon.HIToolbox
import EmuuGRPC

/// macOS virtual key codes (`kVK_*`) the engine translates to evdev itself (`KeyboardEvent` with
/// `codeType = Mac`, chromium's keycode tables), so Android sees a real hardware keyboard: KEY_DOWN/KEY_UP,
/// repeats and modifiers, which games need.
public enum MacKeyMap {
    /// Keys sent by physical position (layout-independent).
    public static let positional: Set<Int> = {
        var s: Set<Int> = [
            kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H,
            kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P,
            kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X,
            kVK_ANSI_Y, kVK_ANSI_Z,
            kVK_Return, kVK_Tab, kVK_Space, kVK_Delete, kVK_ForwardDelete, kVK_Escape,
            kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown,
            kVK_Shift, kVK_RightShift, kVK_Control, kVK_RightControl, kVK_Option, kVK_RightOption, kVK_CapsLock,
            kVK_VolumeUp, kVK_VolumeDown, kVK_Mute,
            kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4,
            kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9,
            kVK_ANSI_KeypadDecimal, kVK_ANSI_KeypadMultiply, kVK_ANSI_KeypadPlus, kVK_ANSI_KeypadMinus,
            kVK_ANSI_KeypadDivide, kVK_ANSI_KeypadEnter, kVK_ANSI_KeypadEquals,
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
        ]
        s.formUnion(layoutDependent)
        return s
    }()

    /// Keys whose character depends on the keyboard layout (digits, punctuation).
    public static let layoutDependent: Set<Int> = [
        kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8,
        kVK_ANSI_9, kVK_ANSI_Minus, kVK_ANSI_Equal, kVK_ANSI_LeftBracket, kVK_ANSI_RightBracket, kVK_ANSI_Backslash,
        kVK_ANSI_Semicolon, kVK_ANSI_Quote, kVK_ANSI_Comma, kVK_ANSI_Period, kVK_ANSI_Slash, kVK_ANSI_Grave,
    ]

    public static let modifierFlags: [Int: NSEvent.ModifierFlags] = [
        kVK_Shift: .shift, kVK_RightShift: .shift, kVK_Control: .control, kVK_RightControl: .control,
        kVK_Option: .option, kVK_RightOption: .option, kVK_CapsLock: .capsLock,
    ]

    static let usUnshifted: [Int: String] = [
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4", kVK_ANSI_5: "5",
        kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",",
        kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`",
    ]
}

/// A host key event reduced to what translation needs (keeps the translator independent of `NSEvent`).
public struct HostKeyEvent: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case down, up }
    public var kind: Kind
    public var keyCode: UInt16
    /// `NSEvent.characters` (after modifiers), if any.
    public var characters: String?
    public var modifierFlagsRawValue: UInt
    public var isRepeat: Bool

    public var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue) }

    public init(kind: Kind, keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags, isRepeat: Bool = false) {
        self.kind = kind
        self.keyCode = keyCode
        self.characters = characters
        self.modifierFlagsRawValue = modifiers.rawValue
        self.isRepeat = isRepeat
    }
}

/// Converts host key events to engine key events:
///
/// - Letters, space, Enter, Backspace, arrows, F-keys, modifiers…: the **physical key** (Mac key code) as
///   KEY_DOWN/KEY_UP, so games get real key state and Android's keymap applies Shift/Ctrl.
/// - Digits and punctuation: the physical key when the host produced the US character for it (the guest's
///   keymap is US); otherwise (other layouts, shifted symbols on non-US layouts) the produced character as a
///   W3C `key` press, which the engine turns into the right key + Shift sequence.
/// - Option-composed or non-ASCII characters: sent as `text` (the engine only translates printable ASCII
///   reliably; others may be dropped).
/// - With Control held everything is positional (Ctrl+A, Ctrl+C…).
public struct KeyEventTranslator: Sendable {
    private var pressed: Set<UInt16> = []

    public init() {}

    public var pressedKeyCount: Int { pressed.count }

    public mutating func translate(_ event: HostKeyEvent) -> [EmulatorInputEvent] {
        let code = Int(event.keyCode)
        if event.kind == .up {
            guard pressed.remove(event.keyCode) != nil else { return [] }
            return [.key(.macKey(event.keyCode, .keyup))]
        }
        let ctrl = event.modifiers.contains(.control)
        let option = event.modifiers.contains(.option)
        let shift = event.modifiers.contains(.shift)
        let printable = Self.isPrintable(event.characters)
        let chars = event.characters ?? ""

        var positional = MacKeyMap.positional.contains(code)
        if positional, !ctrl, printable {
            if MacKeyMap.layoutDependent.contains(code) {
                // Physical key only when it yields the US unshifted (or US shifted, handled by the guest) char.
                positional = !option && (chars == MacKeyMap.usUnshifted[code] || shift && Self.isASCIIPrintable(chars) && Self.usShiftedMatches(code, chars))
            } else if option {
                positional = false   // Option+letter composes (å, ∂…)
            }
        }
        if positional {
            pressed.insert(event.keyCode)
            return [.key(.macKey(event.keyCode, .keydown))]
        }
        guard printable else { return [] }
        if Self.isASCIIPrintable(chars) {
            return chars.map { .key(.key(String($0), .keypress)) }
        }
        return [.key(EmulatorKeyEvent(text: chars))]
    }

    /// Modifier key alone (`flagsChanged`): DOWN when the flag appears, UP when it disappears.
    public mutating func modifierChanged(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> [EmulatorInputEvent] {
        guard let flag = MacKeyMap.modifierFlags[Int(keyCode)] else { return [] }
        if flags.contains(flag) {
            guard pressed.insert(keyCode).inserted else { return [] }
            if flag == .capsLock {
                pressed.remove(keyCode)
                return [.key(.macKey(keyCode, .keypress))]
            }
            return [.key(.macKey(keyCode, .keydown))]
        }
        guard pressed.remove(keyCode) != nil else { return flag == .capsLock ? [.key(.macKey(keyCode, .keypress))] : [] }
        return [.key(.macKey(keyCode, .keyup))]
    }

    /// Releases every held key (window lost focus).
    public mutating func releaseAll() -> [EmulatorInputEvent] {
        let ups = pressed.sorted().map { EmulatorInputEvent.key(.macKey($0, .keyup)) }
        pressed.removeAll()
        return ups
    }

    static let usShifted: [Int: String] = [
        kVK_ANSI_0: ")", kVK_ANSI_1: "!", kVK_ANSI_2: "@", kVK_ANSI_3: "#", kVK_ANSI_4: "$", kVK_ANSI_5: "%",
        kVK_ANSI_6: "^", kVK_ANSI_7: "&", kVK_ANSI_8: "*", kVK_ANSI_9: "(",
        kVK_ANSI_Minus: "_", kVK_ANSI_Equal: "+", kVK_ANSI_LeftBracket: "{", kVK_ANSI_RightBracket: "}",
        kVK_ANSI_Backslash: "|", kVK_ANSI_Semicolon: ":", kVK_ANSI_Quote: "\"", kVK_ANSI_Comma: "<",
        kVK_ANSI_Period: ">", kVK_ANSI_Slash: "?", kVK_ANSI_Grave: "~",
    ]

    static func usShiftedMatches(_ code: Int, _ chars: String) -> Bool { usShifted[code] == chars }

    static func isPrintable(_ s: String?) -> Bool {
        guard let s, !s.isEmpty else { return false }
        return s.unicodeScalars.allSatisfy { scalar in
            !(scalar.value < 0x20 || scalar.value == 0x7F || (0x80..<0xA0).contains(scalar.value)
              || (0xF700...0xF8FF).contains(scalar.value))
        }
    }

    static func isASCIIPrintable(_ s: String?) -> Bool {
        guard let s, !s.isEmpty else { return false }
        return s.unicodeScalars.allSatisfy { (0x20..<0x7F).contains($0.value) }
    }
}
