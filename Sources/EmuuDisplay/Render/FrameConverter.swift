import Foundation
import Accelerate
import CoreVideo
import CoreGraphics
import ImageIO
import EmuuBase

/// Copies RGBA frames out of the emulator's shared memory into BGRA, IOSurface-backed `CVPixelBuffer`s
/// from a small pool (no per-frame allocation once the pool is warm). One vImage channel permute per frame
/// (≈ one memcpy of 4.6 MB for 720x1600); the IOSurface is then handed to Core Animation / the encoder
/// without further copies.
///
/// The pool refuses to grow past `maxOutstanding` buffers: if the renderer/recorder still hold all of them
/// the frame is dropped instead (bounded memory under any back-pressure). Not thread-safe; used on the
/// session's reader thread only.
public final class FrameConverter: @unchecked Sendable {
    private var pool: CVPixelBufferPool?
    private var poolSize = VideoSize(width: 0, height: 0)
    private let maxOutstanding: Int
    private let auxAttributes: CFDictionary

    public init(maxOutstanding: Int = 8) {
        self.maxOutstanding = maxOutstanding
        self.auxAttributes = [kCVPixelBufferPoolAllocationThresholdKey: maxOutstanding] as CFDictionary
    }

    /// Converts `width × height` RGBA8888 pixels (tightly packed, top-down) at `source` into a pooled BGRA buffer.
    /// Returns nil when the pool is exhausted. No consistency check: use `convertStable` for memory another
    /// process may be writing.
    public func convert(rgba source: UnsafeRawPointer, width: Int, height: Int) -> CVPixelBuffer? {
        guard let buffer = pooledBuffer(width: width, height: height) else { return nil }
        return permute(source, into: buffer, width: width, height: height) ? buffer : nil
    }

    /// Outcome of `convertStable`.
    public enum StableResult {
        /// A consistent copy; `attempts` > 1 means the region changed under an earlier attempt.
        case frame(CVPixelBuffer, attempts: Int)
        /// No buffer free (renderer/recorder hold them all).
        case poolExhausted
        /// The region kept changing during every attempt (the engine was writing the next frame); dropped.
        case unstable(attempts: Int)
    }

    /// Like `convert`, for shared memory the engine may be overwriting right now (`ImageTransport.MMAP` has a
    /// single region per stream and no lock or sequence word; measured on 36.4.9 under host load: the engine
    /// writes into the region — bottom row first — while Emuu reads it, a few ms after sending the metadata).
    /// Seqlock-style without engine help: convert the region into the output buffer, then compare
    /// the output with the region (channel-swapped, one pass). Different means a write overlapped the read:
    /// retry, and drop the frame after `maxAttempts` (the engine's next message follows within a frame
    /// interval). Equal means no row changed between being read and being compared, so the output is one frame.
    ///
    /// Limit: a writer that was *paused* mid-frame for the whole read-and-compare (≈ 1 ms at 720x1600) leaves a
    /// stable half-written region that this cannot tell from a whole frame. The overlapping case is the one this
    /// catches (`DisplayStats.racedFrames`).
    public func convertStable(rgba source: UnsafeRawPointer, width: Int, height: Int, maxAttempts: Int = 3) -> StableResult {
        guard width > 0, height > 0 else { return .unstable(attempts: 0) }
        guard let buffer = pooledBuffer(width: width, height: height) else { return .poolExhausted }
        var attempts = 0
        while attempts < max(1, maxAttempts) {
            attempts += 1
            guard permute(source, into: buffer, width: width, height: height) else { return .poolExhausted }
            afterCopyForTesting?()
            let stable = buffer.withBGRAPixels { px in Self.matches(bgra: px, rgba: source) } ?? false
            guard stable else {
                if let onRace = raceObserver {
                    var info = Self.describeRace(output: buffer, region: source, width: width, height: height, attempt: attempts)
                    info.context = raceContext
                    onRace(info)
                }
                continue
            }
            return .frame(buffer, attempts: attempts)
        }
        return .unstable(attempts: attempts)
    }

    /// True when every pixel of `bgra` is the channel-swapped pixel of tightly packed `rgba` (one pass, no copy).
    static func matches(bgra px: BGRAPixels, rgba: UnsafeRawPointer) -> Bool {
        let rowBytes = px.width * 4
        for y in 0..<px.height where !rowMatches(px.base.advanced(by: y * px.bytesPerRow), rgba.advanced(by: y * rowBytes), pixels: px.width) {
            return false
        }
        return true
    }

    @inline(__always)
    static func rowMatches(_ bgra: UnsafeRawPointer, _ rgba: UnsafeRawPointer, pixels: Int) -> Bool {
        var diff: UInt64 = 0
        let words = pixels / 2
        if Int(bitPattern: bgra) & 7 == 0 && Int(bitPattern: rgba) & 7 == 0 {
            let a = bgra.assumingMemoryBound(to: UInt64.self), b = rgba.assumingMemoryBound(to: UInt64.self)
            for i in 0..<words {
                let x = b[i]
                diff |= ((x & 0xFF00_FF00_FF00_FF00) | ((x & 0x0000_00FF_0000_00FF) << 16) | ((x >> 16) & 0x0000_00FF_0000_00FF)) ^ a[i]
            }
        } else {
            for i in 0..<words {
                let x = rgba.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)
                diff |= ((x & 0xFF00_FF00_FF00_FF00) | ((x & 0x0000_00FF_0000_00FF) << 16) | ((x >> 16) & 0x0000_00FF_0000_00FF))
                    ^ bgra.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)
            }
        }
        if pixels & 1 == 1 {
            let x = UInt64(rgba.loadUnaligned(fromByteOffset: words * 8, as: UInt32.self))
            let y = UInt64(bgra.loadUnaligned(fromByteOffset: words * 8, as: UInt32.self))
            diff |= ((x & 0xFF00_FF00) | ((x & 0xFF) << 16) | ((x >> 16) & 0xFF)) ^ y
        }
        return diff == 0
    }

    /// Unit tests: runs between the copy and the compare (simulates the engine writing at that moment).
    var afterCopyForTesting: (() -> Void)?

    /// What a detected race looked like (diagnostics only; costs a row-by-row compare and a PNG-able copy).
    public struct RaceInfo: @unchecked Sendable {
        public var attempt: Int
        /// Rows that differed between the copy and the region afterwards.
        public var firstRow: Int, lastRow: Int, rowsChanged: Int
        public var height: Int
        /// Caller-supplied context (`raceContext` at the time), e.g. sequence number and transport delay.
        public var context: String = ""
        /// The picture as it was read (what an unvalidated read would have shown), BGRA.
        public var copy: CVPixelBuffer?
    }

    /// Diagnostics: called on the reader thread for every detected race. nil (default) = no extra work.
    public var raceObserver: ((RaceInfo) -> Void)?
    /// Diagnostics: copied into `RaceInfo.context`.
    public var raceContext = ""

    static func describeRace(output: CVPixelBuffer, region: UnsafeRawPointer, width: Int, height: Int, attempt: Int) -> RaceInfo {
        var first = -1, last = -1, changed = 0
        var copy: CVPixelBuffer?
        output.withBGRAPixels { px in
            for y in 0..<height where !rowMatches(px.base.advanced(by: y * px.bytesPerRow), region.advanced(by: y * width * 4), pixels: width) {
                if first < 0 { first = y }
                last = y
                changed += 1
            }
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &copy)
            if let copy {
                CVPixelBufferLockBaseAddress(copy, [])
                let dst = CVPixelBufferGetBaseAddress(copy)!, dstRow = CVPixelBufferGetBytesPerRow(copy)
                for y in 0..<height { memcpy(dst.advanced(by: y * dstRow), px.base.advanced(by: y * px.bytesPerRow), width * 4) }
                CVPixelBufferUnlockBaseAddress(copy, [])
            }
        }
        return RaceInfo(attempt: attempt, firstRow: first, lastRow: last, rowsChanged: changed, height: height, copy: copy)
    }

    private func pooledBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        guard width > 0, height > 0 else { return nil }
        if pool == nil || poolSize.width != width || poolSize.height != height {
            pool = Self.makePool(width: width, height: height, minimum: 3)
            poolSize = VideoSize(width: width, height: height)
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        let rc = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, auxAttributes, &out)
        guard rc == kCVReturnSuccess, let buffer = out else { return nil }
        return buffer
    }

    private func permute(_ source: UnsafeRawPointer, into buffer: CVPixelBuffer, width: Int, height: Int) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let dst = CVPixelBufferGetBaseAddress(buffer) else { return false }
        var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source), height: vImagePixelCount(height),
                                width: vImagePixelCount(width), rowBytes: width * 4)
        var dest = vImage_Buffer(data: dst, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                 rowBytes: CVPixelBufferGetBytesPerRow(buffer))
        let map: [UInt8] = [2, 1, 0, 3]   // RGBA → BGRA
        let err = vImagePermuteChannels_ARGB8888(&src, &dest, map, vImage_Flags(kvImageNoFlags))
        return err == kvImageNoError
    }

    static func makePool(width: Int, height: Int, minimum: Int) -> CVPixelBufferPool? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let poolAttrs: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: minimum]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, attrs as CFDictionary, &pool)
        return pool
    }
}

extension CVPixelBuffer {
    /// A CGImage copy of a BGRA buffer (screenshots/evidence only; not on the frame path).
    public func makeCGImage() -> CGImage? {
        CVPixelBufferLockBaseAddress(self, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(self, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(self) else { return nil }
        let w = CVPixelBufferGetWidth(self), h = CVPixelBufferGetHeight(self), bpr = CVPixelBufferGetBytesPerRow(self)
        guard let data = CFDataCreate(nil, base.assumingMemoryBound(to: UInt8.self), bpr * h),
              let provider = CGDataProvider(data: data) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// PNG of the buffer (evidence/screenshots).
    public func pngData() -> Data? {
        guard let image = makeCGImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
