import SwiftUI
import EmuuBase
import EmuuMemory

/// The always-visible vertical control strip on the right of an emulator window.
///
/// Groups (top to bottom): navigation | device | capture | apps | memory. If the window is shorter than
/// the strip, it scrolls instead of overflowing into a menu.
struct ControlStrip: View {
    @Bindable var session: InstanceSession

    private var ready: Bool { session.phase == .ready && session.engineState == .running }

    var body: some View {
        @Bindable var ui = session.ui
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 2) {
                group {
                    StripButton(icon: "back", fallback: "chevron.backward", label: "Back", shortcut: "⌘B") { session.back() }
                    StripButton(icon: "home", fallback: "circle", label: "Home", shortcut: "⇧⌘H") { session.home() }
                    StripButton(icon: "recents", fallback: "square", label: "Recent apps", shortcut: "⌘S") { session.recents() }
                }
                StripDivider()
                group {
                    StripButton(icon: "rotate", fallback: "rotate.right", label: "Rotate", shortcut: "⌘R") { session.rotate() }
                    StripButton(icon: "volume-up", fallback: "speaker.plus", label: "Volume up", shortcut: "⌘↑") { session.volumeUp() }
                    StripButton(icon: "volume-down", fallback: "speaker.minus", label: "Volume down", shortcut: "⌘↓") { session.volumeDown() }
                    StripButton(icon: "keyboard", fallback: "keyboard",
                                label: session.softKeyboardEnabled ? "On-screen keyboard: on (click to hide)" : "On-screen keyboard: off (click to show)",
                                shortcut: "⌘K", isOn: session.softKeyboardEnabled, busy: session.keyboardBusy) {
                        session.toggleSoftKeyboard()
                    }
                }
                StripDivider()
                group {
                    StripButton(icon: "screenshot", fallback: "camera", label: "Screenshot to clipboard and ~/.emuu/screenshots",
                                shortcut: "⇧⌘S") { Task { await session.takeScreenshot() } }
                    RecordButton(session: session)
                }
                StripDivider()
                group {
                    StripButton(icon: "install", fallback: "square.and.arrow.down",
                                label: "Install APK… (.apk, .xapk, .apks, .apkm — or drop files on the window)", shortcut: "⌘I") {
                        InstallPanel.run(for: session)
                    }
                    StripButton(icon: "playstore", fallback: "bag", label: "Open Google Play", shortcut: "⇧⌘P") {
                        Task { await session.openPlayStore() }
                    }
                    StripButton(icon: "apps", fallback: "square.grid.2x2", label: "Installed apps", shortcut: "⇧⌘A") { ui.showApps = true }
                }
                StripDivider()
                MemoryIndicator(session: session)
                    .popover(isPresented: $ui.showHUD, arrowEdge: .leading) { MemoryHUDView(session: session) }
            }
            .disabled(!ready)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
        }
    }

    @ViewBuilder private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 2) { content() }
    }
}

private struct StripDivider: View {
    var body: some View {
        Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 26, height: 1).padding(.vertical, 6)
    }
}

/// Hover / pressed / on states for strip buttons.
struct StripButtonStyle: ButtonStyle {
    var isOn = false
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, isOn: isOn, tint: tint)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        let isOn: Bool
        let tint: Color?
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let fill: Color = configuration.isPressed ? Color.primary.opacity(0.18)
                : isOn ? Color.accentColor.opacity(0.18)
                : hovering ? Color.primary.opacity(0.08) : .clear
            configuration.label
                .foregroundStyle(tint ?? (isOn ? Color.accentColor : Color.primary.opacity(0.82)))
                .frame(width: 40, height: 36)
                .background(fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .opacity(enabled ? 1 : 0.35)
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
                .onHover { hovering = enabled && $0 }
        }
    }
}

struct StripButton: View {
    let icon: String
    let fallback: String
    let label: String
    var shortcut: String?
    var isOn = false
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                StripIcon(name: icon, fallback: fallback)
            }
        }
        .buttonStyle(StripButtonStyle(isOn: isOn))
        .help(shortcut.map { "\(label) (\($0))" } ?? label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Record toggle: red while recording, with the elapsed time underneath.
private struct RecordButton: View {
    let session: InstanceSession

    var body: some View {
        let recording = session.isRecording
        Button { session.toggleRecording() } label: {
            VStack(spacing: 1) {
                if session.recordingBusy {
                    ProgressView().controlSize(.small)
                } else {
                    StripIcon(name: recording ? "record-stop" : "record", fallback: recording ? "stop.circle" : "record.circle",
                              size: recording ? 18 : 20)
                }
                if recording, let start = session.recordingStartedAt {
                    TimelineView(.periodic(from: start, by: 1)) { ctx in
                        Text(Self.elapsed(from: start, to: ctx.date))
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    }
                }
            }
        }
        .buttonStyle(StripButtonStyle(tint: recording ? .red : nil))
        .background(recording ? Color.red.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(recording ? "Stop recording (⌥⌘R)" : "Record the screen to an MP4 in ~/.emuu/recordings (⌥⌘R)")
        .accessibilityLabel(recording ? "Stop recording" : "Start recording")
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Memory indicator: chip icon plus guest memory use, coloured by the governor's pressure level. Opens the HUD.
private struct MemoryIndicator: View {
    let session: InstanceSession

    var body: some View {
        Button { session.ui.showHUD.toggle() } label: {
            VStack(spacing: 2) {
                StripIcon(name: "memory", fallback: "memorychip", size: 18)
                Text(usedText).font(.system(size: 9, weight: .semibold).monospacedDigit())
                Capsule().fill(Color.primary.opacity(0.12)).frame(width: 24, height: 3)
                    .overlay(alignment: .leading) {
                        Capsule().fill(levelColor).frame(width: 24 * usedFraction, height: 3)
                    }
            }
        }
        .buttonStyle(StripButtonStyle(isOn: session.ui.showHUD))
        .frame(height: 50)
        .help("Memory: \(helpText) (⇧⌘M)")
        .accessibilityLabel("Memory HUD, \(helpText)")
    }

    private var usedFraction: CGFloat {
        guard let p = session.latestSample, let total = p.guestTotalBytes, let avail = p.guestAvailableBytes, total > 0 else { return 0 }
        return CGFloat(Double(total - min(avail, total)) / Double(total))
    }

    private var usedText: String {
        session.latestSample?.guestTotalBytes == nil ? "–" : "\(Int((usedFraction * 100).rounded()))%"
    }

    private var helpText: String {
        var parts: [String] = []
        if session.latestSample?.guestTotalBytes != nil { parts.append("guest \(usedText) used") }
        if let s = session.governorStatus { parts.append("tier \(s.tier.description), \(s.level.description)") }
        if session.automationMode { parts.append("automation mode") }
        return parts.isEmpty ? "governor details" : parts.joined(separator: ", ")
    }

    private var levelColor: Color {
        switch session.governorStatus?.level ?? .normal {
        case .normal: return .green
        case .elevated: return .yellow
        case .high: return .orange
        case .critical: return .red
        }
    }
}
