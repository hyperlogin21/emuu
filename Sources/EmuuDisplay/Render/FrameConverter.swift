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
    /// Returns nil when the pool is exhausted.
    public func convert(rgba source: UnsafeRawPointer, width: Int, height: Int) -> CVPixelBuffer? {
        guard width > 0, height > 0 else { return nil }
        if pool == nil || poolSize.width != width || poolSize.height != height {
            pool = Self.makePool(width: width, height: height, minimum: 3)
            poolSize = VideoSize(width: width, height: height)
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        let rc = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, auxAttributes, &out)
        guard rc == kCVReturnSuccess, let buffer = out else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let dst = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source), height: vImagePixelCount(height),
                                width: vImagePixelCount(width), rowBytes: width * 4)
        var dest = vImage_Buffer(data: dst, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                 rowBytes: CVPixelBufferGetBytesPerRow(buffer))
        let map: [UInt8] = [2, 1, 0, 3]   // RGBA → BGRA
        let err = vImagePermuteChannels_ARGB8888(&src, &dest, map, vImage_Flags(kvImageNoFlags))
        return err == kvImageNoError ? buffer : nil
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
