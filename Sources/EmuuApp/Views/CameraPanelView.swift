import AppKit
import SwiftUI
import UniformTypeIdentifiers
import EmuuBase
import EmuuEngine

/// State of the camera popover: the saved setting, what the running engine has, Mac cameras, the shown picture.
@MainActor
@Observable
final class CameraPanelModel {
    let session: InstanceSession
    private(set) var setting: CameraConfig
    /// `hw.camera.*` of the running engine (engine values), nil while unknown.
    private(set) var runningBack: String?
    private(set) var runningFront: String?
    private(set) var hostCameras: [HostCamera] = []
    private(set) var shownImage: String?
    private(set) var busy = false
    private(set) var message: String?

    init(session: InstanceSession) {
        self.session = session
        self.setting = (try? session.engineEnvironment.store.load(session.id))?.cameraConfig ?? session.config.cameraConfig
    }

    var env: EngineEnvironment { session.engineEnvironment }

    func load() async {
        if let fresh = try? env.store.load(session.id) { setting = fresh.cameraConfig }
        let launched = CameraLaunchPlan.launchedCameras(avdDirectory: env.paths.avdDirectory(for: session.id))
        runningBack = launched?.back
        runningFront = launched?.front
        let pid = await session.engineController?.enginePID()
        shownImage = CameraShownState.load(env.paths, session.id, pid: pid)?.image
        hostCameras = (try? await HostCameraList.query(sdk: env.sdk)) ?? []
    }

    /// Engine value the setting resolves to (Mac cameras by name/ID through the current host list).
    func engineValue(_ s: CameraSource) -> String {
        HostCameraList.engineValue(s, hostCameras: hostCameras) ?? "none"
    }

    /// The running engine has other cameras than the saved setting.
    var restartNeeded: Bool {
        guard let b = runningBack, let f = runningFront else { return false }
        return b != engineValue(setting.back) || f != engineValue(setting.front)
    }

    var sceneRunning: Bool { runningBack == "virtualscene" }

    /// Choices for one camera: None, Virtual scene (back only), Emulated, then each Mac camera by name.
    func choices(_ facing: CameraFacing) -> [(source: CameraSource, title: String)] {
        var out: [(CameraSource, String)] = [(.none, "None")]
        if facing == .back { out.append((.virtualScene, "Virtual scene (can show a picture)")) }
        out.append((.emulated, "Emulated (test pattern)"))
        for c in hostCameras { out.append((.webcam(c.uniqueID), c.name ?? c.engineName)) }
        // Keep a stored Mac camera that is not connected now selectable.
        let current = setting.source(facing)
        if !out.contains(where: { $0.0 == current }) { out.append((current, "\(current.title) (not connected)")) }
        return out
    }

    func set(_ facing: CameraFacing, _ source: CameraSource) {
        var c = setting
        c.set(facing, source)
        if c.problems.first != nil {
            message = c.problems.first
            return
        }
        do {
            _ = try env.store.updatePreferences(session.id) { $0.camera = c }
            setting = c
            message = nil
            session.note(.info, "Camera \(facing.rawValue): \(source.argument) (applies at the next start)")
        } catch {
            message = "Could not save: \(error.localizedDescription)"
        }
    }

    func restart() {
        session.restartForCameraChange()
        session.ui.showCamera = false
    }

    func show(_ url: URL) async {
        guard let engine = session.engineController else { return }
        busy = true
        defer { busy = false }
        do {
            let config = (try? env.store.load(session.id)) ?? session.config
            let (scene, pid) = try await VirtualSceneAccess.open(paths: env.paths, engine: engine, config: config)
            let r = try await scene.show(image: url)
            CameraShownState(enginePID: pid, image: url.path, poster: r.poster, shownAt: Date()).save(env.paths, session.id)
            shownImage = url.path
            message = nil
            session.note(.action, "Back camera shows \(url.lastPathComponent) (\(Int(r.totalMilliseconds)) ms)")
        } catch {
            message = "Could not show the picture: \(error.localizedDescription)"
        }
    }

    func clear() async {
        guard let engine = session.engineController else { return }
        busy = true
        defer { busy = false }
        do {
            let config = (try? env.store.load(session.id)) ?? session.config
            let (scene, _) = try await VirtualSceneAccess.open(paths: env.paths, engine: engine, config: config)
            try await scene.clear()
            CameraShownState.remove(env.paths, session.id)
            shownImage = nil
            message = nil
            session.note(.action, "Back camera shows the default room")
        } catch {
            message = "Could not clear: \(error.localizedDescription)"
        }
    }

    func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Picture for the back camera"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await show(url) }
    }
}

/// Camera popover from the control strip: back/front source, restart when the hardware changed, and the picture
/// the back camera sees (virtual scene). Dropping an image here shows it (dropping on the device installs APKs).
struct CameraPanelView: View {
    let session: InstanceSession
    @State private var model: CameraPanelModel?
    @State private var dropHover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Camera").font(.headline)
            if let model {
                content(model)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 340)
        .task {
            let m = CameraPanelModel(session: session)
            model = m
            await m.load()
        }
    }

    @ViewBuilder private func content(_ m: CameraPanelModel) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            row("Back", .back, m)
            row("Front", .front, m)
        }
        if m.restartNeeded {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.clockwise.circle").foregroundStyle(.orange)
                Text("Android lists its cameras when it starts: this change applies when the device restarts (one cold boot; apps and data stay).")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            Button("Restart Device Now") { m.restart() }
                .disabled(m.busy)
        }
        if m.setting.back.isWebcam || m.setting.front.isWebcam {
            Text("Mac cameras need camera permission for Emuu (asked when the device starts).")
                .font(.caption).foregroundStyle(.secondary)
        }
        Divider()
        Text("Picture for the back camera").font(.subheadline.weight(.semibold))
        if m.sceneRunning {
            dropZone(m)
            HStack {
                Button("Choose Image…") { m.choosePicture() }
                Button("Clear") { Task { await m.clear() } }.disabled(m.shownImage == nil)
                Spacer()
                if m.busy { ProgressView().controlSize(.small) }
            }
            .disabled(m.busy)
            Text("Apps see the picture filling the back camera's frame (1280×960). Same as `emuu camera show`.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Needs the back camera set to Virtual scene (then restart the device).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if let msg = m.message {
            Text(msg).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func row(_ title: String, _ facing: CameraFacing, _ m: CameraPanelModel) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Picker(title, selection: Binding(get: { m.setting.source(facing) }, set: { m.set(facing, $0) })) {
                ForEach(Array(m.choices(facing).enumerated()), id: \.offset) { _, c in Text(c.title).tag(c.source) }
            }
            .labelsHidden()
        }
    }

    private func dropZone(_ m: CameraPanelModel) -> some View {
        let shown = m.shownImage.map { URL(fileURLWithPath: $0) }
        return ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(dropHover ? Color.accentColor : Color.secondary.opacity(0.5))
                .background(dropHover ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
            if let shown, let image = NSImage(contentsOf: shown) {
                HStack(spacing: 10) {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shown.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Text("Drop another image to swap it").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(8)
            } else {
                Label("Drop an image here (QR code, ID card, …)", systemImage: "photo.on.rectangle")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(height: 74)
        .onDrop(of: [.fileURL], isTargeted: $dropHover) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url, UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else { return }
                Task { @MainActor in await m.show(url) }
            }
            return true
        }
    }
}
