import AppKit
import SwiftUI
import UniformTypeIdentifiers
import EmuuBase
import EmuuDisplay

/// UI-only per-window flags (sheets/popovers/drop highlight), owned by the session so menu commands reach them.
@MainActor
@Observable
final class WindowUIState {
    var showApps = false
    var showHUD = false
    /// A file drag hovers over the window (SwiftUI area or the display view).
    var dropTargeted = false
}

/// Root of an emulator window: the session's view, or a start button when nothing is attached.
struct InstanceRootView: View {
    let id: InstanceID
    /// Reports the device's video size so the window controller can keep the aspect ratio.
    let onVideoSize: @MainActor (VideoSize) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        if let session = model.session(for: id) {
            InstanceSessionView(session: session, onVideoSize: onVideoSize)
        } else {
            DetachedInstanceView(id: id)
        }
    }
}

/// Shown when the window exists but no session is attached (e.g. after the instance was deleted elsewhere).
private struct DetachedInstanceView: View {
    let id: InstanceID
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "iphone.slash").font(.largeTitle).foregroundStyle(.secondary)
            Text(id.rawValue).font(.headline)
            Button("Start") { model.openWindow(id) }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The device screen (left) and the control strip (right). The whole window, display layer included, is a
/// drop target for APKs.
struct InstanceSessionView: View {
    @Bindable var session: InstanceSession
    let onVideoSize: @MainActor (VideoSize) -> Void
    @State private var swiftUIDropTargeted = false

    var body: some View {
        @Bindable var ui = session.ui
        HStack(spacing: 0) {
            screen
            ControlStrip(session: session)
                .frame(width: InstanceWindowGeometry.stripWidth)
        }
        .overlay {
            if ui.dropTargeted || swiftUIDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.12))
                    .overlay(Text("Drop to install").font(.title3.bold()).foregroundStyle(.white)
                        .padding(8).background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8)))
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            session.install(urls: urls)
            return true
        } isTargeted: { swiftUIDropTargeted = $0 }
        .sheet(isPresented: $ui.showApps) { AppsSheet(session: session) }
        .task(id: session.phase) {
            if session.phase == .ready { await session.startDisplay() }
        }
        .onChange(of: session.display?.videoSize, initial: true) { _, size in
            if let size { onVideoSize(size) }
        }
    }

    private var screen: some View {
        ZStack {
            Color.black
            if let display = session.display {
                EmulatorDisplay(controller: display)
                    .id(ObjectIdentifier(display))
            }
            overlay
        }
        .overlay(alignment: .bottom) { InstallJobsView(session: session) }
        .overlay(alignment: .top) { ToastView(session: session) }
        .frame(minWidth: 160, minHeight: InstanceWindowGeometry.minDisplayHeight)
    }

    @ViewBuilder private var overlay: some View {
        switch session.phase {
        case .working(let text):
            VStack(spacing: 10) {
                ProgressView().controlSize(.large).tint(.white)
                Text(text).foregroundStyle(.white.opacity(0.85))
            }
        case .parked(let state):
            VStack(spacing: 10) {
                Image(systemName: state == .hibernated ? "moon.zzz.fill" : "power")
                    .font(.system(size: 40)).foregroundStyle(.white.opacity(0.8))
                Text(state == .hibernated ? "Hibernated — host memory released" : "Stopped")
                    .foregroundStyle(.white.opacity(0.85))
                Button(state == .hibernated ? "Resume" : "Start") { session.resumeEngine() }
                    .buttonStyle(.borderedProminent)
            }
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 36)).foregroundStyle(.yellow)
                Text(message).foregroundStyle(.white).multilineTextAlignment(.center).textSelection(.enabled)
                    .padding(.horizontal)
                HStack {
                    Button("Retry") { session.resumeEngine() }
                    Button("Cold Boot") { session.resumeEngine(coldBoot: true) }
                }
            }
        case .ready:
            if let d = session.display, case .failed(let reason) = d.state, reason.contains("no gRPC endpoint") {
                VStack(spacing: 10) {
                    Image(systemName: "display.trianglebadge.exclamationmark").font(.system(size: 36)).foregroundStyle(.yellow)
                    Text("This engine was started by an older Emuu without its display service. Restart it once (state is kept: quick-boot snapshot, about 5 s).")
                        .foregroundStyle(.white).multilineTextAlignment(.center).padding(.horizontal)
                    Button("Restart Engine") { session.restartEngineForDisplay() }.buttonStyle(.borderedProminent)
                }
            } else if session.engineState == .frozen {
                Label("Frozen", systemImage: "snowflake")
                    .font(.callout).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.black.opacity(0.5), in: Capsule())
            }
        }
    }
}

/// Open panel for installs (menu ⌘I and the strip).
@MainActor
enum InstallPanel {
    static func run(for session: InstanceSession) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = InstanceSession.installExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Install"
        panel.message = "Choose .apk, .xapk, .apks or .apkm files (select all split APKs together)"
        if panel.runModal() == .OK { session.install(urls: panel.urls) }
    }
}

/// Install progress / result banners at the bottom of the screen area.
private struct InstallJobsView: View {
    let session: InstanceSession

    var body: some View {
        VStack(spacing: 6) {
            ForEach(session.installJobs) { job in
                HStack(spacing: 8) {
                    switch job.status {
                    case .running(let stage, let fraction):
                        ProgressView(value: fraction ?? 0).frame(width: 60)
                            .opacity(fraction == nil ? 0.4 : 1)
                        Text("\(stage) \(job.fileName)…").lineLimit(1)
                    case .succeeded(let text):
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(text).lineLimit(2)
                    case .failed(let text):
                        Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                        Text("\(job.fileName): \(text)").lineLimit(4).textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                    if !job.isRunning {
                        Button { session.dismissInstallJob(job.id) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain)
                    }
                }
                .font(.callout)
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(8)
    }
}

/// Transient message at the top of the screen area, with "Show in Finder" for saved files.
private struct ToastView: View {
    let session: InstanceSession

    var body: some View {
        if let text = session.toast {
            HStack(spacing: 8) {
                Text(text).font(.callout).lineLimit(3)
                if session.toastRevealURL != nil {
                    Button("Show in Finder") { session.revealToastFile() }
                        .buttonStyle(.link).font(.callout.weight(.semibold))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 8).padding(.horizontal, 8)
            .transition(.opacity)
        }
    }
}
