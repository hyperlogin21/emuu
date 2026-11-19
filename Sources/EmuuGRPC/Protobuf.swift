import Foundation

/// Minimal protocol-buffers wire-format writer (proto3) for the handful of messages Emuu sends.
public struct ProtoWriter: Sendable {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    mutating func varint(_ v: UInt64) {
        var v = v
        while v >= 0x80 {
            bytes.append(UInt8(v & 0x7f) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(v))
    }

    mutating func tag(_ field: Int, _ wire: Int) { varint(UInt64(field << 3 | wire)) }

    /// int32/int64/uint/enum/bool. Zero is omitted (proto3 default) unless `always`.
    public mutating func int(_ field: Int, _ value: Int64, always: Bool = false) {
        guard value != 0 || always else { return }
        tag(field, 0)
        varint(UInt64(bitPattern: value))   // negative int32 → 10-byte two's complement, as protobuf does
    }

    public mutating func int(_ field: Int, _ value: Int, always: Bool = false) { int(field, Int64(value), always: always) }

    public mutating func bool(_ field: Int, _ value: Bool) { int(field, value ? 1 : 0) }

    public mutating func bytes(_ field: Int, _ value: [UInt8], always: Bool = false) {
        guard !value.isEmpty || always else { return }
        tag(field, 2)
        varint(UInt64(value.count))
        bytes += value
    }

    public mutating func string(_ field: Int, _ value: String) { bytes(field, Array(value.utf8)) }

    /// Embedded message (written even when empty, so a set-but-empty submessage is distinguishable).
    public mutating func message(_ field: Int, _ build: (inout ProtoWriter) -> Void) {
        var inner = ProtoWriter()
        build(&inner)
        bytes(field, inner.bytes, always: true)
    }

    public mutating func packedFloats(_ field: Int, _ values: [Float]) {
        guard !values.isEmpty else { return }
        var raw: [UInt8] = []
        raw.reserveCapacity(values.count * 4)
        for v in values {
            let b = v.bitPattern.littleEndian
            raw += [UInt8(b & 0xff), UInt8((b >> 8) & 0xff), UInt8((b >> 16) & 0xff), UInt8(b >> 24)]
        }
        bytes(field, raw)
    }
}

public enum ProtoError: Error, Sendable, Equatable {
    case truncated
    case badWireType(Int)
}

/// A decoded field value.
public enum ProtoValue: Sendable {
    case varint(UInt64)
    case fixed64(UInt64)
    case fixed32(UInt32)
    case bytes(ArraySlice<UInt8>)

    public var int: Int64 {
        switch self {
        case .varint(let v), .fixed64(let v): return Int64(bitPattern: v)
        case .fixed32(let v): return Int64(v)
        case .bytes: return 0
        }
    }

    public var uint: UInt64 {
        switch self {
        case .varint(let v), .fixed64(let v): return v
        case .fixed32(let v): return UInt64(v)
        case .bytes: return 0
        }
    }

    public var double: Double {
        if case .fixed64(let v) = self { return Double(bitPattern: v) }
        return 0
    }

    public var slice: ArraySlice<UInt8> {
        if case .bytes(let b) = self { return b }
        return []
    }

    public var string: String { String(decoding: slice, as: UTF8.self) }
}

/// Iterates the fields of one encoded message.
public struct ProtoReader: Sendable {
    private let data: ArraySlice<UInt8>
    private var pos: Int

    public init(_ data: ArraySlice<UInt8>) {
        self.data = data
        self.pos = data.startIndex
    }

    public init(_ data: [UInt8]) { self.init(data[...]) }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard pos < data.endIndex else { throw ProtoError.truncated }
            let b = data[pos]
            pos += 1
            if shift < 64 { result |= UInt64(b & 0x7f) << shift }
            if b & 0x80 == 0 { return result }
            shift += 7
        }
    }

    /// The next (field number, value), or nil at the end.
    public mutating func next() throws -> (field: Int, value: ProtoValue)? {
        guard pos < data.endIndex else { return nil }
        let key = try varint()
        let field = Int(key >> 3)
        switch Int(key & 7) {
        case 0:
            return (field, .varint(try varint()))
        case 1:
            guard data.endIndex - pos >= 8 else { throw ProtoError.truncated }
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(data[pos + i]) << (8 * UInt64(i)) }
            pos += 8
            return (field, .fixed64(v))
        case 2:
            let n = Int(try varint())
            guard n >= 0, data.endIndex - pos >= n else { throw ProtoError.truncated }
            let s = data[pos..<(pos + n)]
            pos += n
            return (field, .bytes(s))
        case 5:
            guard data.endIndex - pos >= 4 else { throw ProtoError.truncated }
            var v: UInt32 = 0
            for i in 0..<4 { v |= UInt32(data[pos + i]) << (8 * UInt32(i)) }
            pos += 4
            return (field, .fixed32(v))
        case let w:
            throw ProtoError.badWireType(w)
        }
    }

    /// Calls `body` for every field.
    public static func forEach(_ data: ArraySlice<UInt8>, _ body: (Int, ProtoValue) throws -> Void) throws {
        var r = ProtoReader(data)
        while let (f, v) = try r.next() { try body(f, v) }
    }

    /// Decodes a packed (or a single unpacked) float field.
    public static func floats(_ value: ProtoValue) -> [Float] {
        switch value {
        case .fixed32(let v): return [Float(bitPattern: v)]
        case .bytes(let b):
            var out: [Float] = []
            var i = b.startIndex
            while i + 4 <= b.endIndex {
                let v = UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
                out.append(Float(bitPattern: v))
                i += 4
            }
            return out
        default: return []
        }
    }
}
