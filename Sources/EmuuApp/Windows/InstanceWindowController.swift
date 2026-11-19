import AppKit
import SwiftUI
import EmuuBase
import EmuuDisplay

/// Pure window geometry for an emulator window: the device screen at its aspect ratio plus the fixed-width
/// control strip on the right (unit-tested).
enum InstanceWindowGeometry {
    /// Width of the control strip (points).
    static let stripWidth: CGFloat = 56
    /// The smallest device-screen height; below the strip's natural height it scrolls.
    static let minDisplayHeight: CGFloat = 360

    /// Content size for a device screen of `displayHeight` points.
    static func contentSize(displayHeight: CGFloat, aspect: CGSize) -> CGSize {
        let w = (displayHeight * aspect.width / max(aspect.height, 1)).rounded()
        return CGSize(width: w + stripWidth, height: displayHeight.rounded())
    }

    /// Adjusts a proposed content size during a live resize so the screen keeps its aspect ratio. The
    /// dimension the user changed more drives the other one.
    static func constrain(proposed: CGSize, current: CGSize, aspect: CGSize) -> CGSize {
        guard aspect.width > 0, aspect.height > 0 else { return proposed }
        let widthDriven = abs(proposed.width - current.width) > abs(proposed.height - current.height)
        var h = proposed.height
        if widthDriven { h = max(proposed.width - stripWidth, 1) * aspect.height / aspect.width }
        h = max(h, minDisplayHeight)
        return contentSize(displayHeight: h, aspect: aspect)
    }

    /// Initial / post-rotation size: as tall as fits (85 % of the screen, capped), never wider than 80 %.
    static func idealContentSize(aspect: CGSize, visible: CGSize) -> CGSize {
        let landscape = aspect.width > aspect.height
        var h = min(visible.height * 0.85, landscape ? 600 : 860)
        var size = contentSize(displayHeight: h, aspect: aspect)
        if size.width > visible.width * 0.8 {
            let displayW = visible.width * 0.8 - stripWidth
            h = displayW * aspect.height / aspect.width
            size = contentSize(displayHeight: h, aspect: aspect)
        }
        return size
    }
}

/// One emulator window. Plain AppKit (`NSWindow` + `NSHostingView`) instead of a SwiftUI `WindowGroup`:
/// a closed WindowGroup window, its hosting view and the `InstanceSession` it showed stayed alive
/// (measured ≈1.9 MB growth per open/close cycle). Here the app owns the window: closing it releases the
/// controller, the window and the SwiftUI tree, and the session detaches.
@MainActor
final class InstanceWindowController: NSWindowController, NSWindowDelegate {
    let id: InstanceID
    private weak var model: AppModel?
    private var aspect: CGSize
    private var sizedOnce = false
    nonisolated(unsafe) static var liveCount = 0

    init(id: InstanceID, model: AppModel) {
        self.id = id
        self.model = model
        let spec = model.session(for: id)?.config.display ?? .lightweightPhone
        aspect = CGSize(width: spec.width, height: spec.height)
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let size = InstanceWindowGeometry.idealContentSize(aspect: aspect, visible: visible)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenNone)
        window.title = model.session(for: id)?.displayName ?? id.rawValue
        window.contentMinSize = InstanceWindowGeometry.contentSize(displayHeight: InstanceWindowGeometry.minDisplayHeight, aspect: aspect)
        super.init(window: window)
        Self.liveCount += 1
        window.delegate = self

        let root = InstanceRootView(id: id) { [weak self] size in self?.videoSizeChanged(size) }
            .environment(model)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []          // the controller sizes the window, not SwiftUI
        window.contentView = hosting

        let badge = NSHostingView(rootView: SerialBadge(id: id).environment(model))
        badge.frame = NSRect(x: 0, y: 0, width: 140, height: 28)   // fits "emulator-5584" + icon
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = badge
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { Self.liveCount -= 1 }

    /// Video size known/changed: keep the aspect, resize on first frame and on rotation.
    func videoSizeChanged(_ size: VideoSize) {
        guard size.width > 0, size.height > 0, let window else { return }
        let newAspect = CGSize(width: size.width, height: size.height)
        let rotated = (newAspect.width > newAspect.height) != (aspect.width > aspect.height)
        let changed = newAspect != aspect
        aspect = newAspect
        window.contentMinSize = InstanceWindowGeometry.contentSize(displayHeight: InstanceWindowGeometry.minDisplayHeight, aspect: aspect)
        guard !sizedOnce || rotated || changed else { return }
        sizedOnce = true
        let visible = window.screen?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let target = rotated
            ? InstanceWindowGeometry.idealContentSize(aspect: aspect, visible: visible)
            : InstanceWindowGeometry.constrain(proposed: window.contentLayoutRect.size, current: window.contentLayoutRect.size, aspect: aspect)
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: target))
        var origin = window.frame.origin
        origin.y += window.frame.height - frame.height   // keep the title bar where it was
        window.setFrame(NSRect(origin: origin, size: frame.size), display: true, animate: false)
    }

    // MARK: NSWindowDelegate

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let proposed = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        let current = sender.contentLayoutRect.size
        let content = InstanceWindowGeometry.constrain(proposed: proposed, current: current, aspect: aspect)
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: content)).size
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model?.activeInstanceID = id
    }

    func windowWillClose(_ notification: Notification) {
        guard let window else { return }
        // Tear the SwiftUI tree down now (it holds the display view and observes the session).
        window.titlebarAccessoryViewControllers.indices.reversed().forEach { window.removeTitlebarAccessoryViewController(at: $0) }
        window.contentView = nil
        window.delegate = nil
        model?.windowControllerClosed(id)
    }
}

/// Title bar badge: the adb serial, click to copy.
struct SerialBadge: View {
    let id: InstanceID
    @Environment(AppModel.self) private var model
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        let serial = model.session(for: id)?.client?.serial.rawValue
        Button {
            guard let serial else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(serial, forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        } label: {
            HStack(spacing: 4) {
                Text(copied ? "Copied" : (serial ?? "no adb"))
                    .font(.system(size: 11, design: .monospaced))
                StripIcon(name: "copy", fallback: "doc.on.doc", size: 11)
                    .opacity(serial == nil ? 0 : (hovering ? 1 : 0.6))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.primary.opacity(hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .disabled(serial == nil)
        .help(serial.map { "adb serial — click to copy. Use: adb -s \($0) shell" } ?? "No adb connection yet")
        .accessibilityLabel(serial.map { "Copy adb serial \($0)" } ?? "No adb serial")
        .padding(.trailing, 8)
        .frame(height: 28)
    }
}
