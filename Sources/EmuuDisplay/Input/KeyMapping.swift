import Foundation
import AppKit
import Carbon.HIToolbox
import EmuuGRPC

/// Linux evdev key codes (`input-event-codes.h`). Emuu sends every key as `KeyboardEvent{codeType: Evdev}`:
/// the guest's keyboard device (`qwerty2`, goldfish key layout + US character map) turns them into Android keys.
///
/// Why not the engine's Mac key codes (`codeType: Mac`): kVK_ANSI_A is 0, the protobuf default, so the engine
/// never sees a key code for the A key and drops it, and a key held that way is auto-repeated by the engine (one
/// stuck key typed 362 characters). Why not the `text` / `key` fields: `text` maps "é" to "-" and drops CJK and
/// emoji, and text/key events are not ordered with key-code events. (All measured on 36.4.9, android-36.1.)
///
/// `qwerty2.kl` is the emulator's phone layout, not a PC keyboard (measured key by key): KEY_ESC is BACK, KEY_HOME
/// is the HOME button, KEY_END is ENDCALL (sleeps the device), F1–F4/F10 are MENU/SOFT_RIGHT/CALL/ENDCALL/MENU,
/// the grave key is code 399 (not 41), and Page Up/Down, Insert, the keypad and F5–F12 are KEYCODE_UNKNOWN. Emuu
/// therefore never sends 102, 107 or F-keys; Home/End/Page Up/Down become Android's Alt+arrow movements.
public enum EvdevKey {
    public static let esc = 1, backspace = 14, tab = 15, enter = 28, leftCtrl = 29, leftShift = 42, rightShift = 54
    public static let leftAlt = 56, space = 57, rightCtrl = 97, rightAlt = 100, grave = 399
    public static let up = 103, left = 105, right = 106, down = 108
    public static let delete = 111, volumeDown = 114, volumeUp = 115, back = 158
    public static let a = 30, c = 46, v = 47, x = 45, z = 44
}

/// Host key code (`kVK_*`) → evdev, by physical position. Used for non-character keys and for Control chords
/// (games and Android shortcuts go by key, not by character). Only codes `qwerty2` maps to a harmless Android key.
public enum MacKeyMap {
    public static let evdev: [Int: Int] = [
        kVK_ANSI_A: 30, kVK_ANSI_B: 48, kVK_ANSI_C: 46, kVK_ANSI_D: 32, kVK_ANSI_E: 18, kVK_ANSI_F: 33, kVK_ANSI_G: 34,
        kVK_ANSI_H: 35, kVK_ANSI_I: 23, kVK_ANSI_J: 36, kVK_ANSI_K: 37, kVK_ANSI_L: 38, kVK_ANSI_M: 50, kVK_ANSI_N: 49,
        kVK_ANSI_O: 24, kVK_ANSI_P: 25, kVK_ANSI_Q: 16, kVK_ANSI_R: 19, kVK_ANSI_S: 31, kVK_ANSI_T: 20, kVK_ANSI_U: 22,
        kVK_ANSI_V: 47, kVK_ANSI_W: 17, kVK_ANSI_X: 45, kVK_ANSI_Y: 21, kVK_ANSI_Z: 44,
        kVK_ANSI_1: 2, kVK_ANSI_2: 3, kVK_ANSI_3: 4, kVK_ANSI_4: 5, kVK_ANSI_5: 6, kVK_ANSI_6: 7, kVK_ANSI_7: 8,
        kVK_ANSI_8: 9, kVK_ANSI_9: 10, kVK_ANSI_0: 11,
        kVK_ANSI_Minus: 12, kVK_ANSI_Equal: 13, kVK_ANSI_LeftBracket: 26, kVK_ANSI_RightBracket: 27,
        kVK_ANSI_Semicolon: 39, kVK_ANSI_Quote: 40, kVK_ANSI_Grave: EvdevKey.grave, kVK_ANSI_Backslash: 43, kVK_ANSI_Comma: 51,
        kVK_ANSI_Period: 52, kVK_ANSI_Slash: 53, kVK_Space: 57,
        kVK_Escape: 1, kVK_Delete: 14, kVK_Tab: 15, kVK_Return: 28, kVK_ANSI_KeypadEnter: 28,
        kVK_Control: 29, kVK_RightControl: 97, kVK_Shift: 42, kVK_RightShift: 54, kVK_Option: 56, kVK_RightOption: 100,
        kVK_UpArrow: 103, kVK_LeftArrow: 105, kVK_RightArrow: 106, kVK_DownArrow: 108, kVK_ForwardDelete: 111,
        kVK_VolumeDown: 114, kVK_VolumeUp: 115,
    ]

    /// Keys that never produce text: always sent as physical keys (down at press, up at release; macOS key
    /// repeats are forwarded as repeated downs, the guest does not repeat by itself).
    public static let nonCharacter: Set<Int> = [
        kVK_Escape, kVK_Delete, kVK_ForwardDelete, kVK_Tab, kVK_Return, kVK_ANSI_KeypadEnter,
        kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Help,
        kVK_Mute, kVK_VolumeDown, kVK_VolumeUp,
        // F-keys reach `physicalDown` and are dropped there (no safe Android key on this keyboard).
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
    ]

    /// Modifier keys forwarded to the guest as held keys (Shift and Control). Option is the Mac's compose key
    /// (å, dead keys) and Command stays on the host; Caps Lock is already applied to the text macOS produces.
    public static let forwardedModifiers: [Int: NSEvent.ModifierFlags] = [
        kVK_Shift: .shift, kVK_RightShift: .shift, kVK_Control: .control, kVK_RightControl: .control,
    ]
}

/// The guest's key character map (`qwerty2.kcm`, US): which evdev key (and Shift) types a character.
public enum USKeymap {
    public struct Stroke: Sendable, Hashable {
        public var code: Int
        public var shift: Bool
        public init(_ code: Int, shift: Bool = false) { self.code = code; self.shift = shift }
    }

    static let table: [Character: Stroke] = {
        var t: [Character: Stroke] = [:]
        let letters: [(Character, Int)] = [("a", 30), ("b", 48), ("c", 46), ("d", 32), ("e", 18), ("f", 33), ("g", 34),
                                           ("h", 35), ("i", 23), ("j", 36), ("k", 37), ("l", 38), ("m", 50), ("n", 49),
                                           ("o", 24), ("p", 25), ("q", 16), ("r", 19), ("s", 31), ("t", 20), ("u", 22),
                                           ("v", 47), ("w", 17), ("x", 45), ("y", 21), ("z", 44)]
        for (c, k) in letters {
            t[c] = Stroke(k)
            t[Character(c.uppercased())] = Stroke(k, shift: true)
        }
        let pairs: [(Character, Character, Int)] = [
            ("1", "!", 2), ("2", "@", 3), ("3", "#", 4), ("4", "$", 5), ("5", "%", 6), ("6", "^", 7), ("7", "&", 8),
            ("8", "*", 9), ("9", "(", 10), ("0", ")", 11), ("-", "_", 12), ("=", "+", 13), ("[", "{", 26), ("]", "}", 27),
            (";", ":", 39), ("'", "\"", 40), ("`", "~", EvdevKey.grave), ("\\", "|", 43), (",", "<", 51), (".", ">", 52), ("/", "?", 53),
        ]
        for (base, shifted, k) in pairs {
            t[base] = Stroke(k)
            t[shifted] = Stroke(k, shift: true)
        }
        t[" "] = Stroke(EvdevKey.space)
        t["\n"] = Stroke(EvdevKey.enter)
        t["\r"] = Stroke(EvdevKey.enter)
        t["\r\n"] = Stroke(EvdevKey.enter)
        t["\t"] = Stroke(EvdevKey.tab)
        return t
    }()

    public static func stroke(for c: Character) -> Stroke? { table[c] }

    /// Whether every character can be typed with the guest's keyboard.
    public static func canType(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy { table[$0] != nil } }
}

/// How a key-down is handled — the text-versus-key-code rule.
public enum KeyRoute: Sendable, Hashable {
    /// Through macOS text input (`interpretKeyEvents`): input methods, dead keys and the keyboard layout decide
    /// the text, which then goes to the guest as typed characters.
    case text
    /// As the physical key (evdev), held until key-up.
    case physical
    /// Not for the guest (⌘ chords the view did not map are the menus' business).
    case ignore
}

/// Device-side editing actions for ⌘/⌥ shortcuts (sent as Android key chords).
public enum EditShortcut: Sendable, Hashable, CaseIterable {
    case selectAll, undo, redo, copy, cut, paste
    case lineStart, lineEnd, textStart, textEnd, deleteToLineStart, deleteToLineEnd
    case wordLeft, wordRight, deleteWordBackward, deleteWordForward
}

/// One step of typing: key events, or text the guest's keyboard cannot type (sent through the clipboard).
public enum TypingAction: Sendable, Hashable {
    case events([EmulatorInputEvent])
    case paste(String)
}

/// Turns host keyboard input into guest key events and keeps track of what the guest holds, so nothing sticks.
///
/// The rule (see docs/ARCHITECTURE.md "Keyboard and text input"):
/// * **Characters** (letters, digits, symbols, space — anything macOS turns into text, through the active
///   layout, dead keys and input methods) are sent **as the character**: the guest key + Shift that types that
///   character on Android's US key map. The key is held while the Mac key is held when the guest's Shift state
///   already matches; otherwise it is a quick press with Shift adjusted around it. Characters the guest keyboard
///   cannot type (é, ü, 中文, emoji…) are pasted through the guest clipboard.
/// * **Non-character keys** (arrows, Return, Tab, Backspace, Delete, Home/End, Page Up/Down, Escape, F-keys)
///   and **every Control chord** are sent **by physical key**, held until key-up.
/// * Shift and Control are forwarded as held modifiers and reconciled with the host's flags on every key, so a
///   modifier released elsewhere never stays down in the guest. Option and Command are never forwarded; their
///   editing combinations are mapped (⌥←/→ word, ⌥⌫ word delete, ⌘←/→ line start/end, ⌘A/C/X/V/Z…).
public struct KeyEventTranslator: Sendable {
    /// Text longer than this in one `insertText` is pasted instead of typed key by key.
    public static let pasteThreshold = 64
    /// Host key code → guest evdev code currently held down because of it.
    private var held: [UInt16: Int] = [:]
    /// Guest modifier keys held (evdev codes of Shift/Ctrl).
    private var mods: Set<Int> = []

    public init() {}

    public var pressedKeyCount: Int { held.count + mods.count }
    public var guestShift: Bool { mods.contains(EvdevKey.leftShift) || mods.contains(EvdevKey.rightShift) }
    public var guestControl: Bool { mods.contains(EvdevKey.leftCtrl) || mods.contains(EvdevKey.rightCtrl) }

    // MARK: Decision

    public static func route(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, hasMarkedText: Bool) -> KeyRoute {
        let code = Int(keyCode)
        if hasMarkedText { return .text }                 // the input method owns every key while composing
        if modifiers.contains(.command) { return .ignore }
        if MacKeyMap.forwardedModifiers[code] != nil { return .physical }
        if modifiers.contains(.control) { return MacKeyMap.evdev[code] != nil ? .physical : .ignore }
        if MacKeyMap.nonCharacter.contains(code) { return .physical }
        return .text
    }

    // MARK: Modifiers

    /// Brings the guest's Shift/Control in line with the host's flags (missed `flagsChanged`, focus changes).
    public mutating func syncModifiers(_ flags: NSEvent.ModifierFlags) -> [EmulatorInputEvent] {
        var out: [EmulatorInputEvent] = []
        for (flag, left, right) in [(NSEvent.ModifierFlags.shift, EvdevKey.leftShift, EvdevKey.rightShift),
                                    (.control, EvdevKey.leftCtrl, EvdevKey.rightCtrl)] {
            let guestHas = mods.contains(left) || mods.contains(right)
            if flags.contains(flag), !guestHas {
                mods.insert(left)
                out.append(Self.down(left))
            } else if !flags.contains(flag), guestHas {
                for k in [left, right] where mods.remove(k) != nil { out.append(Self.up(k)) }
            }
        }
        return out
    }

    /// A modifier key changed (`flagsChanged`). Shift/Control go to the guest as held keys. Command going down
    /// releases held character keys: macOS does not deliver their key-up while ⌘ is down.
    public mutating func modifierChanged(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> [EmulatorInputEvent] {
        let code = Int(keyCode)
        if code == kVK_Command || code == kVK_RightCommand {
            guard flags.contains(.command) else { return [] }
            let ups = held.values.sorted().map(Self.up)
            held.removeAll()
            return ups
        }
        guard let flag = MacKeyMap.forwardedModifiers[code], let ev = MacKeyMap.evdev[code] else { return [] }
        let isDown = Self.isModifierDown(keyCode: code, flags: flags, flag: flag)
        if isDown {
            guard mods.insert(ev).inserted else { return [] }
            return [Self.down(ev)]
        }
        var out: [EmulatorInputEvent] = []
        if mods.remove(ev) != nil { out.append(Self.up(ev)) }
        // The other side's key is not down any more either if the flag is gone.
        if !flags.contains(flag) {
            let twins = flag == .shift ? [EvdevKey.leftShift, EvdevKey.rightShift] : [EvdevKey.leftCtrl, EvdevKey.rightCtrl]
            for t in twins where mods.remove(t) != nil { out.append(Self.up(t)) }
        }
        return out
    }

    /// Left/right modifiers share one flag; the device-dependent bits tell which side is down.
    static func isModifierDown(keyCode: Int, flags: NSEvent.ModifierFlags, flag: NSEvent.ModifierFlags) -> Bool {
        let raw = flags.rawValue
        let sideBit: UInt
        switch keyCode {
        case kVK_Shift: sideBit = UInt(NX_DEVICELSHIFTKEYMASK)
        case kVK_RightShift: sideBit = UInt(NX_DEVICERSHIFTKEYMASK)
        case kVK_Control: sideBit = UInt(NX_DEVICELCTLKEYMASK)
        case kVK_RightControl: sideBit = UInt(NX_DEVICERCTLKEYMASK)
        default: sideBit = 0
        }
        let anySide = UInt(NX_DEVICELSHIFTKEYMASK | NX_DEVICERSHIFTKEYMASK | NX_DEVICELCTLKEYMASK | NX_DEVICERCTLKEYMASK)
        if sideBit != 0, raw & anySide != 0 { return raw & sideBit != 0 }
        return flags.contains(flag)   // synthesized events without device bits
    }

    // MARK: Physical keys

    /// Key-down routed `.physical`. Option combinations are mapped to Android's editing chords.
    public mutating func physicalDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isRepeat: Bool) -> [EmulatorInputEvent] {
        let code = Int(keyCode)
        if MacKeyMap.forwardedModifiers[code] != nil { return modifierChanged(keyCode: keyCode, flags: modifiers) }
        var out = syncModifiers(modifiers)
        if modifiers.contains(.option), !modifiers.contains(.control) {
            switch code {
            case kVK_LeftArrow: return out + shortcut(.wordLeft)
            case kVK_RightArrow: return out + shortcut(.wordRight)
            case kVK_Delete: return out + shortcut(.deleteWordBackward)
            case kVK_ForwardDelete: return out + shortcut(.deleteWordForward)
            default: break
            }
        }
        switch code {
        case kVK_Home: return out + shortcut(.lineStart)
        case kVK_End: return out + shortcut(.lineEnd)
        case kVK_PageUp: return out + shortcut(.textStart)
        case kVK_PageDown: return out + shortcut(.textEnd)
        default: break
        }
        guard let ev = MacKeyMap.evdev[code] else { return out }
        if let previous = held[keyCode], previous != ev { out.append(Self.up(previous)) }
        held[keyCode] = ev
        out.append(Self.down(ev))   // a repeat is another down, as a hardware keyboard's auto-repeat
        return out
    }

    /// Key-up: releases whatever that key holds in the guest (nothing if it was typed as a quick press).
    public mutating func keyUp(keyCode: UInt16) -> [EmulatorInputEvent] {
        guard let ev = held.removeValue(forKey: keyCode) else { return [] }
        return [Self.up(ev)]
    }

    /// Releases every held key and modifier (focus lost, window hidden, app deactivated).
    public mutating func releaseAll() -> [EmulatorInputEvent] {
        let ups = held.values.sorted().map(Self.up) + mods.sorted().map(Self.up)
        held.removeAll()
        mods.removeAll()
        return ups
    }

    // MARK: Text

    /// Text macOS produced (`insertText`). `keyCode` is the key being pressed when the text came from a key-down
    /// (nil for the emoji picker, dictation, input-method commits by click…).
    public mutating func typed(_ text: String, keyCode: UInt16?, modifiers: NSEvent.ModifierFlags) -> [TypingAction] {
        guard !text.isEmpty else { return [] }
        var actions: [TypingAction] = []
        var events = syncModifiers(modifiers.subtracting(.control))
        // Long text in one piece (dictation, a long input-method commit): one paste is faster than key presses.
        if text.count > Self.pasteThreshold {
            return (events.isEmpty ? [] : [.events(events)]) + [.paste(text)]
        }
        // Single character from a key: hold it like the key itself when Shift already matches.
        if let keyCode, text.count == 1, let stroke = USKeymap.stroke(for: text.first!), stroke.shift == guestShift,
           stroke.code != EvdevKey.enter, stroke.code != EvdevKey.tab {
            if let previous = held[keyCode], previous != stroke.code { events.append(Self.up(previous)) }
            held[keyCode] = stroke.code
            events.append(Self.down(stroke.code))
            return [.events(events)]
        }
        var pending = ""
        func flushPaste() {
            guard !pending.isEmpty else { return }
            if !events.isEmpty { actions.append(.events(events)); events = [] }
            actions.append(.paste(pending))
            pending = ""
        }
        for ch in text {
            if let stroke = USKeymap.stroke(for: ch) {
                flushPaste()
                events += press(stroke.code, shift: stroke.shift, control: false)
            } else {
                pending.append(ch)
            }
        }
        flushPaste()
        if !events.isEmpty { actions.append(.events(events)) }
        return actions
    }

    /// `count` Backspace presses (replacing text the input method already committed, e.g. press-and-hold accents).
    public mutating func backspaces(_ count: Int) -> [EmulatorInputEvent] {
        guard count > 0 else { return [] }
        var out: [EmulatorInputEvent] = []
        for _ in 0..<count { out += press(EvdevKey.backspace, shift: false, control: false) }
        return out
    }

    // MARK: Shortcuts

    /// Android key chord for an editing shortcut. `selecting` keeps Shift (⇧⌘← selects to the line start).
    public mutating func shortcut(_ s: EditShortcut, selecting: Bool? = nil) -> [EmulatorInputEvent] {
        let sel = selecting ?? guestShift
        switch s {
        case .selectAll: return press(EvdevKey.a, shift: false, control: true)
        case .undo: return press(EvdevKey.z, shift: false, control: true)
        case .redo: return press(EvdevKey.z, shift: true, control: true)
        case .copy: return press(EvdevKey.c, shift: false, control: true)
        case .cut: return press(EvdevKey.x, shift: false, control: true)
        case .paste: return press(EvdevKey.v, shift: false, control: true)
        // Android's text movement: Alt+←/→ line start/end, Alt+↑/↓ start/end of the text (with Shift: select).
        case .lineStart: return press(EvdevKey.left, shift: sel, control: false, alt: true)
        case .lineEnd: return press(EvdevKey.right, shift: sel, control: false, alt: true)
        case .textStart: return press(EvdevKey.up, shift: sel, control: false, alt: true)
        case .textEnd: return press(EvdevKey.down, shift: sel, control: false, alt: true)
        case .wordLeft: return press(EvdevKey.left, shift: sel, control: true)
        case .wordRight: return press(EvdevKey.right, shift: sel, control: true)
        case .deleteToLineStart:
            return press(EvdevKey.left, shift: true, control: false, alt: true) + press(EvdevKey.backspace, shift: false, control: false)
        case .deleteToLineEnd:
            return press(EvdevKey.right, shift: true, control: false, alt: true) + press(EvdevKey.delete, shift: false, control: false)
        case .deleteWordBackward: return press(EvdevKey.backspace, shift: false, control: true)
        case .deleteWordForward: return press(EvdevKey.delete, shift: false, control: true)
        }
    }

    /// A press of `code` with exactly the given Shift/Control/Alt state; held modifiers are restored afterwards.
    mutating func press(_ code: Int, shift: Bool, control: Bool, alt: Bool = false) -> [EmulatorInputEvent] {
        var before: [EmulatorInputEvent] = []
        var after: [EmulatorInputEvent] = []
        for (want, left, right) in [(shift, EvdevKey.leftShift, EvdevKey.rightShift), (control, EvdevKey.leftCtrl, EvdevKey.rightCtrl),
                                    (alt, EvdevKey.leftAlt, EvdevKey.rightAlt)] {
            let heldKeys = [left, right].filter { mods.contains($0) }
            if want, heldKeys.isEmpty {
                before.append(Self.down(left))
                after.insert(Self.up(left), at: 0)
            } else if !want, !heldKeys.isEmpty {
                for k in heldKeys {
                    before.append(Self.up(k))
                    after.insert(Self.down(k), at: 0)
                }
            }
        }
        return before + [Self.down(code), Self.up(code)] + after
    }

    /// Ctrl+V as sent after setting the guest clipboard.
    public var pasteChord: [EmulatorInputEvent] {
        [Self.down(EvdevKey.leftCtrl), Self.down(EvdevKey.v), Self.up(EvdevKey.v), Self.up(EvdevKey.leftCtrl)]
    }

    /// BACK (evdev KEY_BACK) as a key press on the input stream, ordered with typed keys.
    public static let backPress: [EmulatorInputEvent] = [down(EvdevKey.back), up(EvdevKey.back)]

    /// Keys Android's input method (Gboard) takes from a hardware keyboard and turns into text asynchronously;
    /// other keys (arrows, chords, Return, BACK) go straight to the app. `TypingSequencer` lets the input method
    /// catch up before such a key follows typed characters, or it can overtake them.
    public static let imeHandledKeys: Set<Int> = {
        var s = Set(USKeymap.table.values.map(\.code))
        s.remove(EvdevKey.enter)
        s.remove(EvdevKey.tab)
        return s
    }()

    /// Text worth sending: no control characters or function-key private-use characters.
    public static func isTypable(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return s.unicodeScalars.allSatisfy { scalar in
            !(scalar.value < 0x20 || scalar.value == 0x7F || (0x80..<0xA0).contains(scalar.value)
              || (0xF700...0xF8FF).contains(scalar.value))
        }
    }

    static func down(_ code: Int) -> EmulatorInputEvent { .key(.evdev(code, .keydown)) }
    static func up(_ code: Int) -> EmulatorInputEvent { .key(.evdev(code, .keyup)) }
}
