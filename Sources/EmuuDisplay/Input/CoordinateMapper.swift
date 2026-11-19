import Foundation
import CoreGraphics

/// Maps between view coordinates and video pixel coordinates for an aspect-fit layout
/// (`AVLayerVideoGravity.resizeAspect`: the video is scaled uniformly and centred, letterboxed).
///
/// View coordinates are top-left origin (the display view is flipped), in points.
public struct AspectFitMapper: Sendable, Hashable {
    public var viewSize: CGSize
    public var videoSize: VideoSize

    public init(viewSize: CGSize, videoSize: VideoSize) {
        self.viewSize = viewSize
        self.videoSize = videoSize
    }

    /// The rectangle (in view coordinates) the video occupies.
    public var contentRect: CGRect {
        guard !videoSize.isEmpty, viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let vw = CGFloat(videoSize.width), vh = CGFloat(videoSize.height)
        let scale = min(viewSize.width / vw, viewSize.height / vh)
        let w = vw * scale, h = vh * scale
        return CGRect(x: (viewSize.width - w) / 2, y: (viewSize.height - h) / 2, width: w, height: h)
    }

    /// Video pixels per view point.
    public var pixelsPerPoint: CGFloat {
        let r = contentRect
        return r.width > 0 ? CGFloat(videoSize.width) / r.width : 0
    }

    /// Maps a view point to integer video pixel coordinates. Returns nil outside the video area unless
    /// `clamp` is set (used while a drag that started inside leaves the picture).
    public func videoPoint(fromView p: CGPoint, clamp: Bool = false) -> (x: Int, y: Int)? {
        let r = contentRect
        guard r.width > 0, r.height > 0 else { return nil }
        // Multiply before dividing so exact pixel positions don't lose an ulp (190*720/360 == 380, not 379.999…).
        var fx = (p.x - r.minX) * CGFloat(videoSize.width) / r.width
        var fy = (p.y - r.minY) * CGFloat(videoSize.height) / r.height
        let w = CGFloat(videoSize.width), h = CGFloat(videoSize.height)
        if clamp {
            fx = min(max(fx, 0), w)
            fy = min(max(fy, 0), h)
        } else if fx < 0 || fx > w || fy < 0 || fy > h {
            return nil
        }
        // Pixel indices: [0, width-1].
        let x = Int(fx.rounded(.down)), y = Int(fy.rounded(.down))
        return (min(max(x, 0), videoSize.width - 1), min(max(y, 0), videoSize.height - 1))
    }

    /// Maps video pixel coordinates back to the view (pixel centre).
    public func viewPoint(fromVideoX x: Int, y: Int) -> CGPoint {
        let r = contentRect
        guard !videoSize.isEmpty else { return .zero }
        return CGPoint(
            x: r.minX + (CGFloat(x) + 0.5) / CGFloat(videoSize.width) * r.width,
            y: r.minY + (CGFloat(y) + 0.5) / CGFloat(videoSize.height) * r.height
        )
    }
}
