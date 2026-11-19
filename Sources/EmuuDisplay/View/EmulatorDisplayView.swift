import AppKit
import QuartzCore
import Carbon.HIToolbox
import EmuuBase
import EmuuGRPC

/// Layer-hosting view that shows the engine's framebuffer (IOSurface contents, aspect-fit, letterboxed) and
/// turns mouse, trackpad and keyboard input into engine input events.
///
/// Host shortcuts (⌘ is never forwarded to the device):
/// ⌘B back · ⌘⇧H home · ⌘S recent apps · ⌘R rotate · ⌘P power · ⌘N notifications · ⌘V paste host clipboard ·
/// ⌘C/⌘X copy/cut the device selection to the host · ⌘↑/⌘↓ volume.
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
    /// Clipboard actions that need the session.
    public var setDeviceClipboard: ((_ text: String, _ paste: Bool) -> Void)?
    /// ⌘C / ⌘X: the device copies/cuts its selection; the clipboard stream brings it to the host.
    public var requestDeviceCopy: ((_ cut: Bool) -> Void)?

    /// Size of the frames being shown (already rotated by the engine).
    public private(set) var videoSize = VideoSize(width: 0, height: 0)
    public private(set) var rotation: SkinRotation = .portrait
    private var physicalSize = VideoSize(width: 0, height: 0)
    private var pointer = PointerInputTranslator(mapper: AspectFitMapper(viewSize: .zero, videoSize: VideoSize(width: 0, height: 0)),
                                                 device: DeviceTouchMapper(physical: VideoSize(width: 0, height: 0), rotation: .portrait))
    private var keys = KeyEventTranslator()
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

    @discardableResult
    private func dispatch(_ events: [EmulatorInputEvent], userInitiated: Bool = true) -> Bool {
        guard !events.isEmpty else { return false }
        if userInitiated { onUserInteraction?() }
        return sendInput?(events) ?? false
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
        window?.makeFirstResponder(self)
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

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        dispatch(keys.translate(HostKeyEvent(kind: .down, keyCode: event.keyCode, characters: event.characters,
                                             modifiers: event.modifierFlags, isRepeat: event.isARepeat)))
    }

    public override func keyUp(with event: NSEvent) {
        dispatch(keys.translate(HostKeyEvent(kind: .up, keyCode: event.keyCode, characters: event.characters,
                                             modifiers: event.modifierFlags)))
    }

    public override func flagsChanged(with event: NSEvent) {
        dispatch(keys.modifierChanged(keyCode: event.keyCode, flags: event.modifierFlags))
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown,
              event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        let shift = event.modifierFlags.contains(.shift)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        func press(_ k: DeviceKey) {
            onUserInteraction?()
            pressKey?(k)
        }
        switch (key, shift) {
        case ("b", false): press(.back)
        case ("h", true): press(.home)
        case ("s", false): press(.appSwitch)
        case ("r", false):
            onUserInteraction?()
            onRotate?()
        case ("p", false): press(.power)
        case ("n", false): pullDownNotifications()
        case ("v", false) where hostClipboardEnabled:
            guard let text = NSPasteboard.general.string(forType: .string) else { return true }
            onUserInteraction?()
            setDeviceClipboard?(text, true)
        case ("c", false) where hostClipboardEnabled:
            onUserInteraction?()
            requestDeviceCopy?(false)
        case ("x", false) where hostClipboardEnabled:
            onUserInteraction?()
            requestDeviceCopy?(true)
        default:
            if Int(event.keyCode) == kVK_UpArrow { press(.volumeUp); return true }
            if Int(event.keyCode) == kVK_DownArrow { press(.volumeDown); return true }
            return super.performKeyEquivalent(with: event)
        }
        return true
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
        releaseAllInput()
        return super.resignFirstResponder()
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
