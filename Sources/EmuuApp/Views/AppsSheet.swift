import SwiftUI
import EmuuBase
import EmuuADB

/// Installed user apps with launch / uninstall.
struct AppsSheet: View {
    let session: InstanceSession
    @Environment(\.dismiss) private var dismiss
    @State private var packages: [InstalledPackage] = []
    @State private var loading = true
    @State private var error: String?
    @State private var filter = ""
    @State private var working: String?
    @State private var confirmUninstall: InstalledPackage?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Apps").font(.title3.bold())
                Spacer()
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(width: 180)
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload")
            }
            .padding(12)
            Divider()
            Group {
                if loading && packages.isEmpty {
                    ProgressView("Loading apps…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled).padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filtered.isEmpty {
                    Text(packages.isEmpty ? "No user apps installed yet. Drop an APK on the window or use the Play Store."
                                          : "No match")
                        .foregroundStyle(.secondary).padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filtered) { pkg in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pkg.info.packageName).font(.body.monospaced()).lineLimit(1)
                                Text(detail(pkg)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if working == pkg.id { ProgressView().controlSize(.small) }
                            Button("Open") {
                                run(pkg) { try await PackageManager(shell: $0).launch(pkg.info.packageName) } then: { dismiss() }
                            }
                                .disabled(working != nil)
                            Button("Uninstall", role: .destructive) { confirmUninstall = pkg }
                                .disabled(working != nil)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text("\(packages.count) user apps").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 460)
        .task { await load() }
        .confirmationDialog("Uninstall \(confirmUninstall?.info.packageName ?? "")?",
                            isPresented: Binding(get: { confirmUninstall != nil }, set: { if !$0 { confirmUninstall = nil } })) {
            Button("Uninstall", role: .destructive) {
                if let pkg = confirmUninstall {
                    run(pkg) { shell in
                        let ok = try await PackageManager(shell: shell).uninstall(pkg.info.packageName)
                        if !ok { throw EmuuError.adb("uninstall of \(pkg.info.packageName) was refused") }
                    } then: { packages.removeAll { $0.id == pkg.id } }
                }
                confirmUninstall = nil
            }
        }
    }

    private var filtered: [InstalledPackage] {
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let list = f.isEmpty ? packages : packages.filter { $0.info.packageName.lowercased().contains(f) }
        return list.sorted { $0.info.packageName < $1.info.packageName }
    }

    private func detail(_ p: InstalledPackage) -> String {
        var parts: [String] = []
        if let v = p.info.versionName { parts.append("v\(v)") }
        if let b = p.codeBytes { parts.append(ByteCount.format(b)) }
        if p.info.isFromPlayStore { parts.append("Google Play") }
        if !p.info.isEnabled { parts.append("disabled") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        guard let client = session.client else {
            error = "The instance is not running."
            loading = false
            return
        }
        loading = true
        defer { loading = false }
        do {
            packages = try await PackageManager(shell: client).listPackages(includeSystem: false, details: true)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func run(_ pkg: InstalledPackage, _ body: @escaping @Sendable (ADBClient) async throws -> Void,
                     then: @escaping @MainActor () -> Void = {}) {
        guard let client = session.client else { return }
        working = pkg.id
        Task {
            do {
                try await body(client)
                then()
            } catch {
                session.showToast("\(pkg.info.packageName): \(error.localizedDescription)")
            }
            working = nil
        }
    }
}
