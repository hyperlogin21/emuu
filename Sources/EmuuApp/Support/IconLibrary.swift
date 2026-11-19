import AppKit
import SwiftUI

/// The control strip's SVG icons (Sources/EmuuApp/Resources/Icons, 24×24, 1.75 px strokes).
///
/// SwiftPM copies them into `Emuu_EmuuApp.bundle`. Its generated `Bundle.module` only looks next to the
/// executable / at the app's root and traps when the bundle is missing, while `scripts/make-app.sh` puts the
/// bundle in `Contents/Resources` (the root of a signed app must not hold extra files). So the bundle is
/// looked up here in every place it can be: `Contents/Resources`, next to the executable (`swift build`,
/// `swift run`) and the app root. Icons are template images: they follow the label colour in light and
/// dark mode.
@MainActor
enum IconLibrary {
    static let bundleName = "Emuu_EmuuApp.bundle"

    static let iconsDirectory: URL? = {
        var candidates: [URL] = []
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent(bundleName)) }
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            candidates.append(exe.deletingLastPathComponent().appendingPathComponent(bundleName))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(bundleName))
        for bundleURL in candidates {
            // macOS resource bundles keep files in Contents/Resources; accept a flat layout too.
            let roots = [Bundle(url: bundleURL)?.resourceURL, bundleURL].compactMap { $0 }
            for root in roots {
                let icons = root.appendingPathComponent("Icons", isDirectory: true)
                if FileManager.default.fileExists(atPath: icons.appendingPathComponent("home.svg").path) { return icons }
            }
        }
        return nil
    }()

    private static var cache: [String: NSImage] = [:]

    /// The named icon as a template image, nil if the resource bundle is missing.
    static func image(_ name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        guard let url = iconsDirectory?.appendingPathComponent("\(name).svg"), let image = NSImage(contentsOf: url) else {
            return nil
        }
        image.isTemplate = true
        image.size = NSSize(width: 24, height: 24)
        cache[name] = image
        return image
    }

    /// All icon names (for checks).
    static let names = ["back", "home", "recents", "rotate", "volume-up", "volume-down", "screenshot", "record",
                        "record-stop", "keyboard", "install", "playstore", "apps", "memory", "copy"]
}

/// An SVG icon from `IconLibrary`, falling back to an SF Symbol if the bundle is missing.
struct StripIcon: View {
    let name: String
    let fallback: String
    var size: CGFloat = 20

    var body: some View {
        if let image = IconLibrary.image(name) {
            Image(nsImage: image).renderingMode(.template).resizable().interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: fallback).font(.system(size: size * 0.8)).frame(width: size, height: size)
        }
    }
}
