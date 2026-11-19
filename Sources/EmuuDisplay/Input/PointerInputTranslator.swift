import Foundation
import CoreGraphics
import EmuuGRPC

/// Host mouse buttons as seen by the display view.
public enum HostMouseButton: Int, Sendable, Hashable {
    case left = 0, right = 1, middle = 2, back = 3, forward = 4
}

/// Maps a pixel of the delivered (already rotated) frame to the engine's touch coordinate space, which is
/// the **physical, unrotated** panel (e.g. 720x1600 for a phone even while it is held in landscape).
///
/// Verified on engine 36.4.9 with `pointer_location` in landscape (ROTATION_90, frame 1600x720): a touch at
/// physical (100, 600) appeared at frame pixel (600, 620) = (y, W − x).
public struct DeviceTouchMapper: Sendable, Hashable {
    /// Physical panel size (portrait for phones).
    public var physical: VideoSize
    public var rotation: SkinRotation

    public init(physical: VideoSize, rotation: SkinRotation) {
        self.physical = physical
        self.rotation = rotation
    }

    /// Frame size this mapping expects (physical size, swapped in landscape).
    public var frameSize: VideoSize { rotation.isLandscape ? physical.swapped : physical }

    public func physicalPoint(frameX x: Int, frameY y: Int) -> (x: Int, y: Int) {
        let W = physical.width, H = physical.height
        let p: (Int, Int)
        switch rotation {
        case .portrait: p = (x, y)
        case .landscape: p = (W - 1 - y, x)
        case .reversePortrait: p = (W - 1 - x, H - 1 - y)
        case .reverseLandscape: p = (y, H - 1 - x)
        }
        return (min(max(p.0, 0), max(W - 1, 0)), min(max(p.1, 0), max(H - 1, 0)))
    }
}

/// Converts host pointer input to engine input events:
/// - left button → a finger (touch slot 0) with the trackpad's force as pressure;
/// - right button → BACK; middle → HOME; button 4 → recent apps;
/// - scroll wheel / two-finger scroll → wheel events (120 per notch);
/// - trackpad pinch (magnify) → two real fingers (slots 1 and 2) around the cursor.
public struct PointerInputTranslator: Sendable {
    public var mapper: AspectFitMapper
    public var device: DeviceTouchMapper
    private var leftDown = false
    private var lastPoint: (x: Int, y: Int) = (0, 0)
    private var pinch: Pinch?
    /// Fractional wheel deltas carried between events (trackpads send many small deltas).
    private var wheelCarry: (x: Double, y: Double) = (0, 0)

    static let fingerID = 0
    static let pinchIDs = (1, 2)

    private struct Pinch: Sendable {
        var centerX: Int
        var centerY: Int
        var baseOffset: Double
        var magnification: Double
    }

    public init(mapper: AspectFitMapper, device: DeviceTouchMapper) {
        self.mapper = mapper
        self.device = device
    }

    public var isTouching: Bool { leftDown || pinch != nil }

    // MARK: Buttons

    public mutating func mouseDown(_ button: HostMouseButton, at point: CGPoint, pressure: Float) -> [EmulatorInputEvent] {
        switch button {
        case .left:
            guard !mapper.videoSize.isEmpty, let p = mapper.videoPoint(fromView: point) else { return [] }
            leftDown = true
            lastPoint = p
            return [touch([(Self.fingerID, p, Self.pressure(pressure))])]
        case .right: return [.key(.key(DeviceKey.back.w3cKey, .keydown))]
        case .middle: return [.key(.key(DeviceKey.home.w3cKey, .keydown))]
        case .back: return [.key(.key(DeviceKey.appSwitch.w3cKey, .keydown))]
        case .forward: return []
        }
    }

    public mutating func mouseDragged(_ button: HostMouseButton, to point: CGPoint, pressure: Float) -> [EmulatorInputEvent] {
        guard button == .left, leftDown, let p = mapper.videoPoint(fromView: point, clamp: true) else { return [] }
        lastPoint = p
        return [touch([(Self.fingerID, p, Self.pressure(pressure))])]
    }

    public mutating func mouseUp(_ button: HostMouseButton, at point: CGPoint) -> [EmulatorInputEvent] {
        switch button {
        case .left:
            guard leftDown else { return [] }
            leftDown = false
            let p = mapper.videoPoint(fromView: point, clamp: true) ?? lastPoint
            return [touch([(Self.fingerID, p, 0)])]
        case .right: return [.key(.key(DeviceKey.back.w3cKey, .keyup))]
        case .middle: return [.key(.key(DeviceKey.home.w3cKey, .keyup))]
        case .back: return [.key(.key(DeviceKey.appSwitch.w3cKey, .keyup))]
        case .forward: return []
        }
    }

    /// Lifts every finger (focus lost, rotation, session restart).
    public mutating func cancelAll() -> [EmulatorInputEvent] {
        var out: [EmulatorInputEvent] = []
        if leftDown {
            leftDown = false
            out.append(touch([(Self.fingerID, lastPoint, 0)]))
        }
        out += endPinch()
        return out
    }

    // MARK: Scroll

    /// `deltaX`/`deltaY` are `NSEvent.scrollingDeltaX/Y` (positive Y = content moves down = wheel away from
    /// the user). Precise (trackpad) deltas are in points: ~10 points per notch.
    public mutating func scroll(at point: CGPoint, deltaX: CGFloat, deltaY: CGFloat, precise: Bool) -> [EmulatorInputEvent] {
        guard mapper.videoPoint(fromView: point) != nil else { return [] }
        let perNotch: Double = precise ? 10 : 1
        wheelCarry.x += Double(-deltaX) / perNotch * 120
        wheelCarry.y += Double(deltaY) / perNotch * 120
        let dx = Int(wheelCarry.x / 30) * 30, dy = Int(wheelCarry.y / 30) * 30   // send in quarter notches
        guard dx != 0 || dy != 0 else { return [] }
        wheelCarry.x -= Double(dx)
        wheelCarry.y -= Double(dy)
        return [.wheel(dx: max(-1200, min(1200, dx)), dy: max(-1200, min(1200, dy)))]
    }

    // MARK: Pinch (trackpad magnify gesture)

    public mutating func beginPinch(at point: CGPoint) -> [EmulatorInputEvent] {
        guard pinch == nil, !leftDown, let c = mapper.videoPoint(fromView: point) else { return [] }
        let base = Double(min(mapper.videoSize.width, mapper.videoSize.height)) * 0.08
        let state = Pinch(centerX: c.x, centerY: c.y, baseOffset: max(base, 8), magnification: 0)
        pinch = state
        let (a, b) = fingers(state)
        return [touch([(Self.pinchIDs.0, a, 512), (Self.pinchIDs.1, b, 512)])]
    }

    /// `delta` is `NSEvent.magnification` (incremental).
    public mutating func updatePinch(delta: CGFloat) -> [EmulatorInputEvent] {
        guard var state = pinch else { return [] }
        state.magnification = max(-0.9, min(8, state.magnification + Double(delta)))
        pinch = state
        let (a, b) = fingers(state)
        return [touch([(Self.pinchIDs.0, a, 512), (Self.pinchIDs.1, b, 512)])]
    }

    public mutating func endPinch() -> [EmulatorInputEvent] {
        guard let state = pinch else { return [] }
        pinch = nil
        let (a, b) = fingers(state)
        return [touch([(Self.pinchIDs.0, a, 0), (Self.pinchIDs.1, b, 0)])]
    }

    private func fingers(_ s: Pinch) -> ((x: Int, y: Int), (x: Int, y: Int)) {
        let d = s.baseOffset * (1 + s.magnification)
        let maxX = mapper.videoSize.width - 1, maxY = mapper.videoSize.height - 1
        func clampX(_ v: Double) -> Int { min(max(Int(v.rounded()), 0), maxX) }
        func clampY(_ v: Double) -> Int { min(max(Int(v.rounded()), 0), maxY) }
        let dx = d * 0.7071, dy = d * 0.7071
        return ((clampX(Double(s.centerX) - dx), clampY(Double(s.centerY) - dy)),
                (clampX(Double(s.centerX) + dx), clampY(Double(s.centerY) + dy)))
    }

    // MARK: Helpers

    /// Touches in frame pixels → one `TouchEvent` in physical coordinates.
    private func touch(_ points: [(id: Int, p: (x: Int, y: Int), pressure: Int)]) -> EmulatorInputEvent {
        .touch(points.map { t in
            let d = device.physicalPoint(frameX: t.p.x, frameY: t.p.y)
            return EmulatorTouch(x: d.x, y: d.y, identifier: t.id, pressure: t.pressure, touchMajor: t.pressure > 0 ? 8 : 0)
        })
    }

    /// Engine pressure scale is 0…1024 (a value of 50 showed as 0.05 in `pointer_location`). Mice report 1.0
    /// while pressed; Force Touch trackpads 0…1 (keep a floor: zero pressure would lift the finger).
    static func pressure(_ p: Float) -> Int {
        guard p.isFinite, p > 0 else { return 1024 }
        return Int(min(1, max(0.05, p)) * 1024)
    }
}
