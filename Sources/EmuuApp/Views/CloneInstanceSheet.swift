import SwiftUI
import EmuuBase
import EmuuFarm

/// "Clone…" sheet: name for the copy, consent to hibernate a running source, progress.
struct CloneInstanceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let source: InstanceRow

    @State private var name = ""
    @State private var working = false
    @State private var status: String?
    @State private var error: String?

    private var sourceName: String { source.config.displayName.isEmpty ? source.id.rawValue : source.config.displayName }

    var body: some View {
        let plan = model.clonePlan(for: source.id, consent: true)
        VStack(alignment: .leading, spacing: 12) {
            Text("Clone “\(sourceName)”").font(.title2.bold())
            Text("The copy gets everything on \(sourceName): Google sign-in, Play Store, apps and their data, settings. It takes no extra disk space until the two differ.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name of the copy", text: $name)
                .textFieldStyle(.roundedBorder)
                .disabled(working)
            switch plan {
            case .hibernateCopyResume:
                Label("\(sourceName) is running. To copy it safely, Emuu hibernates it for a few seconds (its state is saved), makes the copy, then resumes it. Its apps continue where they were.",
                      systemImage: "pause.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .refuse(let why):
                Text(why).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            case .copyNow:
                EmptyView()
            }
            Text("Google sees the copy as the same device and account as \(sourceName). Google may not keep you signed in on several copies that run at the same time.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if working, let status {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status).font(.callout)
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                Button(Self.confirmTitle(plan)) { clone() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty || {
                        if case .refuse = plan { return true } else { return false }
                    }())
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { if name.isEmpty { name = model.suggestedCloneName(for: source.id) } }
    }

    nonisolated static func confirmTitle(_ plan: CloneSourcePlan) -> String {
        if case .hibernateCopyResume = plan { return "Hibernate, Clone & Resume" }
        return "Clone"
    }

    private func clone() {
        working = true
        error = nil
        status = "Preparing…"
        Task {
            do {
                _ = try await model.cloneInstance(source.id, displayName: name) { status = $0 }
                dismiss()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            working = false
        }
    }
}
