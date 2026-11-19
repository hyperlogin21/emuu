// Draws Emuu's app icon (1024x1024 PNG) with AppKit. Usage: swift make-icon.swift <out.png>
// Kept as a script so the icon has no binary asset in the repo; scripts/make-app.sh runs it.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
let size = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { fatalError("bitmap") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let s = CGFloat(size)

// macOS squircle-ish tile with a green gradient.
let tile = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18)
NSShadow().apply { $0.shadowBlurRadius = s * 0.02; $0.shadowOffset = NSSize(width: 0, height: -s * 0.01); $0.shadowColor = .black.withAlphaComponent(0.35) }
NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.80, blue: 0.52, alpha: 1),
                    NSColor(calibratedRed: 0.05, green: 0.45, blue: 0.40, alpha: 1)])!.draw(in: tilePath, angle: -90)
NSShadow().apply { $0.shadowColor = nil }

// Phone outline.
let phone = NSRect(x: s * 0.36, y: s * 0.22, width: s * 0.28, height: s * 0.56)
let phonePath = NSBezierPath(roundedRect: phone, xRadius: s * 0.045, yRadius: s * 0.045)
NSColor.white.withAlphaComponent(0.95).setFill()
phonePath.fill()
let screen = phone.insetBy(dx: s * 0.022, dy: s * 0.045)
let screenPath = NSBezierPath(roundedRect: screen, xRadius: s * 0.02, yRadius: s * 0.02)
NSColor(calibratedRed: 0.07, green: 0.20, blue: 0.22, alpha: 1).setFill()
screenPath.fill()

// A small "memory bars" glyph on the screen (the governor).
let barW = screen.width * 0.16
let gap = screen.width * 0.08
let heights: [CGFloat] = [0.30, 0.55, 0.40, 0.20]
var x = screen.midX - (CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap) / 2
for (i, h) in heights.enumerated() {
    let bar = NSRect(x: x, y: screen.minY + screen.height * 0.18, width: barW, height: screen.height * h)
    (i == 1 ? NSColor(calibratedRed: 0.55, green: 1.0, blue: 0.70, alpha: 1) : NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.62, alpha: 1)).setFill()
    NSBezierPath(roundedRect: bar, xRadius: barW * 0.3, yRadius: barW * 0.3).fill()
    x += barW + gap
}
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")

extension NSShadow {
    func apply(_ configure: (NSShadow) -> Void) {
        configure(self)
        set()
    }
}
