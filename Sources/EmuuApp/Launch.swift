import Foundation

/// Entry point: one Emuu app per user. A second launch (Finder, `open -n`, running the binary directly)
/// activates the running app, forwards install files and exits before it creates any window or Dock icon.
@main
enum EmuuLauncher {
    static func main() {
        SingleInstanceGuard.enforce()
        EmuuMainApp.main()
    }
}
