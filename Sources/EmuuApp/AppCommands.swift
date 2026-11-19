import SwiftUI
import EmuuBase

/// Menu bar commands. They act on the key emulator window (`AppModel.activeSession`). Device shortcuts match
/// the ones the display view handles itself when focused (the view gets key equivalents first, so both paths
/// send the same thing exactly once).
struct EmuuCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    private var session: InstanceSession? { model.activeSession }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Instance…") {
                openWindow(id: EmuuMainApp.libraryWindowID)
                model.showCreateSheet = true
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            Button("Instance Library") { openWindow(id: EmuuMainApp.libraryWindowID) }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Button("Install APK…") { if let session { InstallPanel.run(for: session) } }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(session == nil)
        }

        CommandMenu("Device") {
            Group { deviceItems }.disabled(session == nil)
        }
    }

    @ViewBuilder private var deviceItems: some View {
        Button("Back") { session?.back() }
            .keyboardShortcut("b", modifiers: .command)
        Button("Home") { session?.home() }
            .keyboardShortcut("h", modifiers: [.command, .shift])
        Button("Recent Apps") { session?.recents() }
            .keyboardShortcut("s", modifiers: .command)
        Button("Rotate") { session?.rotate() }
            .keyboardShortcut("r", modifiers: .command)
        Button("Power") { session?.power() }
            .keyboardShortcut("p", modifiers: .command)
        Divider()
        Button("Volume Up") { session?.volumeUp() }
            .keyboardShortcut(.upArrow, modifiers: .command)
        Button("Volume Down") { session?.volumeDown() }
            .keyboardShortcut(.downArrow, modifiers: .command)
        Button(session?.softKeyboardEnabled == false ? "Show On-Screen Keyboard" : "Hide On-Screen Keyboard") {
            session?.toggleSoftKeyboard()
        }
        .keyboardShortcut("k", modifiers: .command)
        Divider()
        Button("Screenshot") { if let session { Task { await session.takeScreenshot() } } }
            .keyboardShortcut("s", modifiers: [.command, .shift])
        Button(session?.isRecording == true ? "Stop Recording" : "Start Recording") { session?.toggleRecording() }
            .keyboardShortcut("r", modifiers: [.command, .option])
        Button("Show Screenshots Folder") { session?.revealScreenshots() }
        Button("Show Recordings Folder") { session?.revealRecordings() }
        Button("Apps…") { session?.ui.showApps = true }
            .keyboardShortcut("a", modifiers: [.command, .shift])
        Button("Open Play Store") { if let session { Task { await session.openPlayStore() } } }
            .keyboardShortcut("p", modifiers: [.command, .shift])
        Button("Sign In to Google…") { if let session { Task { await session.openGoogleSignIn() } } }
        Divider()
        Button("Copy adb Serial") { session?.copySerial() }
            .keyboardShortcut("c", modifiers: [.command, .option])
        Button("Memory HUD") { session?.ui.showHUD.toggle() }
            .keyboardShortcut("m", modifiers: [.command, .shift])
        Button("Reclaim Memory Now") { if let session { Task { await session.reclaimNow() } } }
        Button("Hibernate") { if let session { Task { await session.hibernateNow() } } }
    }
}
