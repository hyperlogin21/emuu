import AppKit
import Carbon.HIToolbox

/// Typing scenarios for the keyboard self-test (`EMUU_APP_SELFTEST_ONLY=keyboard`, see KeyboardSelfTest.swift).
/// Each is a sequence of host input steps — what the keyboard, macOS text input or the user does — and the text
/// the test app's field (scripts/typing-test-apk) must contain afterwards. Plain data with no app dependencies.
struct KeyTestScenario {
    enum Step {
        /// Types a string on a US (ABC) keyboard: Shift via flagsChanged, key down/up per character.
        case type(String)
        /// One key down+up with the characters macOS reports (other layouts, special keys).
        case key(Int, String, NSEvent.ModifierFlags = [])
        /// A held key: down, `repeats` auto-repeat downs, up.
        case hold(Int, String, repeats: Int, NSEvent.ModifierFlags = [])
        case down(Int, String, NSEvent.ModifierFlags = [])
        case up(Int, String)
        case flags(Int, NSEvent.ModifierFlags)
        /// A ⌘ chord through the key-equivalent path (view first, then the menus).
        case cmd(String, Int, NSEvent.ModifierFlags = [])
        /// NSTextInputClient calls as input methods make them (no key event).
        case insert(String, replace: NSRange? = nil)
        /// The press-and-hold accent menu: replaces the character before the insertion point (the range comes from
        /// the view's `selectedRange()`, as the input method asks for it).
        case pressAndHold(String)
        case marked(String)
        case resignKey, deactivate
        case wait(Int)
        /// Puts text on the Mac pasteboard (the runner saves and restores the user's pasteboard).
        case macClipboard(String)
    }

    enum Check: Equatable {
        case field(String)
        /// Field text plus the Mac pasteboard (device → Mac clipboard).
        case fieldAndMacClipboard(String, String)
    }

    var name: String
    var category: String
    var steps: [Step]
    var check: Check
    /// Needs NSTextInputClient (input methods, press-and-hold, emoji picker).
    var needsTextInputClient = false

    static let shiftFlags = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICELSHIFTKEYMASK))
    static let ctrlFlags = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.control.rawValue | UInt(NX_DEVICELCTLKEYMASK))
    static let cmdFlags = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | UInt(NX_DEVICELCMDKEYMASK))

    /// US key + Shift for a character (the ABC layout).
    static let usKeys: [Character: (Int, Bool)] = {
        var t: [Character: (Int, Bool)] = [:]
        let letters: [(Character, Int)] = [("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E),
            ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J), ("k", kVK_ANSI_K),
            ("l", kVK_ANSI_L), ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O), ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q),
            ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T), ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W),
            ("x", kVK_ANSI_X), ("y", kVK_ANSI_Y), ("z", kVK_ANSI_Z)]
        for (c, k) in letters { t[c] = (k, false); t[Character(c.uppercased())] = (k, true) }
        let pairs: [(Character, Character, Int)] = [("1", "!", kVK_ANSI_1), ("2", "@", kVK_ANSI_2), ("3", "#", kVK_ANSI_3),
            ("4", "$", kVK_ANSI_4), ("5", "%", kVK_ANSI_5), ("6", "^", kVK_ANSI_6), ("7", "&", kVK_ANSI_7), ("8", "*", kVK_ANSI_8),
            ("9", "(", kVK_ANSI_9), ("0", ")", kVK_ANSI_0), ("-", "_", kVK_ANSI_Minus), ("=", "+", kVK_ANSI_Equal),
            ("[", "{", kVK_ANSI_LeftBracket), ("]", "}", kVK_ANSI_RightBracket), (";", ":", kVK_ANSI_Semicolon),
            ("'", "\"", kVK_ANSI_Quote), ("`", "~", kVK_ANSI_Grave), ("\\", "|", kVK_ANSI_Backslash), (",", "<", kVK_ANSI_Comma),
            (".", ">", kVK_ANSI_Period), ("/", "?", kVK_ANSI_Slash)]
        for (a, b, k) in pairs { t[a] = (k, false); t[b] = (k, true) }
        t[" "] = (kVK_Space, false)
        t["\n"] = (kVK_Return, false)
        t["\t"] = (kVK_Tab, false)
        return t
    }()

    /// Deterministic 2 000 printable-ASCII characters (letters, digits, symbols, spaces).
    static let long2000: String = {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 !@#$%^&*()_+-=[]{};:'\",.<>/?\\|`~")
        var x: UInt32 = 12345
        return String((0..<2000).map { _ in
            x = x &* 1103515245 &+ 12345
            return alphabet[Int((x >> 16) % UInt32(alphabet.count))]
        })
    }()

    static let pasteMixed2000: String = {
        let unit = Array("Grüße, 你好 😀 naïve — 東京 ok! ")
        return String((0..<2000).map { unit[$0 % unit.count] })
    }()

    static let none = NSRange(location: NSNotFound, length: 0)

    static let all: [KeyTestScenario] = [
        // Printable ASCII
        .init(name: "lowercase", category: "ASCII", steps: [.type("the quick brown fox jumps over the lazy dog")],
              check: .field("the quick brown fox jumps over the lazy dog")),
        .init(name: "uppercase", category: "ASCII", steps: [.type("THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG")],
              check: .field("THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG")),
        .init(name: "digits", category: "ASCII", steps: [.type("0123456789")], check: .field("0123456789")),
        .init(name: "symbols-unshifted", category: "ASCII", steps: [.type("-=[]\\;',./`")], check: .field("-=[]\\;',./`")),
        .init(name: "symbols-shifted", category: "ASCII", steps: [.type("!@#$%^&*()_+{}|:\"<>?~")], check: .field("!@#$%^&*()_+{}|:\"<>?~")),
        .init(name: "space-return", category: "ASCII", steps: [.type("a b\nc")], check: .field("a b\nc")),
        .init(name: "keypad", category: "ASCII", steps: [
            .key(kVK_ANSI_Keypad1, "1", .numericPad), .key(kVK_ANSI_Keypad2, "2", .numericPad), .key(kVK_ANSI_Keypad0, "0", .numericPad),
            .key(kVK_ANSI_KeypadMultiply, "*", .numericPad), .key(kVK_ANSI_KeypadPlus, "+", .numericPad), .key(kVK_ANSI_KeypadMinus, "-", .numericPad),
            .key(kVK_ANSI_KeypadDivide, "/", .numericPad), .key(kVK_ANSI_KeypadDecimal, ".", .numericPad), .key(kVK_ANSI_KeypadEquals, "=", .numericPad),
            .key(kVK_ANSI_KeypadEnter, "\u{3}", .numericPad), .type("x"),
        ], check: .field("120*+-/.=\nx")),
        // Editing and navigation
        .init(name: "backspace", category: "Editing", steps: [.type("hello"), .key(kVK_Delete, "\u{7F}"), .key(kVK_Delete, "\u{7F}")], check: .field("hel")),
        .init(name: "arrows", category: "Editing", steps: [.type("abcd"), .key(kVK_LeftArrow, "\u{F702}"), .key(kVK_LeftArrow, "\u{F702}"), .type("X"),
                                                           .key(kVK_UpArrow, "\u{F700}"), .key(kVK_DownArrow, "\u{F701}"), .key(kVK_RightArrow, "\u{F703}"), .type("Y")],
              check: .field("abXcdY")),   // ↑ on the first line goes to the start, ↓ on the last to the end
        .init(name: "capital-then-arrow", category: "Editing", steps: [.type("abcX"), .key(kVK_LeftArrow, "\u{F702}"), .type("a")],
              check: .field("abcaX")),
        .init(name: "forward-delete", category: "Editing", steps: [.type("abcd"), .key(kVK_LeftArrow, "\u{F702}"), .key(kVK_LeftArrow, "\u{F702}"),
                                                                   .key(kVK_ForwardDelete, "\u{F728}")], check: .field("abd")),
        .init(name: "home-end", category: "Editing", steps: [.type("bc"), .key(kVK_Home, "\u{F729}"), .type("a"), .key(kVK_End, "\u{F72B}"), .type("d")],
              check: .field("abcd")),
        .init(name: "page-up-down", category: "Editing", steps: [.type("a\nb\nc"), .key(kVK_PageUp, "\u{F72C}"), .type("X"), .key(kVK_PageDown, "\u{F72D}"), .type("Y")],
              check: .field("Xa\nb\ncY")),
        .init(name: "hold-backspace", category: "Repeat", steps: [.type("abcdefgh"), .hold(kVK_Delete, "\u{7F}", repeats: 4)], check: .field("abc")),
        .init(name: "hold-letter", category: "Repeat", steps: [.hold(kVK_ANSI_K, "k", repeats: 4)], check: .field("kkkkk")),
        .init(name: "hold-arrow", category: "Repeat", steps: [.type("abcdef"), .hold(kVK_LeftArrow, "\u{F702}", repeats: 2), .type("X")], check: .field("abcXdef")),
        .init(name: "shift-arrow-select", category: "Editing", steps: [
            .type("hello world"), .flags(kVK_Shift, shiftFlags),
            .key(kVK_LeftArrow, "\u{F702}", shiftFlags), .key(kVK_LeftArrow, "\u{F702}", shiftFlags), .key(kVK_LeftArrow, "\u{F702}", shiftFlags),
            .key(kVK_LeftArrow, "\u{F702}", shiftFlags), .key(kVK_LeftArrow, "\u{F702}", shiftFlags), .flags(kVK_Shift, []), .type("X"),
        ], check: .field("hello X")),
        .init(name: "option-arrow-word", category: "Editing", steps: [.type("one two"), .key(kVK_LeftArrow, "\u{F702}", .option), .type("X")],
              check: .field("one Xtwo")),
        .init(name: "option-delete-word", category: "Editing", steps: [.type("one two"), .key(kVK_Delete, "\u{7F}", .option)], check: .field("one ")),
        // Shortcuts
        .init(name: "cmd-a", category: "Shortcuts", steps: [.type("abc"), .cmd("a", kVK_ANSI_A), .type("Z")], check: .field("Z")),
        .init(name: "cmd-z-undo", category: "Shortcuts", steps: [.type("abc"), .wait(300), .cmd("a", kVK_ANSI_A), .type("X"), .wait(300), .cmd("z", kVK_ANSI_Z)],
              check: .field("abc")),
        .init(name: "cmd-left-right", category: "Shortcuts", steps: [.type("bc"), .cmd("", kVK_LeftArrow), .type("a"), .cmd("", kVK_RightArrow), .type("d")],
              check: .field("abcd")),
        .init(name: "cmd-shift-left", category: "Shortcuts", steps: [.type("abc def"), .flags(kVK_Shift, shiftFlags), .cmd("", kVK_LeftArrow, shiftFlags),
                                                                     .flags(kVK_Shift, []), .type("X")], check: .field("X")),
        .init(name: "cmd-delete", category: "Shortcuts", steps: [.type("abc def"), .cmd("\u{7F}", kVK_Delete)], check: .field("")),
        .init(name: "cmd-v-mac-clipboard", category: "Shortcuts", steps: [.type("<"), .macClipboard("Grüße, 你好 😀 — ok"), .cmd("v", kVK_ANSI_V), .type(">")],
              check: .field("<Grüße, 你好 😀 — ok>")),
        .init(name: "cmd-c-to-mac", category: "Shortcuts", steps: [.macClipboard("before"), .type("copy me"), .cmd("a", kVK_ANSI_A), .cmd("c", kVK_ANSI_C), .wait(1500)],
              check: .fieldAndMacClipboard("copy me", "copy me")),
        .init(name: "cmd-x-to-mac", category: "Shortcuts", steps: [.macClipboard("before"), .type("cut me"), .cmd("a", kVK_ANSI_A), .cmd("x", kVK_ANSI_X), .wait(1500)],
              check: .fieldAndMacClipboard("", "cut me")),
        .init(name: "ctrl-a", category: "Shortcuts", steps: [.type("abc"), .flags(kVK_Control, ctrlFlags), .key(kVK_ANSI_A, "\u{1}", ctrlFlags),
                                                             .flags(kVK_Control, []), .type("Q")], check: .field("Q")),
        // Characters Android's keyboard cannot type
        // Dead keys as the input system reports them to the view (marked accent, then the composed letter).
        .init(name: "dead-keys", category: "Non-ASCII", steps: [
            .marked("´"), .insert("é"), .marked("˜"), .insert("ñ"), .marked("¨"), .insert("ü"), .type("!"),
        ], check: .field("éñü!"), needsTextInputClient: true),
        // The same keys as raw key events through macOS text input (needs an active input context: the app frontmost).
        .init(name: "dead-keys-tsm", category: "Non-ASCII", steps: [
            .key(kVK_ANSI_E, "", .option), .key(kVK_ANSI_E, "e"), .key(kVK_ANSI_N, "", .option), .key(kVK_ANSI_N, "n"),
            .key(kVK_ANSI_U, "", .option), .key(kVK_ANSI_U, "u"), .type("!"),
        ], check: .field("éñü!")),
        .init(name: "option-letters", category: "Non-ASCII", steps: [.key(kVK_ANSI_A, "å", .option), .key(kVK_ANSI_S, "ß", .option), .key(kVK_ANSI_2, "™", .option)],
              check: .field("åß™")),
        .init(name: "press-and-hold", category: "Non-ASCII", steps: [.type("caf"), .key(kVK_ANSI_E, "e"), .pressAndHold("é"), .type("!")],
              check: .field("café!"), needsTextInputClient: true),
        .init(name: "emoji-picker", category: "Non-ASCII", steps: [.type("hi "), .insert("😀👍🏽🇫🇷"), .type(".")], check: .field("hi 😀👍🏽🇫🇷."),
              needsTextInputClient: true),
        .init(name: "ime-pinyin", category: "Non-ASCII", steps: [
            .marked("n"), .marked("ni"), .marked("ni h"), .marked("ni ha"), .marked("ni hao"), .wait(400), .insert("你好"),
            .marked("s"), .marked("shi"), .marked("shij"), .marked("shijie"), .insert("世界"), .type("!"),
        ], check: .field("你好世界!"), needsTextInputClient: true),
        .init(name: "ime-japanese", category: "Non-ASCII", steps: [
            .marked("k"), .marked("か"), .marked("かn"), .marked("かん"), .marked("かんj"), .marked("かんじ"), .marked("漢字"), .insert("漢字"),
            .marked("で"), .marked("です"), .insert("です"),
        ], check: .field("漢字です"), needsTextInputClient: true),
        .init(name: "layout-azerty", category: "Layouts", steps: [
            .key(kVK_ANSI_Q, "a"), .key(kVK_ANSI_W, "z"), .key(kVK_ANSI_1, "&"), .flags(kVK_Shift, shiftFlags), .key(kVK_ANSI_1, "1", shiftFlags),
            .flags(kVK_Shift, []), .key(kVK_ANSI_2, "é"), .key(kVK_ANSI_M, ","), .key(kVK_ANSI_Semicolon, "m"),
        ], check: .field("az&1é,m")),
        .init(name: "layout-qwertz", category: "Layouts", steps: [
            .key(kVK_ANSI_Y, "z"), .key(kVK_ANSI_Z, "y"), .key(kVK_ANSI_Minus, "ß"), .flags(kVK_Shift, shiftFlags), .key(kVK_ANSI_7, "/", shiftFlags),
            .flags(kVK_Shift, []), .key(kVK_ANSI_L, "@", .option),
        ], check: .field("zyß/@")),
        // Speed and order
        .init(name: "fast-2000", category: "Speed", steps: [.type(long2000)], check: .field(long2000)),
        .init(name: "paste-2000", category: "Speed", steps: [.macClipboard(pasteMixed2000), .cmd("v", kVK_ANSI_V)], check: .field(pasteMixed2000)),
        .init(name: "ime-commits-burst", category: "Speed",
              steps: (0..<40).map { i in KeyTestScenario.Step.insert(i % 2 == 0 ? "東京タワー" : "ok ") },
              check: .field(String(repeating: "東京タワーok ", count: 20)), needsTextInputClient: true),
        // Key-up bookkeeping
        .init(name: "resign-key-mid-press", category: "Stuck keys", steps: [.down(kVK_ANSI_W, "w"), .down(kVK_DownArrow, "\u{F701}"), .resignKey],
              check: .field("w")),
        .init(name: "deactivate-mid-press", category: "Stuck keys", steps: [.flags(kVK_Shift, shiftFlags), .down(kVK_ANSI_A, "A", shiftFlags), .deactivate],
              check: .field("A")),
        .init(name: "modifier-released-first", category: "Stuck keys", steps: [.flags(kVK_Shift, shiftFlags), .down(kVK_ANSI_A, "A", shiftFlags),
                                                                               .flags(kVK_Shift, []), .up(kVK_ANSI_A, "a"), .type("b")],
              check: .field("Ab")),
        .init(name: "command-pressed-mid-key", category: "Stuck keys", steps: [.down(kVK_ANSI_W, "w"), .flags(kVK_Command, cmdFlags), .flags(kVK_Command, [])],
              check: .field("w")),
    ]
}
