import SwiftUI
import EmuuBase
import EmuuMemory

/// Memory HUD popover: guest/host figures, governor tier, recent actions, profile and policy controls.
struct MemoryHUDView: View {
    @Bindable var session: InstanceSession
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: 12) {
            header
            figures
            Divider()
            controls(settings: settings)
            Divider()
            timeline
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { session.setHUDActive(true) }
        .onDisappear { session.setHUDActive(false) }
    }

    private var header: some View {
        HStack {
            Text("Memory").font(.headline)
            Spacer()
            if let s = session.governorStatus {
                Text(s.tier.description)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(tierColor(s.tier).opacity(0.2), in: Capsule())
                    .foregroundStyle(tierColor(s.tier))
                Text(s.level.description.capitalized)
                    .font(.caption)
                    .foregroundStyle(levelColor(s.level))
            } else if let owner = session.otherGovernorOwner {
                Text("Governed by Emuu pid \(owner.ownerPID)")
                    .font(.caption).foregroundStyle(.secondary)
            } else if session.isCLISupervised {
                Text(session.cliGovernorSummary ?? "Governed by emuu CLI (pid \(session.cliSupervisorPID.map(String.init) ?? "?"))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private var figures: some View {
        let p = session.latestSample
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            if let total = p?.guestTotalBytes, let avail = p?.guestAvailableBytes, total > 0 {
                GridRow {
                    Text("Guest used").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        ProgressView(value: Double(total - min(avail, total)), total: Double(total))
                            .tint(levelColor(session.governorStatus?.level ?? .normal))
                        Text("\(ByteCount.format(total - min(avail, total))) of \(ByteCount.format(total)) · \(ByteCount.format(avail)) available")
                            .font(.caption).monospacedDigit()
                    }
                }
            } else {
                GridRow {
                    Text("Guest").foregroundStyle(.secondary)
                    Text(session.engineState == .running ? "waiting for first sample…" : String(describing: session.engineState))
                        .font(.caption)
                }
            }
            if let swap = p?.guestSwapUsedBytes {
                GridRow {
                    Text("Guest zram").foregroundStyle(.secondary)
                    Text(ByteCount.format(swap)).font(.caption).monospacedDigit()
                }
            }
            GridRow {
                Text("Engine").foregroundStyle(.secondary)
                if let fp = p?.engineFootprintBytes {
                    Text("\(ByteCount.format(fp)) footprint" + (p?.engineCPUPercent.map { String(format: " · %.0f%% CPU", $0) } ?? ""))
                        .font(.caption).monospacedDigit()
                } else {
                    Text("—").font(.caption)
                }
            }
            if let hp = p?.hostPressure {
                GridRow {
                    Text("Mac").foregroundStyle(.secondary)
                    Text("pressure \(hp.description)" + (p?.hostFreeBytes.map { " · \(ByteCount.format($0)) free" } ?? ""))
                        .font(.caption).foregroundStyle(levelColor(hp))
                }
            }
            if let s = session.governorStatus, s.creepActive {
                GridRow {
                    Text("Trend").foregroundStyle(.secondary)
                    Text("memory creep detected").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private func controls(settings: AppSettings) -> some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 8) {
            Picker("Profile", selection: Binding(get: { session.profile }, set: { p in Task { await session.setProfile(p) } })) {
                ForEach(MemoryProfile.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(!session.governsMemory)

            Toggle("Automation mode", isOn: Binding(get: { session.automationMode },
                                                    set: { on in Task { await session.setAutomationMode(on) } }))
                .help("For tests and scripts over adb (adb -s \(session.client?.serial.rawValue ?? "<serial>")): never freeze or hibernate this instance; only background apps are trimmed. Saved per instance; same as `emuu automation on|off`.")
            Picker("Video decoder", selection: Binding(get: { session.videoDecoder }, set: { session.setVideoDecoder($0) })) {
                ForEach(VideoDecoderMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .help("Where video in the guest is decoded. Software (Android's own decoders, the default) avoids the host decoder path; Hardware uses the Mac's VideoToolbox. Applies at the next start (one cold boot when switching). Same as `emuu video-decoder`.")
            Toggle("Freeze when hidden", isOn: $settings.autoFreezeWhenHidden)
                .disabled(session.automationMode)
                .onChange(of: settings.autoFreezeWhenHidden) { model.settingsChanged() }
                .help("Pause the engine (0% CPU) after the window has been hidden for a while; thaws instantly when shown")
            Picker("Hibernate after frozen", selection: $settings.hibernateAfterIdleMinutes) {
                ForEach(AppSettings.hibernateChoices, id: \.self) { m in
                    Text(m == 0 ? "Never" : (m < 60 ? "\(m) min" : "\(m / 60) h")).tag(m)
                }
            }
            .onChange(of: settings.hibernateAfterIdleMinutes) { model.settingsChanged() }
            .help("Save a snapshot and quit the engine to release all host memory; resumes in ~2 s")

            HStack {
                Button {
                    Task { await session.reclaimNow() }
                } label: {
                    if session.reclaimInProgress { ProgressView().controlSize(.small) } else { Text("Reclaim Now") }
                }
                .disabled(session.reclaimInProgress || session.engineState != .running)
                .help("Trim background apps, kill cached processes and compact system memory in the guest")
                Button("Hibernate") { Task { await session.hibernateNow() } }
                    .disabled(!(session.engineState == .running || session.engineState == .frozen))
                    .help("Release all host memory now; the window resumes the instance in ~2 s")
                Spacer()
            }
            if AppSettings.engineActionsDisabled {
                Text("EMUU_APP_NO_ENGINE_ACTIONS is set: the governor will not freeze or hibernate.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent activity").font(.subheadline.weight(.semibold))
            if session.timeline.isEmpty {
                Text("Nothing yet").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(session.timeline.reversed()) { e in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(e.date, format: .dateTime.hour().minute().second())
                                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                                Image(systemName: icon(e.kind)).font(.caption2).foregroundStyle(color(e.kind))
                                Text(e.text).font(.caption).lineLimit(3)
                            }
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        }
    }

    private func icon(_ k: TimelineEntry.Kind) -> String {
        switch k {
        case .info: return "info.circle"
        case .action: return "bolt.fill"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    private func color(_ k: TimelineEntry.Kind) -> Color {
        switch k {
        case .info: return .secondary
        case .action: return .accentColor
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func tierColor(_ t: GovernorTier) -> Color {
        switch t {
        case .none: return .green
        case .trim, .killBackground: return .orange
        case .reclaim: return .red
        case .freeze: return .cyan
        case .hibernate: return .indigo
        }
    }

    private func levelColor(_ l: MemoryPressureLevel) -> Color {
        switch l {
        case .normal: return .green
        case .elevated: return .yellow
        case .high: return .orange
        case .critical: return .red
        }
    }
}
