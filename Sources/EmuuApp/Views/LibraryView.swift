import SwiftUI
import EmuuBase
import EmuuEngine

/// The instance library: list, create, start/stop/delete, state badges.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingDelete: InstanceRow?
    @State private var pendingClone: InstanceRow?

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if let error = model.setupError {
                SetupErrorView(message: error)
            } else if model.rows.isEmpty {
                ContentUnavailableView {
                    Label("No instances", systemImage: "iphone")
                } description: {
                    Text("Create a lightweight Android instance with Google Play.")
                } actions: {
                    Button("New Instance…") { model.showCreateSheet = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(model.rows) { row in
                        InstanceRowView(row: row, attached: model.sessions[row.id] != nil,
                                        busy: model.busy.contains(row.id),
                                        open: { open(row.id) },
                                        finish: { choice in Task { await model.finish(row.id, choice) } },
                                        delete: { pendingDelete = row },
                                        clone: { pendingClone = row })
                    }
                }
                .listStyle(.inset)
            }
            if let advice = model.playStoreAdvice {
                Text(advice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(8)
            }
        }
        .frame(minWidth: 460, minHeight: 280)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.showCreateSheet = true } label: { Label("New Instance", systemImage: "plus") }
                    .help("Create a new instance (⌥⌘N)")
                    .disabled(model.setupError != nil)
            }
        }
        .sheet(isPresented: $model.showCreateSheet) {
            CreateInstanceSheet { id in open(id) }
        }
        .sheet(item: $pendingClone) { row in
            CloneInstanceSheet(source: row)
        }
        .alert("Delete \(pendingDelete?.config.displayName ?? "")?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let row = pendingDelete { Task { await model.deleteInstance(row.id) } }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The instance, its apps and data are removed permanently.")
        }
        .alert("Emuu", isPresented: Binding(get: { model.libraryError != nil }, set: { if !$0 { model.libraryError = nil } })) {
            Button("OK") { model.libraryError = nil }
        } message: {
            Text(model.libraryError ?? "")
        }
        .onAppear { model.setLibraryVisible(true) }
        .onDisappear { model.setLibraryVisible(false) }
        .task {
            await model.attachRunningInstances()
        }
    }

    private func open(_ id: InstanceID) {
        model.openWindow(id)
    }
}

private struct SetupErrorView: View {
    let message: String
    var body: some View {
        ContentUnavailableView {
            Label("Android SDK not found", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message).textSelection(.enabled)
        }
    }
}

struct InstanceRowView: View {
    let row: InstanceRow
    let attached: Bool
    let busy: Bool
    let open: () -> Void
    let finish: (ShutdownChoice) -> Void
    let delete: () -> Void
    var clone: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone")
                .font(.title2)
                .foregroundStyle(row.state.isRunningEngine ? Color.accentColor : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.config.displayName.isEmpty ? row.id.rawValue : row.config.displayName)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StateBadge(state: row.state)
            if busy {
                ProgressView().controlSize(.small)
            }
            Button(primaryTitle, action: open)
                .disabled(busy || row.state == .stopping || row.state == .hibernating)
            Menu {
                Button("Hibernate") { finish(.hibernate) }
                    .disabled(!(row.state == .running || row.state == .frozen))
                Button("Shut Down") { finish(.shutDown) }
                    .disabled(!row.state.isRunningEngine)
                Divider()
                Button("Clone…", action: clone)
                    .disabled(busy)
                Button("Delete…", role: .destructive, action: delete)
                    .disabled(busy)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: open)
    }

    private var primaryTitle: String {
        if attached { return "Show" }
        switch row.state {
        case .running, .frozen, .booting: return "Open"
        case .hibernated: return "Resume"
        default: return "Start"
        }
    }

    private var subtitle: String {
        var parts = ["\(row.config.ramMB) MB", "\(row.config.cores) cores",
                     "\(row.config.display.width)×\(row.config.display.height)",
                     row.config.systemImage.androidVersion?.marketingName ?? row.config.systemImage.apiDirectory,
                     row.config.systemImage.hasPlayStore ? "Google Play" : row.config.systemImage.tag]
        if let owner = row.otherOwner {
            parts.append(owner.ownerKind == .cli ? "attached by CLI" : "attached by another app")
        }
        return parts.joined(separator: " · ")
    }
}

struct StateBadge: View {
    let state: InstanceState

    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var title: String {
        switch state {
        case .stopped: return "Stopped"
        case .booting: return "Booting"
        case .running: return "Running"
        case .frozen: return "Frozen"
        case .hibernating: return "Hibernating"
        case .hibernated: return "Hibernated"
        case .stopping: return "Stopping"
        case .crashed: return "Crashed"
        }
    }

    private var color: Color {
        switch state {
        case .running: return .green
        case .booting, .hibernating, .stopping: return .orange
        case .frozen: return .cyan
        case .hibernated: return .indigo
        case .stopped: return .secondary
        case .crashed: return .red
        }
    }
}

/// Create-instance sheet with the profile picker.
struct CreateInstanceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onCreated: (InstanceID) -> Void

    @State private var name = "Pixel"
    @State private var preset: InstancePreset = .standard
    @State private var image: SystemImageRef?
    @State private var creating = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Instance").font(.title2.bold())
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            Text("Profile").font(.headline)
            Picker("Profile", selection: $preset) {
                ForEach(InstancePreset.allCases, id: \.self) { p in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.title(p))
                        Text(Self.detail(p)).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(p)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            androidVersionSection
            if let advice = model.playStoreAdvice {
                Text(advice).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create & Start") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(creating)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func create() {
        creating = true
        error = nil
        Task {
            do {
                let id = try await model.createInstance(name: name, preset: preset, image: image)
                dismiss()
                onCreated(id)
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            creating = false
        }
    }

    /// Installed Android versions; others get the Terminal command that installs them (downloads are 1.5–2 GB and
    /// need Google's licence accepted, which stays in `emuu images install`).
    @ViewBuilder private var androidVersionSection: some View {
        let choices = model.androidVersionChoices
        if !choices.installed.isEmpty {
            Text("Android version").font(.headline)
            Picker("Android version", selection: Binding(get: { image ?? choices.defaultImage ?? choices.installed[0] },
                                                         set: { image = $0 })) {
                ForEach(choices.installed, id: \.self) { ref in
                    Text(AndroidVersionChoices.title(ref, isDefault: ref == choices.defaultImage)).tag(ref)
                }
            }
            .labelsHidden()
            Text("Fixed for the life of the instance (its data belongs to that version).")
                .font(.caption).foregroundStyle(.secondary)
            if !choices.installable.isEmpty {
                Text("Install another version in Terminal, then reopen this sheet: "
                     + choices.installable.map { "\($0.version.marketingName): `\($0.command)`" }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    static func title(_ p: InstancePreset) -> String {
        switch p {
        case .lite: return "Lite"
        case .standard: return "Standard"
        case .gaming: return "Gaming"
        }
    }

    static func detail(_ p: InstancePreset) -> String {
        "\(p.ramMB) MB RAM · \(p.cores) cores · " + {
            switch p {
            case .lite: return "smallest footprint, aggressive memory governor"
            case .standard: return "balanced for everyday apps"
            case .gaming: return "more RAM, governor stays out of the way while playing"
            }
        }()
    }
}
