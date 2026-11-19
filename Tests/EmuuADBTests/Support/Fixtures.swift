import Foundation
import EmuuBase

/// Builds Android binary XML manifests and zip archives for tests.
enum Fixtures {
    // MARK: AXML encoder

    struct Attr {
        enum Value { case string(String), int(Int32) }
        var name: String
        var resourceID: UInt32?   // android attr id (nil for "package"/"split")
        var value: Value
    }

    struct Element {
        var name: String
        var attrs: [Attr]
    }

    static func le16(_ v: UInt16) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 2) }
    static func le32(_ v: UInt32) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 4) }

    /// Encodes a minimal binary XML document. Attribute names with resource ids are placed first in
    /// the string pool so the resource map lines up (as aapt does).
    static func binaryManifest(_ elements: [Element], utf8: Bool = false) -> Data {
        var pool: [String] = []
        var resIDs: [UInt32] = []
        func idx(_ s: String) -> UInt32 {
            if let i = pool.firstIndex(of: s) { return UInt32(i) }
            pool.append(s); return UInt32(pool.count - 1)
        }
        // resource-id'd attribute names first
        for e in elements { for a in e.attrs where a.resourceID != nil && !pool.contains(a.name) { pool.append(a.name); resIDs.append(a.resourceID!) } }
        _ = idx("http://schemas.android.com/apk/res/android")
        for e in elements {
            _ = idx(e.name)
            for a in e.attrs {
                _ = idx(a.name)
                if case .string(let s) = a.value { _ = idx(s) }
            }
        }

        // String pool chunk
        var strData = Data()
        var offsets: [UInt32] = []
        for s in pool {
            offsets.append(UInt32(strData.count))
            if utf8 {
                let bytes = Array(s.utf8)
                let u16 = s.utf16.count
                precondition(u16 < 0x80 && bytes.count < 0x80)
                strData.append(UInt8(u16)); strData.append(UInt8(bytes.count))
                strData.append(contentsOf: bytes); strData.append(0)
            } else {
                strData.append(le16(UInt16(s.utf16.count)))
                for u in s.utf16 { strData.append(le16(u)) }
                strData.append(le16(0))
            }
        }
        while strData.count % 4 != 0 { strData.append(0) }
        let poolHeader = 28
        let stringsStart = poolHeader + offsets.count * 4
        var poolChunk = Data()
        poolChunk.append(le16(0x0001)); poolChunk.append(le16(UInt16(poolHeader)))
        poolChunk.append(le32(UInt32(stringsStart + strData.count)))
        poolChunk.append(le32(UInt32(pool.count))); poolChunk.append(le32(0))
        poolChunk.append(le32(utf8 ? 0x100 : 0)); poolChunk.append(le32(UInt32(stringsStart))); poolChunk.append(le32(0))
        for o in offsets { poolChunk.append(le32(o)) }
        poolChunk.append(strData)

        var resMap = Data()
        resMap.append(le16(0x0180)); resMap.append(le16(8)); resMap.append(le32(UInt32(8 + 4 * resIDs.count)))
        for r in resIDs { resMap.append(le32(r)) }

        var body = Data()
        let ns = idx("http://schemas.android.com/apk/res/android")
        for e in elements {
            var chunk = Data()
            let attrCount = e.attrs.count
            let size = 16 + 20 + attrCount * 20
            chunk.append(le16(0x0102)); chunk.append(le16(16)); chunk.append(le32(UInt32(size)))
            chunk.append(le32(1)); chunk.append(le32(0xFFFF_FFFF))
            chunk.append(le32(0xFFFF_FFFF)); chunk.append(le32(idx(e.name)))
            chunk.append(le16(20)); chunk.append(le16(20)); chunk.append(le16(UInt16(attrCount)))
            chunk.append(le16(0)); chunk.append(le16(0)); chunk.append(le16(0))
            for a in e.attrs {
                chunk.append(le32(a.resourceID != nil ? ns : 0xFFFF_FFFF))
                chunk.append(le32(idx(a.name)))
                switch a.value {
                case .string(let s):
                    chunk.append(le32(idx(s))); chunk.append(le16(8)); chunk.append(0); chunk.append(0x03); chunk.append(le32(idx(s)))
                case .int(let v):
                    chunk.append(le32(0xFFFF_FFFF)); chunk.append(le16(8)); chunk.append(0); chunk.append(0x10); chunk.append(le32(UInt32(bitPattern: v)))
                }
            }
            body.append(chunk)
        }

        var doc = Data()
        let total = 8 + poolChunk.count + resMap.count + body.count
        doc.append(le16(0x0003)); doc.append(le16(8)); doc.append(le32(UInt32(total)))
        doc.append(poolChunk); doc.append(resMap); doc.append(body)
        return doc
    }

    static func manifest(package: String, versionCode: Int32 = 1, versionName: String = "1.0", split: String? = nil, minSdk: Int32 = 24, utf8: Bool = false) -> Data {
        var attrs: [Attr] = [
            Attr(name: "versionCode", resourceID: 0x0101_021B, value: .int(versionCode)),
            Attr(name: "versionName", resourceID: 0x0101_021C, value: .string(versionName)),
            Attr(name: "package", resourceID: nil, value: .string(package)),
        ]
        if let split { attrs.append(Attr(name: "split", resourceID: nil, value: .string(split))) }
        return binaryManifest([
            Element(name: "manifest", attrs: attrs),
            Element(name: "uses-sdk", attrs: [Attr(name: "minSdkVersion", resourceID: 0x0101_020C, value: .int(minSdk))]),
        ], utf8: utf8)
    }

    // MARK: Zip

    /// Creates a zip at `dest` from `files` (relative path -> contents) using /usr/bin/zip.
    @discardableResult
    static func zip(_ files: [String: Data], to dest: URL) throws -> URL {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("emuu-zip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        for (path, data) in files {
            let url = staging.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        try? FileManager.default.removeItem(at: dest)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = staging
        p.arguments = ["-q", "-r", "-X", dest.path] + files.keys.sorted()
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw EmuuError.io(path: dest.path, message: "zip failed \(p.terminationStatus)") }
        return dest
    }

    /// A fake APK: zip with a binary AndroidManifest.xml, classes.dex, and optional native libs.
    static func apk(at dest: URL, package: String, split: String? = nil, abis: [String] = [], payloadBytes: Int = 1000) throws -> URL {
        var files: [String: Data] = [
            "AndroidManifest.xml": manifest(package: package, split: split),
            "classes.dex": Data((0..<payloadBytes).map { UInt8(truncatingIfNeeded: $0 &* 31) }),
        ]
        for abi in abis { files["lib/\(abi)/libgame.so"] = Data("ELF-\(abi)".utf8) }
        return try zip(files, to: dest)
    }

    static func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("emuu-adb-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Shell output for DeviceSpec.query on a typical arm64 emulator.
    static func deviceSpecReply(abis: String = "arm64-v8a", density: Int = 320, locale: String = "en-US", sdk: Int = 36) -> String {
        "\(abis)\n@@EMUU@@\nPhysical density: \(density)\n@@EMUU@@\n\(density)\n@@EMUU@@\n\(locale)\n@@EMUU@@\n\n@@EMUU@@\n\(sdk)\n"
    }
}
