// Generates a machine-readable test video for display-artefact diagnosis (see docs/ARCHITECTURE.md,
// "Diagnosing display artefacts"). Every frame n carries:
//   * a magenta border (constant; lets the analyser find the video on screen),
//   * a background whose grey level changes every frame,
//   * the frame counter n mod 512 in FIVE markers (four corners + centre), each 3 cells of an 8-colour
//     palette (3 bits per cell) — a frame whose markers disagree is torn or mixed,
//   * a white vertical bar that moves every frame.
// Length: <seconds> rounded up to a multiple of 512 frames (the counter period).
// Raw RGB frames go to ffmpeg on stdin (H.264 High, yuv420p, like phone/TikTok video).
//
// Usage: swift make-pattern-video.swift <width> <height> <fps> <seconds> <out.mp4> [noise]
// `noise` fills the background with moving random texture and encodes at ~12 Mbit/s, so the decoder works as
// hard as on real camera footage (flat colours decode almost for free).
import Foundation

let args = CommandLine.arguments
guard args.count == 6 || args.count == 7, let W = Int(args[1]), let H = Int(args[2]), let fps = Int(args[3]), let secs = Int(args[4]) else {
    FileHandle.standardError.write("usage: make-pattern-video.swift W H FPS SECONDS OUT.mp4\n".data(using: .utf8)!)
    exit(2)
}
let out = args[5]
let noisy = args.count == 7 && args[6] == "noise"

/// Must match `PatternGeometry` in Sources/EmuuDisplay/Diagnostics/FrameAnalyzer.swift.
let palette: [(UInt8, UInt8, UInt8)] = [(0, 0, 0), (255, 0, 0), (0, 255, 0), (0, 0, 255),
                                         (255, 255, 0), (0, 255, 255), (255, 0, 255), (255, 255, 255)]
let border = max(4, W / 40)
let cell = W / 10
func markerOrigins() -> [(Int, Int)] {
    let m = border + cell / 3
    return [(m, m), (W - m - 3 * cell, m), (m, H - m - cell), (W - m - 3 * cell, H - m - cell),
            (W / 2 - 3 * cell / 2, H / 2 - cell / 2)]
}

let ffmpeg = Process()
ffmpeg.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
ffmpeg.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", "\(W)x\(H)",
                    "-r", "\(fps)", "-i", "-", "-c:v", "libx264", "-profile:v", "high", "-pix_fmt", "yuv420p",
                    "-preset", "fast"] + (noisy ? ["-b:v", "12M", "-maxrate", "16M", "-bufsize", "16M"] : ["-crf", "16"]) + [ "-g", "\(fps)", "-movflags", "+faststart", out]
let pipe = Pipe()
ffmpeg.standardInput = pipe
try ffmpeg.run()

var buf = [UInt8](repeating: 0, count: W * H * 3)
func fill(_ x0: Int, _ y0: Int, _ w: Int, _ h: Int, _ c: (UInt8, UInt8, UInt8)) {
    for y in max(0, y0)..<min(H, y0 + h) {
        var i = (y * W + max(0, x0)) * 3
        for _ in max(0, x0)..<min(W, x0 + w) {
            buf[i] = c.0; buf[i + 1] = c.1; buf[i + 2] = c.2
            i += 3
        }
    }
}

// A whole number of counter periods, so a looping player wraps 511 → 0 like any other step.
let total = (fps * secs + 511) / 512 * 512
let barW = max(6, W / 40)
for n in 0..<total {
    let g = UInt8(40 + (n * 7) % 160)   // background grey, changes every frame
    fill(0, 0, W, H, (g, g, g))
    if noisy {
        // Moving pseudo-random texture (xorshift), ±48 around the grey level: hard to compress, like real footage.
        var r = UInt32(truncatingIfNeeded: n &* 2654435761 | 1)
        for y in stride(from: 0, to: H, by: 2) {
            for x in stride(from: 0, to: W, by: 2) {
                r ^= r << 13; r ^= r >> 17; r ^= r << 5
                let v = UInt8(clamping: Int(g) + Int(r % 97) - 48)
                for dy in 0..<2 { var i = ((y + dy) * W + x) * 3; for _ in 0..<2 { buf[i] = v; buf[i + 1] = v &+ UInt8(r >> 24 & 15); buf[i + 2] = v; i += 3 } }
            }
        }
    }
    let span = W - 2 * border - barW
    fill(border + (n * W / 60) % span, border, barW, H - 2 * border, (255, 255, 255))
    for (x, y) in markerOrigins() {
        fill(x - cell / 8, y - cell / 8, 3 * cell + cell / 4, cell + cell / 4, (128, 128, 128))   // neutral frame around cells
        for k in 0..<3 {
            fill(x + k * cell, y, cell, cell, palette[(n >> (3 * (2 - k))) & 7])
        }
    }
    fill(0, 0, W, border, (255, 0, 255)); fill(0, H - border, W, border, (255, 0, 255))
    fill(0, 0, border, H, (255, 0, 255)); fill(W - border, 0, border, H, (255, 0, 255))
    buf.withUnsafeBytes { pipe.fileHandleForWriting.write(Data($0)) }
}
try pipe.fileHandleForWriting.close()
ffmpeg.waitUntilExit()
exit(ffmpeg.terminationStatus)
