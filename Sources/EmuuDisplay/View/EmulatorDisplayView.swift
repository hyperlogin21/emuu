import AppKit
import QuartzCore
import Carbon.HIToolbox
import EmuuBase
import EmuuGRPC

/// Layer-hosting view that shows the engine's framebuffer (IOSurface contents, aspect-fit, letterboxed) and
/// turns mouse, trackpad and keyboard input into engine input events.
///
/// Typing: the view is an `NSTextInputClient`, so the Mac's keyboard layout, dead keys, press-and-hold accents,
/// the emoji picker and input methods (Pinyin, Japanese…) produce the text; `KeyEventTranslator` decides what
/// goes to the guest as keys and what as pasted text (rule in KeyMapping.swift), `TypingSequencer` keeps it in order.
///
/// Host shortcuts (⌘ is never forwarded to the device):
/// ⌘B back · ⌘⇧H home · ⌘S recent apps · ⌘R rotate · ⌘P power · ⌘N notifications · ⌘↑/⌘↓ volume ·
/// ⌘V paste the Mac clipboard · ⌘C/⌘X copy/cut the device selection (it reaches the Mac clipboard) ·
/// ⌘A select all · ⌘Z/⇧⌘Z undo/redo · ⌘←/⌘→ line start/end (⇧ selects) · ⌘⌫ delete to line start.
@MainActor
public final class EmulatorDisplayView: NSView {
    public let displayLayer = CALayer()

    /// Where input goes (normally `EmulatorDisplaySession.send`).
    public var sendInput: (@Sendable ([EmulatorInputEvent]) -> Bool)?
    /// Device buttons (back/home/…).
    public var pressKey: ((DeviceKey) -> Void)?
    /// ⌘R.
    public var onRotate: (() -> Void)?
    /// Called with every user input (for `DisplayActivityTracker.noteInteraction`).
    public var onUserInteraction: (() -> Void)?
    /// Files dropped on the device screen (APK install). Setting it registers the view for file drags.
    public var onFileDrop: (([URL]) -> Void)? {
        didSet {
            if onFileDrop != nil { registerForDraggedTypes([.fileURL]) } else { unregisterDraggedTypes() }
        }
    }
    public var onDropTargeted: ((Bool) -> Void)?
    /// Called after a left-button tap/drag ends, with the release point in **physical device pixels** (the
    /// coordinate space of `adb shell input tap`). The app checks the soft keyboard after taps.
    public var onPointerUp: ((_ x: Int, _ y: Int) -> Void)?
    /// Called when on-screen visibility or key-window focus changes.
    public var onVisibilityChange: ((_ visible: Bool, _ focused: Bool) -> Void)?
    public var hostClipboardEnabled = true
    /// Ordered keyboard/pointer output; text the guest keyboard cannot type goes through the guest clipboard
    /// (the controller sets its clipboard closures).
    public let typing = TypingSequencer(pasteChord: KeyEventTranslator().pasteChord)
    /// The user started typing on the Mac keyboard (first key after a pause, a click or a focus change), with the
    /// `focusEpoch` at that moment. The app hides Android's soft keyboard then (`hideSoftKeyboardIfFocusUnchanged`).
    public var onMacTyping: ((_ focusEpoch: UInt64) -> Void)?
    /// Bumped by clicks and keys that may move focus (Return, Tab, Escape).
    public internal(set) var focusEpoch: UInt64 = 0

    /// Size of the frames being shown (already rotated by the engine).
    public private(set) var videoSize = VideoSize(width: 0, height: 0)
    public private(set) var rotation: SkinRotation = .portrait
    private var physicalSize = VideoSize(width: 0, height: 0)
    private var pointer = PointerInputTranslator(mapper: AspectFitMapper(viewSize: .zero, videoSize: VideoSize(width: 0, height: 0)),
                                                 device: DeviceTouchMapper(physical: VideoSize(width: 0, height: 0), rotation: .portrait))
    var keys = KeyEventTranslator()
    // Text input state (EmulatorDisplayView+TextInput.swift).
    var currentKeyEvent: NSEvent?
    var textInputHandled = false
    var markedString = ""
    var markedSelection = NSRange(location: 0, length: 0)
    /// Text committed since the last click/navigation key, so input methods can address it (press-and-hold
    /// replaces the character it follows).
    var typedShadow = ""
    var lastMacTyping: (at: ContinuousClock.Instant, epoch: UInt64)?
    let markedLayer = CATextLayer()
    private var windowObservers: [NSObjectProtocol] = []
    public private(set) lazy var frameSink = LayerFrameSink(layer: displayLayer)

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        displayLayer.contentsGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.isOpaque = true
        displayLayer.minificationFilter = .trilinear
        displayLayer.magnificationFilter = .linear
        displayLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer = displayLayer
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setUpMarkedLayer()
        typing.send = { [weak self] events in self?.sendInput?(events) ?? false }
    }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override var isOpaque: Bool { true }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        displayLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    /// New frame geometry (first frame, rotation). Lifts held fingers (their coordinates would be stale).
    public func setGeometry(frame size: VideoSize, rotation: SkinRotation, physical: VideoSize?) {
        guard size != videoSize || rotation != self.rotation || (physical.map { $0 != physicalSize } ?? false) else { return }
        dispatch(pointer.cancelAll(), userInitiated: false)
        videoSize = size
        self.rotation = rotation
        physicalSize = physical ?? (rotation.isLandscape ? size.swapped : size)
        updateMapper()
    }

    /// Releases held keys and touches.
    public func releaseAllInput() {
        dispatch(pointer.cancelAll(), userInitiated: false)
        releaseKeys()
    }

    /// Releases held keys and modifiers in the guest.
    public func releaseKeys() {
        dispatch(keys.releaseAll(), userInitiated: false)
    }

    public var mapper: AspectFitMapper { pointer.mapper }
    public var touchMapper: DeviceTouchMapper { pointer.device }

    public override func layout() {
        super.layout()
        updateMapper()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateMapper()
    }

    private func updateMapper() {
        pointer.mapper = AspectFitMapper(viewSize: bounds.size, videoSize: videoSize)
        pointer.device = DeviceTouchMapper(physical: physicalSize, rotation: rotation)
    }

    /// Every input event leaves through the sequencer, so it stays behind text still being pasted.
    @discardableResult
    func dispatch(_ events: [EmulatorInputEvent], userInitiated: Bool = true) -> Bool {
        guard !events.isEmpty else { return false }
        if userInitiated { onUserInteraction?() }
        return typing.events(events)
    }

    private func location(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private static func pressure(_ event: NSEvent) -> Float {
        let p = Float(event.pressure)
        if event.type == .pressure, event.stage >= 2 { return 1 }
        return p
    }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) {
        commitMarkedText()
        window?.makeFirstResponder(self)
        focusEpoch &+= 1
        resetTypedShadow()
        typing.resetFieldState()
        dispatch(pointer.mouseDown(.left, at: location(event), pressure: Self.pressure(event)))
    }

    public override func mouseDragged(with event: NSEvent) {
        dispatch(pointer.mouseDragged(.left, to: location(event), pressure: Self.pressure(event)))
    }

    public override func mouseUp(with event: NSEvent) {
        let p = location(event)
        dispatch(pointer.mouseUp(.left, at: p))
        if let v = mapper.videoPoint(fromView: p, clamp: false) {
            let d = touchMapper.physicalPoint(frameX: v.x, frameY: v.y)
            onPointerUp?(d.x, d.y)
        }
    }

    public override func pressureChange(with event: NSEvent) {
        guard pointer.isTouching, NSEvent.pressedMouseButtons & 1 != 0 else { return }
        dispatch(pointer.mouseDragged(.left, to: location(event), pressure: Self.pressure(event)))
    }

    public override func rightMouseDown(with event: NSEvent) {
        dispatch(pointer.mouseDown(.right, at: location(event), pressure: 1))
    }

    public override func rightMouseUp(with event: NSEvent) {
        dispatch(pointer.mouseUp(.right, at: location(event)))
    }

    public override func otherMouseDown(with event: NSEvent) {
        guard let button = HostMouseButton(rawValue: event.buttonNumber) else { return }
        dispatch(pointer.mouseDown(button, at: location(event), pressure: 1))
    }

    public override func otherMouseUp(with event: NSEvent) {
        guard let button = HostMouseButton(rawValue: event.buttonNumber) else { return }
        dispatch(pointer.mouseUp(button, at: location(event)))
    }

    public override func scrollWheel(with event: NSEvent) {
        dispatch(pointer.scroll(at: location(event), deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                                precise: event.hasPreciseScrollingDeltas))
    }

    public override func magnify(with event: NSEvent) {
        switch event.phase {
        case .began:
            dispatch(pointer.beginPinch(at: location(event)))
            dispatch(pointer.updatePinch(delta: event.magnification))
        case .changed:
            dispatch(pointer.updatePinch(delta: event.magnification))
        case .ended, .cancelled:
            dispatch(pointer.endPinch())
        default:
            break
        }
    }

    // MARK: File drops

    private static func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard onFileDrop != nil, !Self.fileURLs(sender).isEmpty else { return [] }
        onDropTargeted?(true)
        return .copy
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onFileDrop != nil && !Self.fileURLs(sender).isEmpty ? .copy : []
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) { onDropTargeted?(false) }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDropTargeted?(false)
        let urls = Self.fileURLs(sender)
        guard let onFileDrop, !urls.isEmpty else { return false }
        onFileDrop(urls)
        return true
    }

    // MARK: Keyboard (text input: EmulatorDisplayView+TextInput.swift)

    public override func keyDown(with event: NSEvent) {
        onUserInteraction?()
        let route = KeyEventTranslator.route(keyCode: event.keyCode, modifiers: event.modifierFlags, hasMarkedText: hasMarkedText())
        switch route {
        case .ignore:
            return
        case .physical:
            let code = Int(event.keyCode)
            if Self.focusChangingKeys.contains(code) { focusEpoch &+= 1 }
            if code == kVK_Delete, !event.modifierFlags.contains(.option) { typedShadowDeleteBackward() } else { resetTypedShadow() }
            dispatch(keys.physicalDown(keyCode: event.keyCode, modifiers: event.modifierFlags, isRepeat: event.isARepeat))
        case .text:
            currentKeyEvent = event
            defer { currentKeyEvent = nil }
            textInputHandled = false
            interpretKeyEvents([event])
            if !textInputHandled, !hasMarkedText(), let chars = event.characters, KeyEventTranslator.isTypable(chars) {
                // No input context (tests, some synthesized events): the characters the key produced.
                insertText(chars, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            noteMacTyping()
        }
    }

    public override func keyUp(with event: NSEvent) {
        dispatch(keys.keyUp(keyCode: event.keyCode))
    }

    public override func flagsChanged(with event: NSEvent) {
        dispatch(keys.modifierChanged(keyCode: event.keyCode, flags: event.modifierFlags))
    }

    /// Keys after which the focused field may change (a BACK to hide the soft keyboard must not follow them).
    static let focusChangingKeys: Set<Int> = [kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_Escape]

    /// ⌘ shortcuts while the device screen has keyboard focus. Device actions (back, home, rotate…) and text
    /// editing (⌘A/C/X/V/Z, ⌘←/→, ⌘⌫) are handled here; every other ⌘ chord (⌘Q, ⌘W, ⌘M, ⌘,, ⌘K, ⌥⌘R, ⇧⌘S…)
    /// goes on to the menus.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown,
              let action = Self.commandAction(for: event, hostClipboard: hostClipboardEnabled) else {
            return super.performKeyEquivalent(with: event)
        }
        commitMarkedText()
        onUserInteraction?()
        func press(_ k: DeviceKey) { pressKey?(k) }
        switch action {
        case .device(let k): press(k)
        case .rotate: onRotate?()
        case .notifications: pullDownNotifications()
        case .pasteHostClipboard:
            resetTypedShadow()
            if let text = NSPasteboard.general.string(forType: .string) { typing.paste(text, restoreClipboard: false) }
        case .edit(let s):
            resetTypedShadow()
            dispatch(keys.syncModifiers(event.modifierFlags.intersection([.shift])) + keys.shortcut(s, selecting: event.modifierFlags.contains(.shift)))
        }
        return true
    }

    /// What a ⌘ chord does on the device (nil: not ours).
    public enum CommandAction: Sendable, Hashable {
        case device(DeviceKey), rotate, notifications, pasteHostClipboard, edit(EditShortcut)
    }

    public static func commandAction(for event: NSEvent, hostClipboard: Bool) -> CommandAction? {
        let flags = event.modifierFlags
        guard flags.contains(.command), !flags.contains(.option), !flags.contains(.control) else { return nil }
        let shift = flags.contains(.shift)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch Int(event.keyCode) {
        case kVK_UpArrow: return .device(.volumeUp)
        case kVK_DownArrow: return .device(.volumeDown)
        case kVK_LeftArrow: return .edit(.lineStart)
        case kVK_RightArrow: return .edit(.lineEnd)
        case kVK_Delete: return shift ? nil : .edit(.deleteToLineStart)
        case kVK_ForwardDelete: return shift ? nil : .edit(.deleteToLineEnd)
        default: break
        }
        switch (key, shift) {
        case ("b", false): return .device(.back)
        case ("h", true): return .device(.home)
        case ("s", false): return .device(.appSwitch)
        case ("r", false): return .rotate
        case ("p", false): return .device(.power)
        case ("n", false): return .notifications
        case ("a", false): return .edit(.selectAll)
        case ("z", false): return .edit(.undo)
        case ("z", true): return .edit(.redo)
        case ("v", false) where hostClipboard: return .pasteHostClipboard
        case ("c", false) where hostClipboard: return .edit(.copy)
        case ("x", false) where hostClipboard: return .edit(.cut)
        default: return nil
        }
    }

    // Edit menu items clicked with the mouse while the device screen has focus.
    @objc public override func selectAll(_ sender: Any?) { dispatch(keys.shortcut(.selectAll)) }
    @objc public func copy(_ sender: Any?) { if hostClipboardEnabled { dispatch(keys.shortcut(.copy)) } }
    @objc public func cut(_ sender: Any?) { if hostClipboardEnabled { dispatch(keys.shortcut(.cut)) } }
    @objc public func paste(_ sender: Any?) {
        guard hostClipboardEnabled, let text = NSPasteboard.general.string(forType: .string) else { return }
        commitMarkedText()
        typing.paste(text, restoreClipboard: false)
    }

    /// ⌘N: a finger swipe down from the top edge, like on the phone.
    private func pullDownNotifications() {
        guard !videoSize.isEmpty else { return }
        let x = videoSize.width / 2
        let steps = 8
        var events: [EmulatorInputEvent] = []
        for i in 0...steps {
            let y = (videoSize.height * 2 / 3) * i / steps
            let d = touchMapper.physicalPoint(frameX: x, frameY: max(y, 1))
            events.append(.touch([EmulatorTouch(x: d.x, y: d.y, identifier: 0, pressure: i == steps ? 0 : 512)]))
        }
        dispatch(events)
    }

    public override func resignFirstResponder() -> Bool {
        commitMarkedText()
        releaseAllInput()
        return super.resignFirstResponder()
    }

    public override func becomeFirstResponder() -> Bool {
        focusEpoch &+= 1
        resetTypedShadow()
        return super.becomeFirstResponder()
    }

    /// Takes keyboard focus when nothing else in the window has it, so typing works as soon as the window is
    /// key (after opening it, switching back to it, or clicking the control strip).
    func claimKeyboardFocusIfUnowned() {
        guard let window, window.firstResponder !== self else { return }
        let owner = window.firstResponder
        if owner == nil || owner === window || !(owner is NSText || owner is NSTextField || owner is NSTextInputClient) {
            window.makeFirstResponder(self)
        }
    }

    // MARK: Visibility

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        windowObservers.forEach(center.removeObserver)
        windowObservers.removeAll()
        guard let window else {
            onVisibilityChange?(false, false)
            return
        }
        displayLayer.contentsScale = window.backingScaleFactor
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification, NSWindow.didChangeScreenNotification,
        ]
        for name in names {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportVisibility() }
            })
        }
        // Keys: never leave one held in the guest when the window stops receiving key-ups; take focus when key.
        windowObservers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseKeys() }
        })
        windowObservers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.claimKeyboardFocusIfUnowned() }
        })
        windowObservers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseKeys() }
        })
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.claimKeyboardFocusIfUnowned() }
        }
        // Un-minimise: the occlusion state can lag behind the zoom animation (or not be re-posted at all), so
        // report again once the animation is over.
        windowObservers.append(center.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportVisibilitySoon() }
        })
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didUnhideNotification] {
            windowObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportVisibilitySoon() }
            })
        }
        reportVisibility()
    }

    public override func viewDidHide() {
        super.viewDidHide()
        reportVisibility()
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        reportVisibility()
    }

    /// Whether the view is actually on screen (key window of the active app, or AppKit's occlusion state).
    public var isEffectivelyVisible: Bool {
        guard let window, !isHiddenOrHasHiddenAncestor, !window.isMiniaturized, window.isVisible else { return false }
        if window.isKeyWindow && NSApp.isActive { return true }
        return window.occlusionState.contains(.visible)
    }

    private func reportVisibilitySoon() {
        reportVisibility()
        for delay in [0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.reportVisibility() }
            }
        }
    }

    private func reportVisibility() {
        let visible = isEffectivelyVisible
        if !visible { releaseAllInput() }
        onVisibilityChange?(visible, visible && (window?.isKeyWindow ?? false))
    }
}
