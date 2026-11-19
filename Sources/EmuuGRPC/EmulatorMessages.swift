import Foundation

// Hand-written encoders/decoders for the subset of `emulator_controller.proto` (Android Emulator 36.4.9,
// `$ANDROID_SDK_ROOT/emulator/lib/emulator_controller.proto`) that Emuu uses. Field numbers are copied from
// that file; keep them in sync if the proto changes.

/// `Rotation.SkinRotation`: the coarse device orientation derived from the emulated sensors.
public enum SkinRotation: Int, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case portrait = 0           // 0°
    case landscape = 1          // 90° (device turned counter-clockwise; ROTATION_90)
    case reversePortrait = 2    // 180°
    case reverseLandscape = 3   // 270° / -90°

    public var isLandscape: Bool { self == .landscape || self == .reverseLandscape }

    /// The Z-axis angle (degrees) to feed `setPhysicalModel(ROTATION)` for this orientation.
    public var zAngle: Float {
        switch self {
        case .portrait: return 0
        case .landscape: return 90
        case .reversePortrait: return 180
        case .reverseLandscape: return -90
        }
    }

    public var description: String {
        switch self {
        case .portrait: return "portrait"
        case .landscape: return "landscape"
        case .reversePortrait: return "reverse portrait"
        case .reverseLandscape: return "reverse landscape"
        }
    }
}

/// `ImageFormat` (request and the echo in every `Image`).
public struct EmulatorImageFormat: Sendable, Hashable {
    public enum PixelFormat: Int, Sendable { case png = 0, rgba8888 = 1, rgb888 = 2 }

    public var format: PixelFormat = .rgba8888
    public var width: Int = 0
    public var height: Int = 0
    public var display: Int = 0
    /// Shared-memory transport (`ImageTransport.MMAP`): a POSIX shm name, or a `file://` URL.
    /// The emulator writes pixels there instead of the gRPC payload. **Width and height must be set**:
    /// with 0×0 and MMAP, emulator 36.4.9 crashed (observed 2026-11-19).
    public var mmapHandle: String?
    /// Output only.
    public var rotation: SkinRotation = .portrait

    public init(format: PixelFormat = .rgba8888, width: Int = 0, height: Int = 0, display: Int = 0, mmapHandle: String? = nil) {
        self.format = format
        self.width = width
        self.height = height
        self.display = display
        self.mmapHandle = mmapHandle
    }

    public func encoded() -> [UInt8] {
        var w = ProtoWriter()
        w.int(1, format.rawValue)
        w.int(3, width)
        w.int(4, height)
        w.int(5, display)
        if let mmapHandle {
            w.message(6) { t in
                t.int(1, 1)   // MMAP
                t.string(2, mmapHandle)
            }
        }
        return w.bytes
    }

    static func decode(_ data: ArraySlice<UInt8>) throws -> EmulatorImageFormat {
        var f = EmulatorImageFormat()
        try ProtoReader.forEach(data) { field, value in
            switch field {
            case 1: f.format = PixelFormat(rawValue: Int(value.int)) ?? .rgba8888
            case 2:
                try ProtoReader.forEach(value.slice) { rf, rv in
                    if rf == 1 { f.rotation = SkinRotation(rawValue: Int(rv.int)) ?? .portrait }
                }
            case 3: f.width = Int(value.uint)
            case 4: f.height = Int(value.uint)
            case 5: f.display = Int(value.uint)
            default: break
            }
        }
        return f
    }
}

/// `Image`: one frame (pixels inline, or in shared memory with MMAP).
public struct EmulatorImage: Sendable {
    public var format = EmulatorImageFormat()
    /// Inline pixel/PNG bytes (empty with MMAP).
    public var image: ArraySlice<UInt8> = []
    public var seq: UInt32 = 0
    /// Unix µs when the emulator produced the frame.
    public var timestampUs: UInt64 = 0

    public var width: Int { format.width }
    public var height: Int { format.height }
    public var isEmpty: Bool { width == 0 || height == 0 }

    public static func decode(_ data: ArraySlice<UInt8>) throws -> EmulatorImage {
        var img = EmulatorImage()
        var legacyW = 0, legacyH = 0
        try ProtoReader.forEach(data) { field, value in
            switch field {
            case 1: img.format = try EmulatorImageFormat.decode(value.slice)
            case 2: legacyW = Int(value.uint)
            case 3: legacyH = Int(value.uint)
            case 4: img.image = value.slice
            case 5: img.seq = UInt32(truncatingIfNeeded: value.uint)
            case 6: img.timestampUs = value.uint
            default: break
            }
        }
        if img.format.width == 0 { img.format.width = legacyW }
        if img.format.height == 0 { img.format.height = legacyH }
        return img
    }
}

/// `Touch` inside a `TouchEvent`. Coordinates are in the device's *physical* (unrotated) display pixels.
public struct EmulatorTouch: Sendable, Hashable {
    public var x: Int
    public var y: Int
    public var identifier: Int
    /// 0 lifts the finger; > 0 while touching (the emulator's range is 0…0x7fff… we use 1…1024).
    public var pressure: Int
    public var touchMajor: Int

    public init(x: Int, y: Int, identifier: Int, pressure: Int, touchMajor: Int = 0) {
        self.x = x
        self.y = y
        self.identifier = identifier
        self.pressure = pressure
        self.touchMajor = touchMajor
    }

    func encode(into w: inout ProtoWriter) {
        w.int(1, x, always: true)
        w.int(2, y, always: true)
        w.int(3, identifier)
        w.int(4, pressure)
        w.int(5, touchMajor)
        w.int(7, 1)   // NEVER_EXPIRE: we always send pressure 0 to lift
    }
}

/// `KeyboardEvent`.
public struct EmulatorKeyEvent: Sendable, Hashable {
    public enum CodeType: Int, Sendable { case usb = 0, evdev = 1, xkb = 2, win = 3, mac = 4 }
    public enum EventType: Int, Sendable { case keydown = 0, keyup = 1, keypress = 2 }

    public var codeType: CodeType = .mac
    public var eventType: EventType = .keypress
    public var keyCode: Int = 0
    /// W3C `KeyboardEvent.key` value ("GoHome", "AudioVolumeUp", "a", …). Takes priority over `keyCode`.
    public var key: String = ""
    /// UTF-8 text typed as key presses (printable ASCII only is reliable).
    public var text: String = ""

    public init(codeType: CodeType = .mac, eventType: EventType = .keypress, keyCode: Int = 0, key: String = "", text: String = "") {
        self.codeType = codeType
        self.eventType = eventType
        self.keyCode = keyCode
        self.key = key
        self.text = text
    }

    public static func key(_ name: String, _ type: EventType = .keypress) -> EmulatorKeyEvent {
        EmulatorKeyEvent(eventType: type, key: name)
    }

    public static func macKey(_ code: UInt16, _ type: EventType) -> EmulatorKeyEvent {
        EmulatorKeyEvent(codeType: .mac, eventType: type, keyCode: Int(code))
    }

    public static func evdev(_ code: Int, _ type: EventType) -> EmulatorKeyEvent {
        EmulatorKeyEvent(codeType: .evdev, eventType: type, keyCode: code)
    }

    func encode(into w: inout ProtoWriter) {
        w.int(1, codeType.rawValue)
        w.int(2, eventType.rawValue)
        w.int(3, keyCode)
        w.string(4, key)
        w.string(5, text)
    }
}

/// One `InputEvent` for `streamInputEvent` (also usable with the unary send* calls).
public enum EmulatorInputEvent: Sendable, Hashable {
    case touch([EmulatorTouch], display: Int = 0)
    case key(EmulatorKeyEvent)
    /// `MouseEvent`: buttons bitmask 1 = primary, 2 = secondary.
    case mouse(x: Int, y: Int, buttons: Int, display: Int = 0)
    /// `WheelEvent`: 120 per wheel click.
    case wheel(dx: Int, dy: Int, display: Int = 0)

    public func encoded() -> [UInt8] {
        var w = ProtoWriter()
        switch self {
        case .touch(let touches, let display):
            w.message(2) { e in Self.encodeTouches(touches, display: display, into: &e) }
        case .key(let k):
            w.message(1) { e in k.encode(into: &e) }
        case .mouse(let x, let y, let buttons, let display):
            w.message(3) { e in
                e.int(1, x, always: true)
                e.int(2, y, always: true)
                e.int(3, buttons)
                e.int(4, display)
            }
        case .wheel(let dx, let dy, let display):
            w.message(6) { e in
                e.int(1, dx)
                e.int(2, dy)
                e.int(3, display)
            }
        }
        return w.bytes
    }

    static func encodeTouches(_ touches: [EmulatorTouch], display: Int, into e: inout ProtoWriter) {
        for t in touches { e.message(1) { m in t.encode(into: &m) } }
        e.int(2, display)
    }
}

/// `EmulatorStatus` (the fields Emuu reads).
public struct EmulatorStatus: Sendable {
    public var version = ""
    public var uptimeMs: UInt64 = 0
    public var booted = false
    public var heartbeat: UInt64 = 0
    /// `hardwareConfig` entries (hw.lcd.width, hw.lcd.height, …).
    public var hardwareConfig: [String: String] = [:]

    /// Physical (portrait, unrotated) display size from `hw.lcd.width`/`hw.lcd.height`.
    public var lcdSize: (width: Int, height: Int)? {
        guard let w = hardwareConfig["hw.lcd.width"].flatMap({ Int($0) }),
              let h = hardwareConfig["hw.lcd.height"].flatMap({ Int($0) }), w > 0, h > 0 else { return nil }
        return (w, h)
    }

    public static func decode(_ data: ArraySlice<UInt8>) throws -> EmulatorStatus {
        var s = EmulatorStatus()
        try ProtoReader.forEach(data) { f, v in
            switch f {
            case 1: s.version = v.string
            case 2: s.uptimeMs = v.uint
            case 3: s.booted = v.uint != 0
            case 5:
                try ProtoReader.forEach(v.slice) { ef, ev in
                    guard ef == 1 else { return }
                    var key = "", value = ""
                    try ProtoReader.forEach(ev.slice) { kf, kv in
                        if kf == 1 { key = kv.string } else if kf == 2 { value = kv.string }
                    }
                    s.hardwareConfig[key] = value
                }
            case 6: s.heartbeat = v.uint
            default: break
            }
        }
        return s
    }
}

/// `PhysicalModelValue` for `ROTATION` (target 1): angles in degrees [x, y, z].
public struct EmulatorRotationValue: Sendable, Hashable {
    public var x: Float = 0
    public var y: Float = 0
    public var z: Float = 0

    public init(x: Float = 0, y: Float = 0, z: Float = 0) {
        self.x = x
        self.y = y
        self.z = z
    }

    public func encoded() -> [UInt8] {
        var w = ProtoWriter()
        w.int(1, 1)   // ROTATION
        w.message(3) { p in p.packedFloats(1, [x, y, z]) }
        return w.bytes
    }

    public static func decode(_ data: ArraySlice<UInt8>) throws -> EmulatorRotationValue {
        var r = EmulatorRotationValue()
        try ProtoReader.forEach(data) { f, v in
            guard f == 3 else { return }
            var values: [Float] = []
            try ProtoReader.forEach(v.slice) { pf, pv in if pf == 1 { values += ProtoReader.floats(pv) } }
            if values.count >= 3 { r = EmulatorRotationValue(x: values[0], y: values[1], z: values[2]) }
        }
        return r
    }
}

/// `ClipData`.
enum EmulatorClipData {
    static func encode(_ text: String) -> [UInt8] {
        var w = ProtoWriter()
        w.string(1, text)
        return w.bytes
    }

    static func decode(_ data: ArraySlice<UInt8>) throws -> String {
        var text = ""
        try ProtoReader.forEach(data) { f, v in if f == 1 { text = v.string } }
        return text
    }
}

/// `PhysicalModelValue` for any target (`PhysicalType`: POSITION = 0 in metres, ROTATION = 1 in degrees, …).
/// The virtual scene camera follows the device's POSITION and ROTATION (verified on 36.4.9; see
/// docs/engine-findings.md, "Camera").
public struct EmulatorPhysicalValue: Sendable, Hashable {
    public static let position = 0
    public static let rotation = 1

    public var target: Int
    public var values: [Float]

    public init(target: Int, values: [Float]) {
        self.target = target
        self.values = values
    }

    public func encoded() -> [UInt8] {
        var w = ProtoWriter()
        if target != 0 { w.int(1, Int64(target)) }
        let v = values
        w.message(3) { p in p.packedFloats(1, v) }
        return w.bytes
    }

    /// Request for `getPhysicalModel`: only the target.
    public static func query(_ target: Int) -> [UInt8] {
        var w = ProtoWriter()
        if target != 0 { w.int(1, Int64(target)) }
        return w.bytes
    }

    public static func decode(_ data: ArraySlice<UInt8>, target: Int) throws -> EmulatorPhysicalValue {
        var values: [Float] = []
        try ProtoReader.forEach(data) { f, v in
            guard f == 3 else { return }
            try ProtoReader.forEach(v.slice) { pf, pv in if pf == 1 { values += ProtoReader.floats(pv) } }
        }
        return EmulatorPhysicalValue(target: target, values: values)
    }
}
