import Foundation
import EmuuBase

/// Facts read from an APK's binary `AndroidManifest.xml` (Android binary XML, "AXML").
public struct APKManifest: Sendable, Hashable {
    public var packageName: String
    public var versionCode: Int64?
    public var versionName: String?
    /// `split="config.arm64_v8a"` for split APKs; nil for a base APK.
    public var splitName: String?
    public var minSdkVersion: Int?
    public var targetSdkVersion: Int?

    public init(packageName: String, versionCode: Int64? = nil, versionName: String? = nil, splitName: String? = nil, minSdkVersion: Int? = nil, targetSdkVersion: Int? = nil) {
        self.packageName = packageName
        self.versionCode = versionCode
        self.versionName = versionName
        self.splitName = splitName
        self.minSdkVersion = minSdkVersion
        self.targetSdkVersion = targetSdkVersion
    }

    /// Parses the binary manifest bytes.
    public static func parse(binaryXML data: Data) throws -> APKManifest {
        try AXMLManifestParser(data: data).parse()
    }
}

/// Minimal Android binary-XML reader: string pool + resource map + start-element chunks.
/// Only the `<manifest>` and `<uses-sdk>` attributes Emuu needs are extracted.
struct AXMLManifestParser {
    private let bytes: [UInt8]

    init(data: Data) { bytes = [UInt8](data) }

    // Chunk types (ResourceTypes.h)
    private static let resStringPoolType: UInt16 = 0x0001
    private static let resXMLType: UInt16 = 0x0003
    private static let resXMLStartElementType: UInt16 = 0x0102
    private static let resXMLResourceMapType: UInt16 = 0x0180
    // Framework attribute ids (android.R.attr)
    private static let attrVersionCode: UInt32 = 0x0101_021B
    private static let attrVersionName: UInt32 = 0x0101_021C
    private static let attrMinSdkVersion: UInt32 = 0x0101_020C
    private static let attrTargetSdkVersion: UInt32 = 0x0101_0270
    // Res_value data types
    private static let typeString: UInt8 = 0x03
    private static let typeIntDec: UInt8 = 0x10
    private static let typeIntHex: UInt8 = 0x11

    private func u16(_ o: Int) throws -> UInt16 {
        guard o >= 0, o + 2 <= bytes.count else { throw EmuuError.parse("AXML truncated at \(o)") }
        return UInt16(bytes[o]) | UInt16(bytes[o + 1]) << 8
    }

    private func u32(_ o: Int) throws -> UInt32 {
        guard o >= 0, o + 4 <= bytes.count else { throw EmuuError.parse("AXML truncated at \(o)") }
        return UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
    }

    private struct Attribute {
        var name: String
        var resourceID: UInt32?
        var rawString: String?
        var dataType: UInt8
        var data: UInt32
    }

    func parse() throws -> APKManifest {
        guard try u16(0) == Self.resXMLType else { throw EmuuError.parse("not an Android binary XML file") }
        let headerSize = Int(try u16(2))
        let total = min(Int(try u32(4)), bytes.count)
        var strings: [String] = []
        var resourceMap: [UInt32] = []
        var manifest: APKManifest?
        var offset = headerSize
        while offset + 8 <= total {
            let type = try u16(offset)
            let chunkHeaderSize = Int(try u16(offset + 2))
            let chunkSize = Int(try u32(offset + 4))
            guard chunkSize >= 8, offset + chunkSize <= total else { throw EmuuError.parse("AXML chunk overruns file") }
            switch type {
            case Self.resStringPoolType:
                strings = try readStringPool(at: offset)
            case Self.resXMLResourceMapType:
                let count = (chunkSize - chunkHeaderSize) / 4
                resourceMap = try (0..<count).map { try u32(offset + chunkHeaderSize + $0 * 4) }
            case Self.resXMLStartElementType:
                let ext = offset + chunkHeaderSize
                let nameIndex = Int(try u32(ext + 4))
                let elementName = nameIndex < strings.count ? strings[nameIndex] : ""
                let attrStart = Int(try u16(ext + 8))
                let attrSize = Int(try u16(ext + 10))
                let attrCount = Int(try u16(ext + 12))
                var attrs: [Attribute] = []
                for i in 0..<attrCount {
                    let a = ext + attrStart + i * attrSize
                    let n = Int(try u32(a + 4))
                    let raw = try u32(a + 8)
                    let value = try u32(a + 16)
                    attrs.append(Attribute(
                        name: n < strings.count ? strings[n] : "",
                        resourceID: n < resourceMap.count ? resourceMap[n] : nil,
                        rawString: raw != 0xFFFF_FFFF && Int(raw) < strings.count ? strings[Int(raw)] : nil,
                        dataType: bytes[a + 15],
                        data: value
                    ))
                }
                if elementName == "manifest", manifest == nil {
                    manifest = try manifestFrom(attrs, strings: strings)
                } else if elementName == "uses-sdk", manifest != nil {
                    for a in attrs {
                        if a.resourceID == Self.attrMinSdkVersion || a.name == "minSdkVersion" { manifest?.minSdkVersion = intValue(a) }
                        if a.resourceID == Self.attrTargetSdkVersion || a.name == "targetSdkVersion" { manifest?.targetSdkVersion = intValue(a) }
                    }
                    return manifest!
                } else if manifest != nil, elementName == "application" {
                    return manifest!
                }
            default:
                break
            }
            offset += chunkSize
        }
        guard let manifest else { throw EmuuError.parse("AndroidManifest.xml has no <manifest> element") }
        return manifest
    }

    private func intValue(_ a: Attribute) -> Int? {
        switch a.dataType {
        case Self.typeIntDec, Self.typeIntHex: return Int(Int32(bitPattern: a.data))
        case Self.typeString: return a.rawString.flatMap { Int($0) }
        default: return nil
        }
    }

    private func stringValue(_ a: Attribute, strings: [String]) -> String? {
        if let s = a.rawString { return s }
        if a.dataType == Self.typeString, Int(a.data) < strings.count { return strings[Int(a.data)] }
        if a.dataType == Self.typeIntDec { return String(Int32(bitPattern: a.data)) }
        return nil
    }

    private func manifestFrom(_ attrs: [Attribute], strings: [String]) throws -> APKManifest {
        var m = APKManifest(packageName: "")
        for a in attrs {
            if a.resourceID == Self.attrVersionCode || (a.resourceID == nil && a.name == "versionCode") {
                if a.dataType == Self.typeIntDec || a.dataType == Self.typeIntHex {
                    m.versionCode = Int64(a.data)
                } else if let s = a.rawString {
                    m.versionCode = Int64(s)
                }
            } else if a.resourceID == Self.attrVersionName || (a.resourceID == nil && a.name == "versionName") {
                m.versionName = stringValue(a, strings: strings)
            } else if a.name == "package" {
                m.packageName = stringValue(a, strings: strings) ?? ""
            } else if a.name == "split" {
                m.splitName = stringValue(a, strings: strings)
            }
        }
        guard !m.packageName.isEmpty else { throw EmuuError.parse("<manifest> has no package attribute") }
        return m
    }

    private func readStringPool(at chunk: Int) throws -> [String] {
        let headerSize = Int(try u16(chunk + 2))
        let count = Int(try u32(chunk + 8))
        let flags = try u32(chunk + 16)
        let stringsStart = Int(try u32(chunk + 20))
        let utf8 = flags & 0x100 != 0
        guard count < 1_000_000 else { throw EmuuError.parse("AXML string pool too large") }
        var result: [String] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let off = chunk + stringsStart + Int(try u32(chunk + headerSize + i * 4))
            result.append(utf8 ? try utf8String(at: off) : try utf16String(at: off))
        }
        return result
    }

    private func utf8String(at start: Int) throws -> String {
        var o = start
        func len8() throws -> Int {
            guard o < bytes.count else { throw EmuuError.parse("AXML string out of range") }
            var v = Int(bytes[o]); o += 1
            if v & 0x80 != 0 {
                guard o < bytes.count else { throw EmuuError.parse("AXML string out of range") }
                v = ((v & 0x7F) << 8) | Int(bytes[o]); o += 1
            }
            return v
        }
        _ = try len8()          // UTF-16 length (unused)
        let byteLength = try len8()
        guard o + byteLength <= bytes.count else { throw EmuuError.parse("AXML string out of range") }
        return String(decoding: bytes[o..<(o + byteLength)], as: UTF8.self)
    }

    private func utf16String(at start: Int) throws -> String {
        var o = start
        var length = Int(try u16(o)); o += 2
        if length & 0x8000 != 0 {
            length = ((length & 0x7FFF) << 16) | Int(try u16(o)); o += 2
        }
        guard o + length * 2 <= bytes.count else { throw EmuuError.parse("AXML string out of range") }
        var units: [UInt16] = []
        units.reserveCapacity(length)
        for i in 0..<length { units.append(try u16(o + i * 2)) }
        return String(decoding: units, as: UTF16.self)
    }
}
