import Testing
import Foundation
import AppKit
import Carbon.HIToolbox
import EmuuBase
import EmuuGRPC
@testable import EmuuDisplay

private func down(_ c: Int) -> EmulatorInputEvent { .key(.evdev(c, .keydown)) }
private func up(_ c: Int) -> EmulatorInputEvent { .key(.evdev(c, .keyup)) }
private func press(_ c: Int) -> [EmulatorInputEvent] { [down(c), up(c)] }
private let shiftL = EvdevKey.leftShift, ctrlL = EvdevKey.leftCtrl
private let shiftFlags = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICELSHIFTKEYMASK))

@Suite struct KeyRouteTests {
    func route(_ code: Int, _ mods: NSEvent.ModifierFlags = [], marked: Bool = false) -> KeyRoute {
        KeyEventTranslator.route(keyCode: UInt16(code), modifiers: mods, hasMarkedText: marked)
    }

    @Test func charactersGoThroughTextInput() {
        for code in [kVK_ANSI_A, kVK_ANSI_Z, kVK_ANSI_1, kVK_ANSI_Slash, kVK_ANSI_Grave, kVK_Space, kVK_ANSI_Keypad5, kVK_ISO_Section] {
            #expect(route(code) == .text)
            #expect(route(code, [.shift]) == .text)
            #expect(route(code, [.option]) == .text)   // ⌥ composes (å, dead keys)
        }
    }

    @Test func nonCharacterKeysArePhysical() {
        for code in [kVK_Return, kVK_Tab, kVK_Delete, kVK_ForwardDelete, kVK_Escape, kVK_LeftArrow, kVK_RightArrow,
                     kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_F5, kVK_ANSI_KeypadEnter] {
            #expect(route(code) == .physical)
            #expect(route(code, [.shift]) == .physical)
            #expect(route(code, [.option]) == .physical)
        }
    }

    @Test func controlChordsArePhysicalAndCommandStaysOnTheHost() {
        #expect(route(kVK_ANSI_C, [.control]) == .physical)
        #expect(route(kVK_ANSI_A, [.control, .shift]) == .physical)
        #expect(route(kVK_ANSI_Q, [.command]) == .ignore)
        #expect(route(kVK_LeftArrow, [.command]) == .ignore)
    }

    @Test func composingSendsEverythingToTheInputMethod() {
        for code in [kVK_Return, kVK_Delete, kVK_LeftArrow, kVK_Space, kVK_Escape, kVK_ANSI_A] {
            #expect(route(code, marked: true) == .text)
        }
    }
}

@Suite struct KeyTranslatorTests {
    @Test func everyKeyCodeIsNonZero() {
        // kVK_ANSI_A is 0 = the protobuf default; the engine dropped it when sent as a Mac key code.
        #expect(MacKeyMap.evdev.values.allSatisfy { $0 > 0 })
        #expect(MacKeyMap.evdev[kVK_ANSI_A] == 30)
        #expect(EmulatorInputEvent.key(.evdev(30, .keydown)).encoded().contains(30))
    }

    @Test func typedCharacterIsHeldWhileTheKeyIsHeld() {
        var t = KeyEventTranslator()
        #expect(t.typed("w", keyCode: UInt16(kVK_ANSI_W), modifiers: []) == [.events([down(17)])])
        #expect(t.typed("w", keyCode: UInt16(kVK_ANSI_W), modifiers: []) == [.events([down(17)])])   // macOS repeat
        #expect(t.keyUp(keyCode: UInt16(kVK_ANSI_W)) == [up(17)])
        #expect(t.keyUp(keyCode: UInt16(kVK_ANSI_W)).isEmpty)   // no stray up
        #expect(t.pressedKeyCount == 0)
    }

    @Test func layoutDecidesTheCharacterNotThePosition() {
        var t = KeyEventTranslator()
        // AZERTY: the key in the US "Q" position types "a" → Android's A key.
        #expect(t.typed("a", keyCode: UInt16(kVK_ANSI_Q), modifiers: []) == [.events([down(30)])])
        #expect(t.keyUp(keyCode: UInt16(kVK_ANSI_Q)) == [up(30)])
        // AZERTY "&" (US "1" key, unshifted) → Shift+7 on Android's US map.
        #expect(t.typed("&", keyCode: UInt16(kVK_ANSI_1), modifiers: []) == [.events([down(shiftL), down(8), up(8), up(shiftL)])])
        // AZERTY Shift+"&" key types "1": the held Shift is lifted around the key, then pressed again.
        _ = t.modifierChanged(keyCode: UInt16(kVK_Shift), flags: shiftFlags)
        #expect(t.typed("1", keyCode: UInt16(kVK_ANSI_1), modifiers: shiftFlags) == [.events([up(shiftL), down(2), up(2), down(shiftL)])])
        #expect(t.guestShift)
    }

    @Test func shiftedUSSymbolsUseTheHeldShift() {
        var t = KeyEventTranslator()
        // flagsChanged missed: the key-down's flags bring Shift into the guest first.
        #expect(t.typed("!", keyCode: UInt16(kVK_ANSI_1), modifiers: [.shift]) == [.events([down(shiftL), down(2)])])
        #expect(t.typed("A", keyCode: UInt16(kVK_ANSI_A), modifiers: [.shift]) == [.events([down(30)])])
    }

    @Test func everyPrintableASCIICharacterHasAStroke() {
        for v in 0x20..<0x7F {
            let c = Character(UnicodeScalar(v)!)
            #expect(USKeymap.stroke(for: c) != nil, "missing \(c)")
        }
        let shifted = "~!@#$%^&*()_+{}|:\"<>?ABCXYZ"
        #expect(shifted.allSatisfy { USKeymap.stroke(for: $0)!.shift })
        let plain = #"`1234567890-=[]\;',./ abcxyz"#
        #expect(USKeymap.stroke(for: "`") == .init(EvdevKey.grave) && USKeymap.stroke(for: "~") == .init(EvdevKey.grave, shift: true))
        #expect(plain.allSatisfy { !USKeymap.stroke(for: $0)!.shift })
    }

    @Test func textTheKeyboardCannotTypeIsPasted() {
        var t = KeyEventTranslator()
        #expect(t.typed("é", keyCode: UInt16(kVK_ANSI_E), modifiers: []) == [.paste("é")])
        #expect(t.pressedKeyCount == 0)
        #expect(t.typed("中文😀", keyCode: nil, modifiers: []) == [.paste("中文😀")])
        // Mixed: keys and pastes in order.
        #expect(t.typed("ab é!", keyCode: nil, modifiers: []) == [
            .events(press(30) + press(48) + press(57)), .paste("é"), .events([down(shiftL), down(2), up(2), up(shiftL)]),
        ])
    }

    @Test func longTextIsPastedInOnePiece() {
        var t = KeyEventTranslator()
        let long = String(repeating: "dictated text ", count: 10)
        #expect(t.typed(long, keyCode: nil, modifiers: []) == [.paste(long)])
    }

    @Test func textWithoutAKeyIsPressedNotHeld() {
        var t = KeyEventTranslator()
        #expect(t.typed("hi", keyCode: nil, modifiers: []) == [.events(press(35) + press(23))])
        #expect(t.typed("x", keyCode: nil, modifiers: []) == [.events(press(45))])
        #expect(t.pressedKeyCount == 0)
    }

    @Test func navigationKeysAreHeldAndRepeat() {
        var t = KeyEventTranslator()
        #expect(t.physicalDown(keyCode: UInt16(kVK_Delete), modifiers: [], isRepeat: false) == [down(EvdevKey.backspace)])
        #expect(t.physicalDown(keyCode: UInt16(kVK_Delete), modifiers: [], isRepeat: true) == [down(EvdevKey.backspace)])
        #expect(t.keyUp(keyCode: UInt16(kVK_Delete)) == [up(EvdevKey.backspace)])
        #expect(t.physicalDown(keyCode: UInt16(kVK_ForwardDelete), modifiers: [], isRepeat: false) == [down(EvdevKey.delete)])
        #expect(t.physicalDown(keyCode: UInt16(kVK_Escape), modifiers: [], isRepeat: false) == [down(EvdevKey.esc)])
        #expect(t.physicalDown(keyCode: UInt16(kVK_ANSI_KeypadEnter), modifiers: [], isRepeat: false) == [down(EvdevKey.enter)])
        // qwerty2 has no Home/End/Page keys (102 is the HOME button, 107 ENDCALL): Android's Alt+arrow movements.
        let alt = EvdevKey.leftAlt
        #expect(t.physicalDown(keyCode: UInt16(kVK_Home), modifiers: [], isRepeat: false) == [down(alt), down(EvdevKey.left), up(EvdevKey.left), up(alt)])
        #expect(t.physicalDown(keyCode: UInt16(kVK_End), modifiers: [], isRepeat: false) == [down(alt), down(EvdevKey.right), up(EvdevKey.right), up(alt)])
        #expect(t.physicalDown(keyCode: UInt16(kVK_PageUp), modifiers: [], isRepeat: false) == [down(alt), down(EvdevKey.up), up(EvdevKey.up), up(alt)])
        #expect(t.physicalDown(keyCode: UInt16(kVK_PageDown), modifiers: [], isRepeat: false) == [down(alt), down(EvdevKey.down), up(EvdevKey.down), up(alt)])
        // F-keys would be MENU/CALL/ENDCALL on this keyboard: not sent.
        for f in [kVK_F1, kVK_F4, kVK_F10, kVK_F12] { #expect(t.physicalDown(keyCode: UInt16(f), modifiers: [], isRepeat: false).isEmpty) }
        #expect(!MacKeyMap.evdev.values.contains(102) && !MacKeyMap.evdev.values.contains(107))
    }

    @Test func shiftArrowSelectsWithTheHeldShift() {
        var t = KeyEventTranslator()
        #expect(t.modifierChanged(keyCode: UInt16(kVK_Shift), flags: shiftFlags) == [down(shiftL)])
        #expect(t.physicalDown(keyCode: UInt16(kVK_LeftArrow), modifiers: shiftFlags, isRepeat: false) == [down(EvdevKey.left)])
    }

    @Test func optionEditingChords() {
        var t = KeyEventTranslator()
        #expect(t.physicalDown(keyCode: UInt16(kVK_LeftArrow), modifiers: [.option], isRepeat: false) == [down(ctrlL), down(EvdevKey.left), up(EvdevKey.left), up(ctrlL)])
        #expect(t.physicalDown(keyCode: UInt16(kVK_Delete), modifiers: [.option], isRepeat: false) == [down(ctrlL), down(EvdevKey.backspace), up(EvdevKey.backspace), up(ctrlL)])
        #expect(t.pressedKeyCount == 0)   // chords are presses: nothing left held
        // ⇧⌥→ selects a word: Shift (held) + Ctrl + Right.
        _ = t.modifierChanged(keyCode: UInt16(kVK_Shift), flags: shiftFlags)
        #expect(t.physicalDown(keyCode: UInt16(kVK_RightArrow), modifiers: [.option, .shift], isRepeat: false) == [down(ctrlL), down(EvdevKey.right), up(EvdevKey.right), up(ctrlL)])
    }

    @Test func commandShortcutsMapToControlChords() {
        var t = KeyEventTranslator()
        #expect(t.shortcut(.selectAll) == [down(ctrlL), down(30), up(30), up(ctrlL)])
        #expect(t.shortcut(.undo) == [down(ctrlL), down(44), up(44), up(ctrlL)])
        #expect(t.shortcut(.redo) == [down(shiftL), down(ctrlL), down(44), up(44), up(ctrlL), up(shiftL)])
        let alt = EvdevKey.leftAlt
        #expect(t.shortcut(.lineStart, selecting: false) == [down(alt), down(EvdevKey.left), up(EvdevKey.left), up(alt)])
        #expect(t.shortcut(.lineEnd, selecting: true) == [down(shiftL), down(alt), down(EvdevKey.right), up(EvdevKey.right), up(alt), up(shiftL)])
        #expect(t.shortcut(.deleteToLineStart) == [down(shiftL), down(alt), down(EvdevKey.left), up(EvdevKey.left), up(alt), up(shiftL)] + press(EvdevKey.backspace))
        // ⌘A while Shift is held: Shift is lifted for the chord and pressed again.
        _ = t.modifierChanged(keyCode: UInt16(kVK_Shift), flags: shiftFlags)
        #expect(t.shortcut(.selectAll) == [up(shiftL), down(ctrlL), down(30), up(30), up(ctrlL), down(shiftL)])
        #expect(t.pasteChord == [down(ctrlL), down(47), up(47), up(ctrlL)])
    }

    @Test func controlChordsGoByPosition() {
        var t = KeyEventTranslator()
        let ctrl = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.control.rawValue | UInt(NX_DEVICELCTLKEYMASK))
        #expect(t.modifierChanged(keyCode: UInt16(kVK_Control), flags: ctrl) == [down(ctrlL)])
        #expect(t.physicalDown(keyCode: UInt16(kVK_ANSI_C), modifiers: ctrl, isRepeat: false) == [down(46)])
        #expect(t.keyUp(keyCode: UInt16(kVK_ANSI_C)) == [up(46)])
        #expect(t.modifierChanged(keyCode: UInt16(kVK_Control), flags: []) == [up(ctrlL)])
    }

    @Test func modifiersNeverStick() {
        var t = KeyEventTranslator()
        let both = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICELSHIFTKEYMASK | NX_DEVICERSHIFTKEYMASK))
        let rightOnly = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICERSHIFTKEYMASK))
        #expect(t.modifierChanged(keyCode: UInt16(kVK_Shift), flags: shiftFlags) == [down(shiftL)])
        #expect(t.modifierChanged(keyCode: UInt16(kVK_RightShift), flags: both) == [down(EvdevKey.rightShift)])
        #expect(t.modifierChanged(keyCode: UInt16(kVK_Shift), flags: rightOnly) == [up(shiftL)])        // left released, right still down
        #expect(t.modifierChanged(keyCode: UInt16(kVK_RightShift), flags: []) == [up(EvdevKey.rightShift)])
        #expect(t.pressedKeyCount == 0)
        // A Shift released while the window was not key: the next key's flags release it in the guest.
        _ = t.modifierChanged(keyCode: UInt16(kVK_Shift), flags: shiftFlags)
        #expect(t.typed("a", keyCode: UInt16(kVK_ANSI_A), modifiers: []) == [.events([up(shiftL), down(30)])])
        // Caps Lock and Option are not forwarded (macOS already applied them to the text).
        #expect(t.modifierChanged(keyCode: UInt16(kVK_CapsLock), flags: [.capsLock]).isEmpty)
        #expect(t.modifierChanged(keyCode: UInt16(kVK_Option), flags: [.option]).isEmpty)
    }

    @Test func modifierReleasedWhileAKeyIsHeld() {
        var t = KeyEventTranslator()
        _ = t.modifierChanged(keyCode: UInt16(kVK_Shift), flags: shiftFlags)
        #expect(t.typed("A", keyCode: UInt16(kVK_ANSI_A), modifiers: shiftFlags) == [.events([down(30)])])
        #expect(t.modifierChanged(keyCode: UInt16(kVK_Shift), flags: []) == [up(shiftL)])
        #expect(t.keyUp(keyCode: UInt16(kVK_ANSI_A)) == [up(30)])
        #expect(t.pressedKeyCount == 0)
    }

    @Test func commandDownReleasesHeldKeysAndReleaseAllClearsEverything() {
        var t = KeyEventTranslator()
        _ = t.typed("w", keyCode: UInt16(kVK_ANSI_W), modifiers: [])
        // macOS does not deliver the W key-up while ⌘ is down: release it now.
        #expect(t.modifierChanged(keyCode: UInt16(kVK_Command), flags: [.command]) == [up(17)])
        _ = t.modifierChanged(keyCode: UInt16(kVK_Shift), flags: shiftFlags)
        _ = t.physicalDown(keyCode: UInt16(kVK_LeftArrow), modifiers: shiftFlags, isRepeat: false)
        #expect(Set(t.releaseAll()) == [up(EvdevKey.left), up(shiftL)])
        #expect(t.pressedKeyCount == 0)
        #expect(t.releaseAll().isEmpty)
    }

    @Test func backspacesForReplacedText() {
        var t = KeyEventTranslator()
        #expect(t.backspaces(2) == press(EvdevKey.backspace) + press(EvdevKey.backspace))
        #expect(t.backspaces(0).isEmpty)
        #expect(KeyEventTranslator.backPress == press(158))
    }
}

@MainActor
@Suite struct TypingSequencerTests {
    final class Log: @unchecked Sendable {
        let entries = Locked<[String]>([])
        let clipboard = Locked("previous")
        func add(_ s: String) { entries.withLock { $0.append(s) } }
    }

    func make(_ log: Log) -> TypingSequencer {
        let s = TypingSequencer(timing: .init(clipboardSettle: .milliseconds(1), pasteSettle: .milliseconds(30), restoreDelay: .milliseconds(40), minKeyInterval: .zero, imeSettle: .zero),
                                pasteChord: [down(29), up(29)])
        s.send = { events in
            for e in events { if case .key(let k) = e { log.add("\(k.eventType == .keydown ? "d" : "u")\(k.keyCode)") } }
            return true
        }
        s.setClipboard = { text in log.add("set:\(text)"); log.clipboard.withLock { $0 = text } }
        s.getClipboard = { log.add("get"); return log.clipboard.current }
        return s
    }

    @Test func keysAfterAPasteWaitForIt() async {
        let log = Log()
        let s = make(log)
        s.perform([.events(press(30)), .paste("é"), .events(press(48))])
        s.events(press(46))
        #expect(await s.waitUntilIdle())
        #expect(log.entries.current == ["d30", "u30", "get", "set:é", "d29", "u29", "d48", "u48", "d46", "u46"])
        // The guest clipboard gets its previous value back once typing is quiet.
        try? await Task.sleep(for: .milliseconds(150))
        #expect(log.entries.current.last == "set:previous")
        #expect(log.clipboard.current == "previous")
    }

    @Test func pastesAreSpacedAndCoalesced() async {
        let log = Log()
        let s = make(log)
        let t0 = ContinuousClock.now
        s.paste("中", restoreClipboard: true)
        s.events(press(30))
        s.paste("文", restoreClipboard: true)
        s.paste("字", restoreClipboard: true)   // queued behind the first: merged with the previous paste
        #expect(await s.waitUntilIdle())
        let elapsed = ContinuousClock.now - t0
        let sets = log.entries.current.filter { $0.hasPrefix("set:") }
        #expect(sets == ["set:中", "set:文字"])
        #expect(elapsed >= .milliseconds(30))   // the second clipboard value waited for the first Ctrl+V
    }

    @Test func burstsOfKeyDownsArePaced() async {
        let log = Log()
        let s = make(log)
        s.timing.minKeyInterval = .milliseconds(5)
        let t0 = ContinuousClock.now
        s.events(press(30))                       // one key-down: sent at once
        #expect(log.entries.current == ["d30", "u30"])
        s.events(press(48) + press(46) + press(32))   // a burst: queued, one down per 5 ms
        #expect(!s.isIdle)
        #expect(await s.waitUntilIdle())
        #expect(log.entries.current == ["d30", "u30", "d48", "u48", "d46", "u46", "d32", "u32"])
        #expect(ContinuousClock.now - t0 >= .milliseconds(15))
        s.events([up(30)])                        // releases never wait
        #expect(log.entries.current.last == "u30")
    }

    @Test func keysThatBypassTheInputMethodWaitForIt() async {
        let log = Log()
        let s = make(log)
        s.timing.imeSettle = .milliseconds(40)
        let t0 = ContinuousClock.now
        s.events(press(30))                     // "a": Gboard turns it into text asynchronously
        s.events(press(EvdevKey.left))          // ← goes straight to the app: must not overtake the "a"
        #expect(log.entries.current == ["d30", "u30"])
        #expect(await s.waitUntilIdle())
        #expect(log.entries.current == ["d30", "u30", "d105", "u105"])
        #expect(ContinuousClock.now - t0 >= .milliseconds(40))
        s.events(press(48))                     // and a character after the arrow waits for the arrow
        #expect(log.entries.current.suffix(2) == ["d105", "u105"])
        #expect(await s.waitUntilIdle())
        #expect(log.entries.current.suffix(2) == ["d48", "u48"])
    }

    @Test func stickyShiftIsClearedBeforeAppKeys() async {
        let log = Log()
        let s = make(log)
        // Shift+X: Gboard takes the X, so the text field saw a lone Shift tap → Shift sticky.
        s.events([down(shiftL), down(45), up(45), up(shiftL)])
        #expect(s.stickyShift)
        s.events(press(EvdevKey.left))           // ← would select: one Shift tap first
        #expect(await s.waitUntilIdle())
        #expect(log.entries.current.suffix(4) == ["d42", "u42", "d105", "u105"])
        #expect(!s.stickyShift)
        // Shift held while an app key is pressed (⇧← selection): used, not sticky; no extra tap.
        s.events([down(shiftL)])
        s.events(press(EvdevKey.left))
        s.events([up(shiftL)])
        #expect(await s.waitUntilIdle())
        #expect(!s.stickyShift)
        let before = log.entries.current.count
        s.events(press(EvdevKey.right))
        #expect(await s.waitUntilIdle())
        #expect(Array(log.entries.current[before...]) == ["d106", "u106"])
        // Lowercase typing leaves nothing sticky.
        s.events(press(30))
        s.events(press(EvdevKey.left))
        #expect(await s.waitUntilIdle())
        #expect(log.entries.current.suffix(4) == ["d30", "u30", "d105", "u105"])
    }

    @Test func commandVKeepsTheMacTextInTheGuestClipboard() async {
        let log = Log()
        let s = make(log)
        s.paste("from mac", restoreClipboard: false)
        #expect(await s.waitUntilIdle())
        try? await Task.sleep(for: .milliseconds(150))
        #expect(log.entries.current == ["set:from mac", "d29", "u29"])
        #expect(log.clipboard.current == "from mac")
    }
}
