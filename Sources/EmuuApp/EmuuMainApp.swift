import AppKit
import SwiftUI
import EmuuBase
import EmuuEngine

struct EmuuMainApp: App {
    static let libraryWindowID = "library"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Emuu", id: Self.libraryWindowID) {
            LibraryView()
                .environment(delegate.model)
        }
        .defaultSize(width: 560, height: 380)
        .commands { EmuuCommands(model: delegate.model) }

        Settings {
            SettingsView().environment(delegate.model)
        }
    }
}

/// Quit handling: offers hibernate (default), shut down or keep running for attached instances.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var terminating = false

    private var selfTest: SelfTestRunner?
    private var cloneTest: CloneSelfTest?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second launch hands over to this process (see `SingleInstanceGuard`).
        DistributedNotificationCenter.default().addObserver(
            forName: SingleInstanceGuard.activateNotification, object: String(getpid()), queue: .main) { [weak self] note in
            let files = (note.userInfo?["files"] as? [String]) ?? []
            MainActor.assumeIsolated {
                NSApp.activate(ignoringOtherApps: true)
                if let key = NSApp.windows.first(where: { $0.isVisible && !$0.isMiniaturized }) {
                    key.makeKeyAndOrderFront(nil)
                } else {
                    NSApp.windows.first { $0.identifier?.rawValue.contains(EmuuMainApp.libraryWindowID) == true }?.makeKeyAndOrderFront(nil)
                }
                if !files.isEmpty { self?.application(NSApp, open: files.map { URL(fileURLWithPath: $0) }) }
            }
        }
        if ProcessInfo.processInfo.environment["EMUU_APP_SELFTEST"] != nil {
            let runner = SelfTestRunner(model: model)
            selfTest = runner
            runner.start()
        }
        if let spec = ProcessInfo.processInfo.environment["EMUU_APP_CLONETEST"] {
            let runner = CloneSelfTest(model: model)
            cloneTest = runner
            runner.start(spec: spec)
        }
    }

    /// Finder "Open With Emuu" / dropping APKs on the Dock icon: install into the key emulator window's
    /// instance, or the only attached one.
    func application(_ application: NSApplication, open urls: [URL]) {
        let ready = model.sessions.values.filter { $0.phase == .ready }
        let active = model.activeSession.flatMap { $0.phase == .ready ? $0 : nil }
        let target = active ?? (ready.count == 1 ? ready.first : nil)
        guard let target else {
            let alert = NSAlert()
            alert.messageText = ready.isEmpty ? "No running instance" : "Which instance?"
            alert.informativeText = ready.isEmpty
                ? "Start an instance first, then open the file again or drop it on the emulator window."
                : "Several instances are running. Drop the file on the emulator window you want to install it on."
            alert.runModal()
            return
        }
        target.install(urls: urls)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateLater }
        let running = model.runningSessions
        let choice: ShutdownChoice
        if running.isEmpty || ProcessInfo.processInfo.environment["EMUU_APP_SELFTEST"] != nil {
            choice = .keepRunning
        } else {
            let alert = NSAlert()
            let names = running.map(\.displayName).sorted().joined(separator: ", ")
            alert.messageText = running.count == 1 ? "\(names) is running" : "\(running.count) instances are running"
            alert.informativeText = "Hibernate saves the current state and releases all memory; the next start resumes in about 2 seconds. "
                + (running.count > 1 ? "(\(names))" : "")
            let order: [ShutdownChoice] = [model.settings.onQuit] + ShutdownChoice.allCases.filter { $0 != model.settings.onQuit }
            for c in order { alert.addButton(withTitle: c.title) }
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard response >= 0, response < order.count else { return .terminateCancel }
            choice = order[response]
        }
        terminating = true
        Task { @MainActor in
            await model.finishAll(choice)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Settings window (⌘,).
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Memory") {
                Toggle("Freeze instances when their window is hidden", isOn: $settings.autoFreezeWhenHidden)
                Picker("Hibernate after being frozen for", selection: $settings.hibernateAfterIdleMinutes) {
                    ForEach(AppSettings.hibernateChoices, id: \.self) { m in
                        Text(m == 0 ? "Never" : (m < 60 ? "\(m) minutes" : "\(m / 60) hours")).tag(m)
                    }
                }
            }
            Section("Lifecycle") {
                Picker("When an emulator window closes", selection: $settings.onWindowClose) {
                    ForEach(ShutdownChoice.allCases) { Text($0.title).tag($0) }
                }
                Picker("Default when quitting", selection: $settings.onQuit) {
                    ForEach(ShutdownChoice.allCases) { Text($0.title).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onChange(of: settings.autoFreezeWhenHidden) { model.settingsChanged() }
        .onChange(of: settings.hibernateAfterIdleMinutes) { model.settingsChanged() }
    }
}
