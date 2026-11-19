import Testing
import Foundation
@testable import EmuuGRPC

private func hex(_ s: String) -> [UInt8] {
    let clean = s.replacingOccurrences(of: " ", with: "")
    var out: [UInt8] = []
    var i = clean.startIndex
    while i < clean.endIndex {
        let j = clean.index(i, offsetBy: 2)
        out.append(UInt8(clean[i..<j], radix: 16)!)
        i = j
    }
    return out
}

@Suite struct HPACKTests {
    @Test func moduleLinks() { #expect(HPACKStaticTable.entries.count == 61) }

    /// RFC 7541 Appendix C.4 (requests with Huffman coding, shared dynamic table).
    @Test func rfcHuffmanRequestSequence() throws {
        var d = HPACKDecoder()
        let r1 = try d.decode(hex("8286 8441 8cf1 e3c2 e5f2 3a6b a0ab 90f4 ff"))
        #expect(r1.map { "\($0.name)=\($0.value)" } == [":method=GET", ":scheme=http", ":path=/", ":authority=www.example.com"])
        let r2 = try d.decode(hex("8286 84be 5886 a8eb 1064 9cbf"))
        #expect(r2.map { "\($0.name)=\($0.value)" } == [":method=GET", ":scheme=http", ":path=/", ":authority=www.example.com", "cache-control=no-cache"])
        let r3 = try d.decode(hex("8287 85bf 4088 25a8 49e9 5ba9 7d7f 8925 a849 e95b b8e8 b4bf"))
        #expect(r3.map { "\($0.name)=\($0.value)" } == [":method=GET", ":scheme=https", ":path=/index.html", ":authority=www.example.com", "custom-key=custom-value"])
        #expect(d.dynamicTableCount == 3)
    }

    /// RFC 7541 C.6.1 (response with Huffman, includes a date and location).
    @Test func rfcHuffmanResponse() throws {
        var d = HPACKDecoder(maxTableSize: 256)
        let fields = try d.decode(hex("4882 6402 5885 aec3 771a 4b61 96d0 7abe 9410 54d4 44a8 2005 9504 0b81 66e0 82a6 2d1b ff6e 919d 29ad 1718 63c7 8f0b 97c8 e9ae 82ae 43d3"))
        #expect(fields.map(\.value) == ["302", "private", "Mon, 21 Oct 2013 20:13:21 GMT", "https://www.example.com"])
    }

    @Test func huffmanRoundTripAllBytes() throws {
        let all = (0...255).map(UInt8.init)
        #expect(try HPACKHuffman.decode(HPACKHuffman.encode(all)) == all)
        #expect(throws: HPACKError.self) { try HPACKHuffman.decode([0xff, 0xff, 0xff, 0xff, 0xff]) }
    }

    @Test func encoderOutputDecodesAndHidesSecrets() throws {
        let fields = [HeaderField(":method", "POST"), HeaderField(":path", "/svc/m"), HeaderField("te", "trailers"),
                      HeaderField("authorization", "Bearer s3cret", sensitive: true)]
        let bytes = HPACKEncoder().encode(fields)
        var d = HPACKDecoder()
        let back = try d.decode(bytes)
        #expect(back.map(\.name) == fields.map(\.name))
        #expect(back.map(\.value) == fields.map(\.value))
        #expect(back[3].sensitive)                       // encoded never-indexed
        #expect(!"\(back[3])".contains("s3cret"))       // and never printed
        #expect(d.dynamicTableCount == 0)               // stateless encoder
    }

    @Test func largeIntegers() throws {
        var out: [UInt8] = []
        HPACKPrimitive.encodeInteger(1337, prefixBits: 5, firstByte: 0, into: &out)
        #expect(out == [31, 154, 10])   // RFC 7541 C.1.2
        var pos = 0
        #expect(try HPACKPrimitive.decodeInteger(out, &pos, prefixBits: 5) == 1337)
    }
}

@Suite struct ProtoTests {
    @Test func imageFormatEncodingMatchesProto() {
        let f = EmulatorImageFormat(format: .rgba8888, width: 720, height: 1600, mmapHandle: "/emuu-1-1")
        var r = ProtoReader(f.encoded())
        var seen: [Int: ProtoValue] = [:]
        while let (field, v) = try! r.next() { seen[field] = v }
        #expect(seen[1]?.int == 1)
        #expect(seen[3]?.int == 720)
        #expect(seen[4]?.int == 1600)
        var t = ProtoReader(seen[6]!.slice)
        #expect(try! t.next()!.value.int == 1)
        #expect(try! t.next()!.value.string == "/emuu-1-1")
    }

    @Test func decodesImageWithRotation() throws {
        var w = ProtoWriter()
        w.message(1) { f in
            f.int(1, 1)
            f.message(2) { r in r.int(1, 1) }
            f.int(3, 1600)
            f.int(4, 720)
        }
        w.int(5, 42)
        w.int(6, Int64(1_795_044_546_420_664))
        let img = try EmulatorImage.decode(w.bytes[...])
        #expect(img.width == 1600 && img.height == 720 && img.seq == 42)
        #expect(img.format.rotation == .landscape)
        #expect(img.timestampUs == 1_795_044_546_420_664)
        #expect(img.image.isEmpty)
    }

    @Test func touchEncodesZeroCoordinates() throws {
        let bytes = EmulatorInputEvent.touch([EmulatorTouch(x: 0, y: 5, identifier: 0, pressure: 0)]).encoded()
        var r = ProtoReader(bytes)
        let (field, v) = try r.next()!
        #expect(field == 2)
        var te = ProtoReader(v.slice)
        let (tf, tv) = try te.next()!
        #expect(tf == 1)
        var fields: [Int: Int64] = [:]
        try ProtoReader.forEach(tv.slice) { f, val in fields[f] = val.int }
        #expect(fields[1] == 0 && fields[2] == 5 && fields[7] == 1)   // x present even when 0, NEVER_EXPIRE
    }

    @Test func rotationRoundTrip() throws {
        let v = EmulatorRotationValue(z: -90)
        var r = ProtoReader(v.encoded())
        _ = try r.next()
        let (f, payload) = try r.next()!
        #expect(f == 3)
        var w = ProtoWriter()
        w.bytes(3, Array(payload.slice))
        #expect(try EmulatorRotationValue.decode(w.bytes[...]).z == -90)
    }

    @Test func discoveryParsing() {
        let v = EmulatorDiscovery.parse("avd.name=x\ngrpc.port=8584\ngrpc.token=abc=def\n")
        let e = EmulatorDiscovery.endpoint(fromDiscovery: v)
        #expect(e?.port == 8584)
        #expect(e?.token == "abc=def")
        #expect(!(e?.description.contains("abc") ?? true))
        #expect(EmulatorDiscovery.endpoint(fromDiscovery: ["avd.name": "x"]) == nil)
    }

    @Test func sharedMemoryRegionIsWritable() throws {
        let region = try SharedMemoryRegion(size: 4096 * 4)
        region.base.storeBytes(of: 0xAB, toByteOffset: 100, as: UInt8.self)
        #expect(region.base.load(fromByteOffset: 100, as: UInt8.self) == 0xAB)
        #expect(region.name.hasPrefix("/emuu-"))
    }
}
