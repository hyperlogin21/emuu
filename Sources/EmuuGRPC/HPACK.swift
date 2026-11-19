import Foundation

/// One HTTP/2 header field.
public struct HeaderField: Sendable, Hashable, CustomStringConvertible {
    public var name: String
    public var value: String
    /// Encode as "never indexed" (credentials).
    public var sensitive: Bool

    public init(_ name: String, _ value: String, sensitive: Bool = false) {
        self.name = name
        self.value = value
        self.sensitive = sensitive
    }

    /// Never prints the value of a sensitive field (authorization tokens).
    public var description: String { sensitive ? "\(name): <redacted>" : "\(name): \(value)" }
}

public enum HPACKError: Error, Equatable, Sendable {
    case truncated
    case integerOverflow
    case invalidIndex(Int)
    case invalidHuffman
    case tableSizeTooLarge(Int)
}

/// RFC 7541 static table (index 1…61).
enum HPACKStaticTable {
    static let entries: [(String, String)] = [
        (":authority", ""), (":method", "GET"), (":method", "POST"), (":path", "/"), (":path", "/index.html"),
        (":scheme", "http"), (":scheme", "https"), (":status", "200"), (":status", "204"), (":status", "206"),
        (":status", "304"), (":status", "400"), (":status", "404"), (":status", "500"), ("accept-charset", ""),
        ("accept-encoding", "gzip, deflate"), ("accept-language", ""), ("accept-ranges", ""), ("accept", ""),
        ("access-control-allow-origin", ""), ("age", ""), ("allow", ""), ("authorization", ""),
        ("cache-control", ""), ("content-disposition", ""), ("content-encoding", ""), ("content-language", ""),
        ("content-length", ""), ("content-location", ""), ("content-range", ""), ("content-type", ""),
        ("cookie", ""), ("date", ""), ("etag", ""), ("expect", ""), ("expires", ""), ("from", ""), ("host", ""),
        ("if-match", ""), ("if-modified-since", ""), ("if-none-match", ""), ("if-range", ""),
        ("if-unmodified-since", ""), ("last-modified", ""), ("link", ""), ("location", ""), ("max-forwards", ""),
        ("proxy-authenticate", ""), ("proxy-authorization", ""), ("range", ""), ("referer", ""), ("refresh", ""),
        ("retry-after", ""), ("server", ""), ("set-cookie", ""), ("strict-transport-security", ""),
        ("transfer-encoding", ""), ("user-agent", ""), ("vary", ""), ("via", ""), ("www-authenticate", ""),
    ]
}

/// HPACK primitives shared by the encoder and decoder.
enum HPACKPrimitive {
    static func encodeInteger(_ value: Int, prefixBits: Int, firstByte: UInt8, into out: inout [UInt8]) {
        let max = (1 << prefixBits) - 1
        if value < max {
            out.append(firstByte | UInt8(value))
            return
        }
        out.append(firstByte | UInt8(max))
        var rest = value - max
        while rest >= 128 {
            out.append(UInt8(rest & 0x7f) | 0x80)
            rest >>= 7
        }
        out.append(UInt8(rest))
    }

    static func decodeInteger(_ bytes: [UInt8], _ pos: inout Int, prefixBits: Int) throws -> Int {
        guard pos < bytes.count else { throw HPACKError.truncated }
        let max = (1 << prefixBits) - 1
        var value = Int(bytes[pos] & UInt8(max))
        pos += 1
        guard value == max else { return value }
        var shift = 0
        while true {
            guard pos < bytes.count else { throw HPACKError.truncated }
            let b = bytes[pos]
            pos += 1
            guard shift <= 28 else { throw HPACKError.integerOverflow }
            value += Int(b & 0x7f) << shift
            shift += 7
            if b & 0x80 == 0 { return value }
        }
    }

    /// Literal string, no Huffman (always valid; requests are a few hundred bytes).
    static func encodeString(_ s: String, into out: inout [UInt8]) {
        let utf8 = Array(s.utf8)
        encodeInteger(utf8.count, prefixBits: 7, firstByte: 0, into: &out)
        out += utf8
    }

    static func decodeString(_ bytes: [UInt8], _ pos: inout Int) throws -> String {
        guard pos < bytes.count else { throw HPACKError.truncated }
        let huffman = bytes[pos] & 0x80 != 0
        let length = try decodeInteger(bytes, &pos, prefixBits: 7)
        guard length <= bytes.count - pos else { throw HPACKError.truncated }
        let slice = bytes[pos..<(pos + length)]
        pos += length
        if huffman {
            return String(decoding: try HPACKHuffman.decode(slice), as: UTF8.self)
        }
        return String(decoding: slice, as: UTF8.self)
    }
}

/// Canonical-Huffman decoder for the HPACK code (RFC 7541 §5.2).
enum HPACKHuffman {
    /// (length, code) → symbol, built once.
    private static let lookup: [UInt64: UInt16] = {
        var map: [UInt64: UInt16] = [:]
        for sym in 0..<256 {
            map[(UInt64(HPACKHuffmanTable.lengths[sym]) << 32) | UInt64(HPACKHuffmanTable.codes[sym])] = UInt16(sym)
        }
        return map
    }()

    static func decode<C: Collection>(_ input: C) throws -> [UInt8] where C.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(input.count * 8 / 5)
        var code: UInt64 = 0
        var length = 0
        for byte in input {
            for bit in stride(from: 7, through: 0, by: -1) {
                code = (code << 1) | UInt64((byte >> UInt8(bit)) & 1)
                length += 1
                if length >= 5, let sym = lookup[(UInt64(length) << 32) | code] {
                    out.append(UInt8(sym))
                    code = 0
                    length = 0
                } else if length > 30 {
                    throw HPACKError.invalidHuffman
                }
            }
        }
        // Padding: at most 7 bits, all ones (most significant bits of EOS).
        if length > 7 || code != (UInt64(1) << UInt64(length)) - 1 { throw HPACKError.invalidHuffman }
        return out
    }

    /// Encoder (tests only; the client sends plain literals).
    static func encode(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var acc: UInt64 = 0
        var bits = 0
        for b in input {
            acc = (acc << UInt64(HPACKHuffmanTable.lengths[Int(b)])) | UInt64(HPACKHuffmanTable.codes[Int(b)])
            bits += Int(HPACKHuffmanTable.lengths[Int(b)])
            while bits >= 8 {
                bits -= 8
                out.append(UInt8((acc >> UInt64(bits)) & 0xff))
            }
        }
        if bits > 0 {
            let pad = 8 - bits
            out.append(UInt8(((acc << UInt64(pad)) | ((1 << UInt64(pad)) - 1)) & 0xff))
        }
        return out
    }
}

/// Stateless HPACK encoder: every field is a literal *without indexing* (never indexed for sensitive
/// fields), names from the static table when they exist. It never adds to the peer's dynamic table, so no
/// encoder state has to be kept in sync with the server.
public struct HPACKEncoder: Sendable {
    public init() {}

    public func encode(_ fields: [HeaderField]) -> [UInt8] {
        var out: [UInt8] = []
        for f in fields {
            if !f.sensitive, let full = HPACKStaticTable.entries.firstIndex(where: { $0.0 == f.name && $0.1 == f.value }) {
                HPACKPrimitive.encodeInteger(full + 1, prefixBits: 7, firstByte: 0x80, into: &out)
                continue
            }
            let first: UInt8 = f.sensitive ? 0x10 : 0x00
            if let nameIndex = HPACKStaticTable.entries.firstIndex(where: { $0.0 == f.name }) {
                HPACKPrimitive.encodeInteger(nameIndex + 1, prefixBits: 4, firstByte: first, into: &out)
            } else {
                out.append(first)
                HPACKPrimitive.encodeString(f.name, into: &out)
            }
            HPACKPrimitive.encodeString(f.value, into: &out)
        }
        return out
    }
}

/// HPACK decoder with a dynamic table (RFC 7541). One per connection; not thread-safe (the connection's
/// reader thread owns it).
public struct HPACKDecoder: Sendable {
    private var dynamic: [(String, String)] = []   // newest first
    private var dynamicSize = 0
    /// The limit we advertised (SETTINGS_HEADER_TABLE_SIZE, default 4096).
    public var maxAllowedTableSize: Int
    private var maxTableSize: Int

    public init(maxTableSize: Int = 4096) {
        self.maxAllowedTableSize = maxTableSize
        self.maxTableSize = maxTableSize
    }

    public var dynamicTableCount: Int { dynamic.count }

    public mutating func decode(_ bytes: [UInt8]) throws -> [HeaderField] {
        var fields: [HeaderField] = []
        var pos = 0
        while pos < bytes.count {
            let b = bytes[pos]
            if b & 0x80 != 0 {
                let index = try HPACKPrimitive.decodeInteger(bytes, &pos, prefixBits: 7)
                let (n, v) = try entry(index)
                fields.append(HeaderField(n, v))
            } else if b & 0x40 != 0 {
                let (n, v) = try literal(bytes, &pos, prefixBits: 6)
                fields.append(HeaderField(n, v))
                add(n, v)
            } else if b & 0x20 != 0 {
                let size = try HPACKPrimitive.decodeInteger(bytes, &pos, prefixBits: 5)
                guard size <= maxAllowedTableSize else { throw HPACKError.tableSizeTooLarge(size) }
                maxTableSize = size
                evict()
            } else {
                // 0000xxxx without indexing, 0001xxxx never indexed.
                let never = b & 0x10 != 0
                let (n, v) = try literal(bytes, &pos, prefixBits: 4)
                fields.append(HeaderField(n, v, sensitive: never))
            }
        }
        return fields
    }

    private func entry(_ index: Int) throws -> (String, String) {
        guard index > 0 else { throw HPACKError.invalidIndex(index) }
        if index <= HPACKStaticTable.entries.count { return HPACKStaticTable.entries[index - 1] }
        let d = index - HPACKStaticTable.entries.count - 1
        guard d < dynamic.count else { throw HPACKError.invalidIndex(index) }
        return dynamic[d]
    }

    private func literal(_ bytes: [UInt8], _ pos: inout Int, prefixBits: Int) throws -> (String, String) {
        let nameIndex = try HPACKPrimitive.decodeInteger(bytes, &pos, prefixBits: prefixBits)
        let name = nameIndex == 0 ? try HPACKPrimitive.decodeString(bytes, &pos) : try entry(nameIndex).0
        let value = try HPACKPrimitive.decodeString(bytes, &pos)
        return (name, value)
    }

    private mutating func add(_ name: String, _ value: String) {
        let size = name.utf8.count + value.utf8.count + 32
        if size > maxTableSize {
            dynamic.removeAll()
            dynamicSize = 0
            return
        }
        dynamic.insert((name, value), at: 0)
        dynamicSize += size
        evict()
    }

    private mutating func evict() {
        while dynamicSize > maxTableSize, let last = dynamic.popLast() {
            dynamicSize -= last.0.utf8.count + last.1.utf8.count + 32
        }
    }
}
