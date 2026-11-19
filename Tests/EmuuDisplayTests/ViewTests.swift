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

    @Test func keyEventsAreTranslated() throws {
        let (view, captured, window) = makeView()
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                    context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: UInt16(kVK_ANSI_W))!
        let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                  context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: UInt16(kVK_ANSI_W))!
        view.keyDown(with: down)
        view.keyUp(with: up)
        #expect(captured.events.current == [.key(.macKey(UInt16(kVK_ANSI_W), .keydown)), .key(.macKey(UInt16(kVK_ANSI_W), .keyup))])
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
        #expect(pressed == [.back, .home, .volumeUp])
        #expect(rotated == 1)
        #expect(captured.events.current.isEmpty)
    }
}
