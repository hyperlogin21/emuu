import AppKit
import QuartzCore
import Carbon.HIToolbox
import EmuuGRPC

/// macOS text input for the device screen. macOS (keyboard layout, dead keys, press-and-hold, emoji picker,
/// dictation, input methods) produces the text; it reaches the guest as typed keys or, for characters Android's
/// hardware keyboard cannot type, as a paste (`KeyEventTranslator.typed`, `TypingSequencer`).
///
/// The guest's text is not readable from here, so the view keeps `typedShadow`: what it typed since the last click or
/// navigation key. That is enough for input methods that replace what they just committed (press-and-hold turns
/// "e" into "é" with `insertText(_:replacementRange:)`). Marked (still composing) text stays on the Mac, shown in
/// an overlay at the bottom of the screen; nothing reaches the device until the input method commits it.
extension EmulatorDisplayView: @preconcurrency NSTextInputClient {
    static let typedShadowLimit = 256

    // MARK: NSTextInputClient

    public func insertText(_ string: Any, replacementRange: NSRange) {
        textInputHandled = true
        let text = Self.plainString(string)
        let wasComposing = !markedString.isEmpty
        setMarked("")
        if !wasComposing, replacementRange.location != NSNotFound {
            deleteTypedShadowSuffix(from: replacementRange.location)
        }
        guard !text.isEmpty else { return }
        let event = currentKeyEvent
        let keyCode = wasComposing ? nil : event?.keyCode
        typing.perform(keys.typed(text, keyCode: keyCode, modifiers: event?.modifierFlags ?? NSEvent.modifierFlags))
        appendTypedShadow(text)
        if event == nil { noteMacTyping() }   // emoji picker, dictation, commits by click
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        textInputHandled = true
        if markedString.isEmpty, replacementRange.location != NSNotFound {
            deleteTypedShadowSuffix(from: replacementRange.location)
        }
        markedSelection = selectedRange
        setMarked(Self.plainString(string))
    }

    public func unmarkText() {
        commitMarkedText()
    }

    public func selectedRange() -> NSRange {
        let base = typedShadow.utf16.count
        guard !markedString.isEmpty else { return NSRange(location: base, length: 0) }
        return NSRange(location: base + markedSelection.location, length: markedSelection.length)
    }

    public func markedRange() -> NSRange {
        markedString.isEmpty ? NSRange(location: NSNotFound, length: 0)
                             : NSRange(location: typedShadow.utf16.count, length: markedString.utf16.count)
    }

    public func hasMarkedText() -> Bool { !markedString.isEmpty }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let all = (typedShadow + markedString) as NSString
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: all.length))
        guard clamped.length > 0 || range.length == 0 else { return nil }
        actualRange?.pointee = clamped
        return NSAttributedString(string: all.substring(with: clamped))
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// Where candidate windows and the press-and-hold popup appear: at the marked-text overlay, or at the
    /// bottom centre of the device screen.
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        let local: CGRect
        if !markedLayer.isHidden {
            local = markedLayer.frame
        } else {
            let c = mapper.contentRect.isEmpty ? bounds : mapper.contentRect
            local = CGRect(x: c.midX - 1, y: c.maxY - 64, width: 2, height: 22)
        }
        guard let window else { return local }
        return window.convertToScreen(convert(local, to: nil))
    }

    public func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    public override func doCommand(by selector: Selector) {
        textInputHandled = true
        // Keys that reach here produced no text: send the key itself (Return while an input method is active
        // but not composing, Backspace after a commit…).
        if let e = currentKeyEvent, MacKeyMap.evdev[Int(e.keyCode)] != nil, MacKeyMap.nonCharacter.contains(Int(e.keyCode)) {
            if Self.focusChangingKeys.contains(Int(e.keyCode)) { focusEpoch &+= 1 }
            resetTypedShadow()
            dispatch(keys.physicalDown(keyCode: e.keyCode, modifiers: e.modifierFlags, isRepeat: e.isARepeat))
            return
        }
        let mapped: [Selector: Int] = [
            #selector(insertNewline(_:)): EvdevKey.enter, #selector(insertTab(_:)): EvdevKey.tab,
            #selector(deleteBackward(_:)): EvdevKey.backspace, #selector(deleteForward(_:)): EvdevKey.delete,
            #selector(cancelOperation(_:)): EvdevKey.esc, #selector(moveLeft(_:)): EvdevKey.left,
            #selector(moveRight(_:)): EvdevKey.right, #selector(moveUp(_:)): EvdevKey.up, #selector(moveDown(_:)): EvdevKey.down,
        ]
        if let code = mapped[selector] {
            resetTypedShadow()
            dispatch(keys.press(code, shift: keys.guestShift, control: false))
        }
    }

    // MARK: Composition overlay

    func setUpMarkedLayer() {
        markedLayer.isHidden = true
        markedLayer.alignmentMode = .center
        markedLayer.foregroundColor = NSColor.white.cgColor
        markedLayer.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor
        markedLayer.cornerRadius = 6
        markedLayer.fontSize = 17
        markedLayer.font = NSFont.systemFont(ofSize: 17)
        markedLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        markedLayer.zPosition = 10
        displayLayer.addSublayer(markedLayer)
    }

    private func setMarked(_ text: String) {
        markedString = text
        if text.isEmpty { markedSelection = NSRange(location: 0, length: 0) }
        layoutMarkedLayer()
    }

    /// The composition, underlined, centred near the bottom of the device screen.
    func layoutMarkedLayer() {
        guard !markedString.isEmpty else {
            markedLayer.isHidden = true
            return
        }
        let font = NSFont.systemFont(ofSize: 17)
        let attributed = NSAttributedString(string: markedString, attributes: [
            .font: font, .foregroundColor: NSColor.white, .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        let content = mapper.contentRect.isEmpty ? bounds : mapper.contentRect
        let size = attributed.size()
        let width = min(ceil(size.width) + 20, max(content.width - 16, 40))
        let height = ceil(size.height) + 8
        markedLayer.string = attributed
        markedLayer.contentsScale = window?.backingScaleFactor ?? 2
        markedLayer.frame = CGRect(x: content.midX - width / 2, y: content.maxY - height - 56, width: width, height: height)
        markedLayer.isHidden = false
    }

    /// Commits the composition as typed text (click, focus loss, ⌘ shortcut), as text views do.
    func commitMarkedText() {
        guard !markedString.isEmpty else { return }
        let text = markedString
        inputContext?.discardMarkedText()
        setMarked("")
        let saved = currentKeyEvent
        currentKeyEvent = nil
        insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        currentKeyEvent = saved
    }

    // MARK: Typed shadow text

    func resetTypedShadow() {
        typedShadow = ""
    }

    func typedShadowDeleteBackward() {
        if !typedShadow.isEmpty { typedShadow.removeLast() }
    }

    private func appendTypedShadow(_ text: String) {
        typedShadow += text
        if typedShadow.utf16.count > Self.typedShadowLimit { typedShadow = "" }   // ranges restart; old text is out of reach
    }

    /// Deletes (on the device too) what was committed from `utf16Location` to the end of the typedShadow text.
    private func deleteTypedShadowSuffix(from utf16Location: Int) {
        let ns = typedShadow as NSString
        guard utf16Location >= 0, utf16Location < ns.length else { return }
        let removed = ns.substring(from: utf16Location)
        typedShadow = ns.substring(to: utf16Location)
        dispatch(keys.backspaces(removed.count))
    }

    // MARK: Soft keyboard

    /// Reports the start of Mac typing (first key after 2 s, a click or a focus change).
    func noteMacTyping() {
        let now = ContinuousClock.now
        defer { lastMacTyping = (now, focusEpoch) }
        if let last = lastMacTyping, last.epoch == focusEpoch, now - last.at < .seconds(2) { return }
        onMacTyping?(focusEpoch)
    }

    /// Sends BACK — which closes only the soft keyboard while it is shown — unless a click or a focus-moving key
    /// happened since `epoch` (the keyboard may then belong to another field, or be gone, and BACK would
    /// navigate). It goes on the input stream behind the keys already typed.
    @discardableResult
    public func hideSoftKeyboardIfFocusUnchanged(since epoch: UInt64) -> Bool {
        guard epoch == focusEpoch, !keys.guestControl else { return false }
        dispatch(KeyEventTranslator.backPress, userInitiated: false)
        return true
    }

    static func plainString(_ value: Any) -> String {
        if let a = value as? NSAttributedString { return a.string }
        if let s = value as? String { return s }
        return ""
    }
}
