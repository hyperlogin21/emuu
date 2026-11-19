import Testing
import Foundation
import AppKit
import Carbon.HIToolbox
import EmuuGRPC
@testable import EmuuDisplay

private func touches(_ e: EmulatorInputEvent) -> [EmulatorTouch] {
    if case .touch(let t, _) = e { return t }
    return []
}

@Suite struct DeviceTouchMapperTests {
    let phone = VideoSize(width: 720, height: 1600)

    @Test func portraitIsIdentity() {
        let m = DeviceTouchMapper(physical: phone, rotation: .portrait)
        #expect(m.frameSize == phone)
        #expect(m.physicalPoint(frameX: 100, frameY: 600) == (100, 600))
    }

    /// Measured on engine 36.4.9 (pointer_location, ROTATION_90): physical (100, 600) shows at frame (600, 619).
    @Test func landscapeMatchesTheEngine() {
        let m = DeviceTouchMapper(physical: phone, rotation: .landscape)
        #expect(m.frameSize == VideoSize(width: 1600, height: 720))
        let p = m.physicalPoint(frameX: 600, frameY: 619)
        #expect(p.x == 100 && p.y == 600)
    }

    @Test func otherRotationsAreBijective() {
        for r in SkinRotation.allCases {
            let m = DeviceTouchMapper(physical: phone, rotation: r)
            var seen = Set<Int>()
            for fx in stride(from: 0, to: m.frameSize.width, by: 97) {
                for fy in stride(from: 0, to: m.frameSize.height, by: 89) {
                    let p = m.physicalPoint(frameX: fx, frameY: fy)
                    #expect((0..<720).contains(p.x) && (0..<1600).contains(p.y))
                    seen.insert(p.x * 10_000 + p.y)
                }
            }
            #expect(seen.count == ((m.frameSize.width + 96) / 97) * ((m.frameSize.height + 88) / 89))
        }
        // Corners map to corners.
        #expect(DeviceTouchMapper(physical: phone, rotation: .reversePortrait).physicalPoint(frameX: 0, frameY: 0) == (719, 1599))
        #expect(DeviceTouchMapper(physical: phone, rotation: .reverseLandscape).physicalPoint(frameX: 0, frameY: 0) == (0, 1599))
        #expect(DeviceTouchMapper(physical: phone, rotation: .landscape).physicalPoint(frameX: 0, frameY: 0) == (719, 0))
    }
}

@Suite struct PointerTranslatorTests {
    func translator(rotation: SkinRotation = .portrait) -> PointerInputTranslator {
        let frame = rotation.isLandscape ? VideoSize(width: 1600, height: 720) : VideoSize(width: 720, height: 1600)
        let view = rotation.isLandscape ? CGSize(width: 800, height: 360) : CGSize(width: 360, height: 800)
        return PointerInputTranslator(mapper: AspectFitMapper(viewSize: view, videoSize: frame),
                                      device: DeviceTouchMapper(physical: VideoSize(width: 720, height: 1600), rotation: rotation))
    }

    @Test func clickIsOneFingerDownAndUp() {
        var t = translator()
        let down = t.mouseDown(.left, at: CGPoint(x: 90, y: 200), pressure: 1)
        let up = t.mouseUp(.left, at: CGPoint(x: 90, y: 200))
        #expect(touches(down[0]) == [EmulatorTouch(x: 180, y: 400, identifier: 0, pressure: 1024, touchMajor: 8)])
        #expect(touches(up[0]) == [EmulatorTouch(x: 180, y: 400, identifier: 0, pressure: 0, touchMajor: 0)])
        #expect(!t.isTouching)
    }

    @Test func landscapeClickUsesPhysicalCoordinates() {
        var t = translator(rotation: .landscape)
        // View (300, 309.5) → frame (600, 619) → physical (100, 600).
        let down = t.mouseDown(.left, at: CGPoint(x: 300, y: 309.6), pressure: 1)
        let p = touches(down[0])[0]
        #expect(p.x == 100 && p.y == 600)
    }

    @Test func outsideThePictureIsIgnoredAndDragsAreClamped() {
        var t = translator()
        t.mapper = AspectFitMapper(viewSize: CGSize(width: 500, height: 800), videoSize: VideoSize(width: 720, height: 1600))
        #expect(t.mouseDown(.left, at: CGPoint(x: 10, y: 10), pressure: 1).isEmpty)   // letterbox
        _ = t.mouseDown(.left, at: CGPoint(x: 250, y: 400), pressure: 1)
        let drag = t.mouseDragged(.left, to: CGPoint(x: 499, y: 900), pressure: 1)
        let p = touches(drag[0])[0]
        #expect(p.x == 719 && p.y == 1599)
    }

    @Test func buttonsMapToDeviceKeys() {
        var t = translator()
        #expect(t.mouseDown(.right, at: .zero, pressure: 1) == [.key(.key("GoBack", .keydown))])
        #expect(t.mouseUp(.right, at: .zero) == [.key(.key("GoBack", .keyup))])
        #expect(t.mouseDown(.middle, at: .zero, pressure: 1) == [.key(.key("GoHome", .keydown))])
        #expect(t.mouseDown(.back, at: .zero, pressure: 1) == [.key(.key("AppSwitch", .keydown))])
    }

    @Test func pinchIsTwoRealFingersAndEndsLifted() {
        var t = translator()
        let begin = t.beginPinch(at: CGPoint(x: 180, y: 400))
        #expect(touches(begin[0]).map(\.identifier) == [1, 2])
        let wider = t.updatePinch(delta: 0.5)
        let a0 = touches(begin[0]), a1 = touches(wider[0])
        #expect(abs(a1[1].x - a1[0].x) > abs(a0[1].x - a0[0].x))
        let end = t.endPinch()
        #expect(touches(end[0]).allSatisfy { $0.pressure == 0 })
        #expect(t.cancelAll().isEmpty)
    }

    @Test func trackpadScrollAccumulatesIntoWheelSteps() {
        var t = translator()
        var events: [EmulatorInputEvent] = []
        for _ in 0..<10 { events += t.scroll(at: CGPoint(x: 100, y: 100), deltaX: 0, deltaY: 1, precise: true) }
        // 10 points = one notch = 120.
        let total = events.reduce(0) { acc, e in if case .wheel(_, let dy, _) = e { return acc + dy } else { return acc } }
        #expect(total == 120)
        #expect(t.scroll(at: CGPoint(x: 100, y: 100), deltaX: 0, deltaY: -3, precise: false) == [.wheel(dx: 0, dy: -360)])
    }

    @Test func pressureScale() {
        #expect(PointerInputTranslator.pressure(1) == 1024)
        #expect(PointerInputTranslator.pressure(0) == 1024)          // mouse without pressure
        #expect(PointerInputTranslator.pressure(0.01) == 51)         // floor 0.05
    }
}

@Suite struct KeyTranslatorTests {
    func ev(_ kind: HostKeyEvent.Kind, _ code: Int, _ chars: String?, _ mods: NSEvent.ModifierFlags = [], repeat r: Bool = false) -> HostKeyEvent {
        HostKeyEvent(kind: kind, keyCode: UInt16(code), characters: chars, modifiers: mods, isRepeat: r)
    }

    @Test func lettersArePhysicalKeysWithDownAndUp() {
        var t = KeyEventTranslator()
        #expect(t.translate(ev(.down, kVK_ANSI_W, "w")) == [.key(.macKey(UInt16(kVK_ANSI_W), .keydown))])
        #expect(t.pressedKeyCount == 1)
        #expect(t.translate(ev(.up, kVK_ANSI_W, "w")) == [.key(.macKey(UInt16(kVK_ANSI_W), .keyup))])
        #expect(t.translate(ev(.up, kVK_ANSI_W, "w")).isEmpty)   // no stray UP
    }

    @Test func nonPrintableKeysArePhysical() {
        var t = KeyEventTranslator()
        for code in [kVK_Return, kVK_Delete, kVK_Escape, kVK_LeftArrow, kVK_F5, kVK_Tab] {
            #expect(t.translate(ev(.down, code, "\u{F702}")) == [.key(.macKey(UInt16(code), .keydown))])
        }
    }

    @Test func layoutDependentCharacters() {
        var t = KeyEventTranslator()
        // US layout: physical key.
        #expect(t.translate(ev(.down, kVK_ANSI_1, "1")) == [.key(.macKey(UInt16(kVK_ANSI_1), .keydown))])
        #expect(t.translate(ev(.down, kVK_ANSI_1, "!", [.shift])) == [.key(.macKey(UInt16(kVK_ANSI_1), .keydown))])
        // A layout where that key yields another character (French AZERTY "&"): the character itself.
        #expect(t.translate(ev(.down, kVK_ANSI_1, "&")) == [.key(.key("&", .keypress))])
    }

    @Test func composedAndNonASCIIBecomeText() {
        var t = KeyEventTranslator()
        #expect(t.translate(ev(.down, kVK_ANSI_A, "å", [.option])) == [.key(EmulatorKeyEvent(text: "å"))])
        #expect(t.pressedKeyCount == 0)
    }

    @Test func controlChordsStayPhysical() {
        var t = KeyEventTranslator()
        #expect(t.translate(ev(.down, kVK_ANSI_C, "\u{3}", [.control])) == [.key(.macKey(UInt16(kVK_ANSI_C), .keydown))])
    }

    @Test func modifiersAndReleaseAll() {
        var t = KeyEventTranslator()
        #expect(t.modifierChanged(keyCode: UInt16(kVK_Shift), flags: [.shift]) == [.key(.macKey(UInt16(kVK_Shift), .keydown))])
        #expect(t.modifierChanged(keyCode: UInt16(kVK_Shift), flags: [.shift]).isEmpty)
        _ = t.translate(ev(.down, kVK_ANSI_A, "A", [.shift]))
        #expect(t.modifierChanged(keyCode: UInt16(kVK_Command), flags: [.command]).isEmpty)   // ⌘ stays on the host
        let ups = t.releaseAll()
        #expect(Set(ups) == [.key(.macKey(UInt16(kVK_Shift), .keyup)), .key(.macKey(UInt16(kVK_ANSI_A), .keyup))])
        #expect(t.pressedKeyCount == 0)
    }
}
