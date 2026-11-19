import Testing
import AppKit
import Carbon.HIToolbox
import EmuuBase
import EmuuGRPC
@testable import EmuuDisplay

@MainActor
@Suite struct EmulatorDisplayViewTests {
    final class Captured: @unchecked Sendable {
        let events = Locked<[EmulatorInputEvent]>([])
    }

    func makeView() -> (EmulatorDisplayView, Captured, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 800), styleMask: [.titled], backing: .buffered, defer: true)
        let view = EmulatorDisplayView(frame: NSRect(x: 0, y: 0, width: 360, height: 800))
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 800)
        let captured = Captured()
        view.sendInput = { e in captured.events.withLock { $0 += e }; return true }
        view.typing.timing.minKeyInterval = .zero
        view.typing.timing.imeSettle = .zero
        view.setGeometry(frame: VideoSize(width: 720, height: 1600), rotation: .portrait, physical: VideoSize(width: 720, height: 1600))
        return (view, captured, window)
    }

    @Test func layerHostingWithAspectFit() {
        let (view, _, _) = makeView()
        #expect(view.layer === view.displayLayer)
        #expect(view.displayLayer.contentsGravity == .resizeAspect)
        #expect(view.isFlipped)
        #expect(view.mapper.contentRect == CGRect(x: 0, y: 0, width: 360, height: 800))
    }

    @Test func mouseClickBecomesTouchAtMappedPosition() throws {
        let (view, captured, window) = makeView()
        var interactions = 0
        var pointerUp: (Int, Int)?
        view.onUserInteraction = { interactions += 1 }
        view.onPointerUp = { pointerUp = ($0, $1) }
        // Window y=600 (bottom-left origin) → view y=200 (flipped) → frame y=400.
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: 90, y: 600), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: mouse(.leftMouseDown))
        view.mouseUp(with: mouse(.leftMouseUp))
        #expect(captured.events.current == [
            .touch([EmulatorTouch(x: 180, y: 400, identifier: 0, pressure: 1024, touchMajor: 8)]),
            .touch([EmulatorTouch(x: 180, y: 400, identifier: 0, pressure: 0)]),
        ])
        #expect(interactions == 2)
        #expect(pointerUp.map { $0 == (180, 400) } == true)
    }

    @Test func landscapeClickReportsPhysicalPointerUp() {
        let (view, _, window) = makeView()
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 360)
        view.setGeometry(frame: VideoSize(width: 1600, height: 720), rotation: .landscape, physical: VideoSize(width: 720, height: 1600))
        var pointerUp: (Int, Int)?
        view.onPointerUp = { pointerUp = ($0, $1) }
        // View (300, 50) → frame (600, 100) → physical (619, 600).
        let loc = view.convert(NSPoint(x: 300, y: 50), to: nil)
        view.mouseUp(with: NSEvent.mouseEvent(with: .leftMouseUp, location: loc, modifierFlags: [], timestamp: 0,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!)
        #expect(pointerUp.map { $0 == (619, 600) } == true)
    }

    func key(_ type: NSEvent.EventType, _ code: Int, _ chars: String, _ mods: NSEvent.ModifierFlags = [], window: NSWindow, repeat r: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: r, keyCode: UInt16(code))!
    }

    @Test func keyEventsAreTranslated() async throws {
        let (view, captured, window) = makeView()
        view.keyDown(with: key(.keyDown, kVK_ANSI_A, "a", window: window))
        view.keyUp(with: key(.keyUp, kVK_ANSI_A, "a", window: window))
        view.keyDown(with: key(.keyDown, kVK_LeftArrow, "\u{F702}", window: window))
        view.keyUp(with: key(.keyUp, kVK_LeftArrow, "\u{F702}", window: window))
        #expect(captured.events.current == [.key(.evdev(30, .keydown)), .key(.evdev(30, .keyup)),
                                            .key(.evdev(105, .keydown)), .key(.evdev(105, .keyup))])
    }

    @Test func textInputClientPastesWhatTheKeyboardCannotType() async {
        let (view, captured, _) = makeView()
        let clip = Locked<[String]>([])
        view.typing.timing = .init(clipboardSettle: .milliseconds(1), pasteSettle: .milliseconds(5), restoreDelay: .milliseconds(5), minKeyInterval: .zero, imeSettle: .zero)
        view.typing.setClipboard = { t in clip.withLock { $0.append(t) } }
        view.typing.getClipboard = { "old" }
        let none = NSRange(location: NSNotFound, length: 0)
        // Dead key / input method: marked text stays on the Mac.
        view.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
        #expect(view.hasMarkedText())
        #expect(!view.markedLayer.isHidden)
        #expect(captured.events.current.isEmpty)
        view.insertText("é", replacementRange: none)
        #expect(!view.hasMarkedText())
        #expect(view.markedLayer.isHidden)
        #expect(await view.typing.waitUntilIdle())
        #expect(clip.current.first == "é")
        #expect(captured.events.current == KeyEventTranslator().pasteChord)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(clip.current == ["é", "old"])
    }

    @Test func pressAndHoldReplacesTheTypedLetter() async {
        let (view, captured, _) = makeView()
        let clip = Locked<[String]>([])
        view.typing.timing = .init(clipboardSettle: .milliseconds(1), pasteSettle: .milliseconds(5), restoreDelay: .seconds(5), minKeyInterval: .zero, imeSettle: .zero)
        view.typing.setClipboard = { t in clip.withLock { $0.append(t) } }
        let none = NSRange(location: NSNotFound, length: 0)
        view.insertText("x", replacementRange: none)
        view.insertText("e", replacementRange: none)
        #expect(view.selectedRange() == NSRange(location: 2, length: 0))
        #expect(view.attributedSubstring(forProposedRange: NSRange(location: 1, length: 1), actualRange: nil)?.string == "e")
        view.insertText("é", replacementRange: NSRange(location: 1, length: 1))
        #expect(await view.typing.waitUntilIdle())
        let bs = EvdevKey.backspace
        #expect(captured.events.current == [.key(.evdev(45, .keydown)), .key(.evdev(45, .keyup)), .key(.evdev(18, .keydown)), .key(.evdev(18, .keyup)),
                                            .key(.evdev(bs, .keydown)), .key(.evdev(bs, .keyup))] + KeyEventTranslator().pasteChord)
        #expect(clip.current == ["é"])
    }

    @Test func commandShortcutsMapEditingAndLeaveMenusAlone() {
        let (view, captured, window) = makeView()
        window.makeFirstResponder(view)
        func cmd(_ c: String, _ code: Int, _ extra: NSEvent.ModifierFlags = []) -> NSEvent {
            key(.keyDown, code, c, NSEvent.ModifierFlags.command.union(extra), window: window)
        }
        #expect(view.performKeyEquivalent(with: cmd("a", kVK_ANSI_A)))
        #expect(captured.events.current == [.key(.evdev(29, .keydown)), .key(.evdev(30, .keydown)), .key(.evdev(30, .keyup)), .key(.evdev(29, .keyup))])
        for (c, code, extra) in [("q", kVK_ANSI_Q, NSEvent.ModifierFlags()), ("w", kVK_ANSI_W, []), ("m", kVK_ANSI_M, []), (",", kVK_ANSI_Comma, []),
                                 ("k", kVK_ANSI_K, []), ("r", kVK_ANSI_R, [.option]), ("c", kVK_ANSI_C, [.option]), ("s", kVK_ANSI_S, [.shift]),
                                 ("i", kVK_ANSI_I, []), ("0", kVK_ANSI_0, []), (" ", kVK_Space, [.control])] {
            #expect(EmulatorDisplayView.commandAction(for: cmd(c, code, extra), hostClipboard: true) == nil, "⌘\(c) must reach the menus")
        }
        #expect(EmulatorDisplayView.commandAction(for: cmd("", kVK_LeftArrow), hostClipboard: true) == .edit(.lineStart))
        #expect(EmulatorDisplayView.commandAction(for: cmd("z", kVK_ANSI_Z, [.shift]), hostClipboard: true) == .edit(.redo))
        #expect(EmulatorDisplayView.commandAction(for: cmd("v", kVK_ANSI_V), hostClipboard: true) == .pasteHostClipboard)
        #expect(EmulatorDisplayView.commandAction(for: cmd("v", kVK_ANSI_V), hostClipboard: false) == nil)
    }

    @Test func focusLossReleasesHeldKeys() {
        let (view, captured, window) = makeView()
        view.keyDown(with: key(.keyDown, kVK_ANSI_W, "w", window: window))
        view.keyDown(with: key(.keyDown, kVK_DownArrow, "\u{F701}", window: window))
        captured.events.withLock { $0.removeAll() }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(Set(captured.events.current) == [.key(.evdev(17, .keyup)), .key(.evdev(108, .keyup))])
    }

    @Test func softKeyboardHideIsCancelledByFocusChanges() {
        let (view, captured, window) = makeView()
        var started: [UInt64] = []
        view.onMacTyping = { started.append($0) }
        view.keyDown(with: key(.keyDown, kVK_ANSI_A, "a", window: window))
        view.keyDown(with: key(.keyDown, kVK_ANSI_B, "b", window: window))
        #expect(started.count == 1)   // once per burst
        let epoch = started[0]
        view.keyDown(with: key(.keyDown, kVK_Return, "\r", window: window))   // may submit and move focus
        captured.events.withLock { $0.removeAll() }
        #expect(!view.hideSoftKeyboardIfFocusUnchanged(since: epoch))
        #expect(view.hideSoftKeyboardIfFocusUnchanged(since: view.focusEpoch))
        #expect(captured.events.current == KeyEventTranslator.backPress)
    }

    @Test func geometryChangeReleasesHeldTouchWithoutCountingAsInteraction() {
        let (view, captured, window) = makeView()
        var interactions = 0
        view.onUserInteraction = { interactions += 1 }
        view.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        view.setGeometry(frame: VideoSize(width: 1600, height: 720), rotation: .landscape, physical: nil)
        #expect(captured.events.current.count == 2)
        if case .touch(let t, _) = captured.events.current[1] { #expect(t[0].pressure == 0) } else { Issue.record("no release") }
        #expect(interactions == 1)
        #expect(view.touchMapper.physical == VideoSize(width: 720, height: 1600))
    }

    @Test func commandShortcutsStayOnTheHost() {
        let (view, captured, window) = makeView()
        window.makeFirstResponder(view)
        var pressed: [DeviceKey] = []
        var rotated = 0
        view.pressKey = { pressed.append($0) }
        view.onRotate = { rotated += 1 }
        func cmd(_ c: String, _ code: Int, shift: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.command, .shift] : [.command], timestamp: 0,
                             windowNumber: window.windowNumber, context: nil, characters: c, charactersIgnoringModifiers: c,
                             isARepeat: false, keyCode: UInt16(code))!
        }
        #expect(view.performKeyEquivalent(with: cmd("b", kVK_ANSI_B)))
        #expect(view.performKeyEquivalent(with: cmd("h", kVK_ANSI_H, shift: true)))
        #expect(view.performKeyEquivalent(with: cmd("r", kVK_ANSI_R)))
        #expect(view.performKeyEquivalent(with: cmd("", kVK_UpArrow)))
        #expect(!view.performKeyEquivalent(with: cmd("q", kVK_ANSI_Q)))
        #expect(pressed == [.back, .home, .volumeUp])
        #expect(rotated == 1)
        #expect(captured.events.current.isEmpty)
    }
}
