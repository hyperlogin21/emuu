import Foundation
import ArgumentParser
import EmuuBase
import EmuuEngine
import EmuuADB
import EmuuMemory

/// Results of `emuu bench` (rendered as Markdown; unit-tested).
struct BenchReport: Codable, Sendable, Hashable {
    struct IdlePhase: Codable, Sendable, Hashable {
        var label: String
        var minutes: Double
        var footprintStart: UInt64?
        var footprintEnd: UInt64?
        var footprintPeak: UInt64?
        var residentEnd: UInt64?
        var guestAvailableEnd: UInt64?
        var guestTotal: UInt64?
        var cpuAveragePercent: Double?
        var governorActions: Int?
        var governorNotes: [String] = []
    }

    var instance: String
    var ramMB: Int
    var cores: Int
    var engineVersion: String?
    var host: String
    var date: Date
    var coldBoot: Duration?
    var hibernate: Duration?
    var hibernateFootprintBefore: UInt64?
    var resume: Duration?
    var phases: [IdlePhase] = []

    func markdown() -> String {
        var md: [String] = []
        let df = ISO8601DateFormatter()
        md.append("## Emuu bench: \(instance)")
        md.append("")
        md.append("\(ramMB) MB guest, \(cores) cores, engine \(engineVersion ?? "?"), \(host), \(df.string(from: date)).")
        md.append("")
        md.append("| Lifecycle | Time |")
        md.append("| --- | --- |")
        md.append("| Cold boot (launch → sys.boot_completed) | \(coldBoot.map(Fmt.seconds) ?? "not measured") |")
        md.append("| Hibernate (snapshot save + quit) | \(hibernate.map(Fmt.seconds) ?? "not measured") |")
        md.append("| Resume from hibernation (quick boot → sys.boot_completed) | \(resume.map(Fmt.seconds) ?? "not measured") |")
        if let fp = hibernateFootprintBefore {
            md.append("| Host memory returned by hibernate | \(ByteCount.format(fp)) (whole engine footprint) |")
        }
        md.append("")
        md.append("| Idle phase | Minutes | Engine footprint start | end | peak | Resident end | Guest available end | Engine CPU avg | Governor actions |")
        md.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
        for p in phases {
            let avail: String
            if let a = p.guestAvailableEnd, let t = p.guestTotal, t > 0 {
                avail = "\(Fmt.mib(a)) (\(Fmt.percent(Double(a) / Double(t))))"
            } else {
                avail = "-"
            }
            md.append("| \(p.label) | \(String(format: "%g", p.minutes)) | \(Fmt.mib(p.footprintStart)) | \(Fmt.mib(p.footprintEnd)) | \(Fmt.mib(p.footprintPeak)) | \(Fmt.mib(p.residentEnd)) | \(avail) | \(p.cpuAveragePercent.map { String(format: "%.1f%%", $0) } ?? "-") | \(p.governorActions.map(String.init) ?? "n/a") |")
        }
        let notes = phases.flatMap { p in p.governorNotes.map { "- \(p.label): \($0)" } }
        if !notes.isEmpty {
            md.append("")
            md.append("Governor activity:")
            md += notes
        }
        md.append("")
        md.append("Footprint is the engine process tree's `phys_footprint` (what Activity Monitor shows as Memory; it includes compressed pages). The governor phase runs after the resume, so it starts from a freshly restored engine; compare trends, not single numbers.")
        return md.joined(separator: "\n")
    }
}

struct Bench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Measure cold boot, hibernate/resume and idle footprint with and without the governor (Markdown table).",
        discussion: """
        Takes over the instance for the whole run: it must be stopped (or hibernated) and not supervised. \
        Sequence: cold boot → idle N min without governor → hibernate → resume → idle N min with governor → stop \
        (quick-boot snapshot saved). Wall time is about 2×N minutes plus ~1 minute.
        """)

    @OptionGroup var target: TargetInstance
    @Option(help: "Idle minutes per phase.") var minutes: Double = 10
    @Option(help: "Seconds between footprint samples.") var sampleEvery: Int = 15
    @Option(help: "Governor profile for the governor phase (default: the instance's).") var profile: ProfileArgument?
    @Option(help: "Let the governor freeze the idle engine after this many minutes in the governor phase.") var idleFreeze: Int?
    @Option(help: "Also write the Markdown to this file.") var output: String?
    @Flag(help: "Print JSON instead of Markdown.") var json = false

    func validate() throws {
        if minutes <= 0 { throw ValidationError("--minutes must be positive") }
        if sampleEvery < 1 { throw ValidationError("--sample-every must be at least 1") }
    }

    func run() async throws {
        let ctx = try CLIContext.live()
        let config = try ctx.resolveInstance(target.explicit)
        let id = config.id
        if SupervisorRegistry(paths: ctx.paths).liveSupervisor(for: id) != nil {
            throw CLIError("\(id) is supervised; stop it first (`emuu stop \(id)`).")
        }
        let engine = try await ctx.engines.engine(for: id)
        let initial = await engine.refresh()
        guard !initial.isRunningEngine else { throw CLIError("\(id) is \(initial); stop it first so the cold boot is real (`emuu stop \(id)`).") }

        var report = BenchReport(instance: id.rawValue, ramMB: EffectiveRAM.megabytes(for: config, paths: ctx.paths), cores: config.cores,
                                 engineVersion: ctx.sdk.emulatorVersion,
                                 host: "\(ProcessInfo.processInfo.physicalMemory / ByteCount.gib) GB Mac, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
                                 date: Date())
        let clock = ContinuousClock()
        do {
            Out.err("[bench] cold boot of \(id)…")
            var t0 = clock.now
            try await engine.start(EngineLaunchOptions(coldBoot: true))
            report.coldBoot = clock.now - t0
            Out.err("[bench] cold boot \(Fmt.seconds(report.coldBoot!)); idle \(String(format: "%g", minutes)) min without governor…")
            report.phases.append(try await idlePhase(label: "Without governor", engine: engine, governor: nil))

            report.hibernateFootprintBefore = HostSampler.processTreeStats(root: await engine.enginePID() ?? -1)?.footprintBytes
            Out.err("[bench] hibernate…")
            t0 = clock.now
            try await engine.hibernate()
            report.hibernate = clock.now - t0
            Out.err("[bench] resume…")
            t0 = clock.now
            try await engine.resume()
            report.resume = clock.now - t0

            guard let serial = await engine.serial() else { throw CLIError("no serial after resume") }
            let options = GovernorOptions(profile: profile?.memoryProfile ?? config.memoryProfile, guestRAMMB: EffectiveRAM.megabytes(for: config, paths: ctx.paths),
                                          headless: true, idleFreezeAfter: idleFreeze.map { .minutes($0) })
            let shell = FollowingShell(serial: serial, server: ctx.adbServer())
            let bundle = GovernorFactory.make(instanceID: id, options: options, engine: engine, shell: shell,
                                              activity: SupervisorActivity(), csv: nil)
            Out.err("[bench] resumed in \(Fmt.seconds(report.resume!)); idle \(String(format: "%g", minutes)) min with governor (\(options.profile.rawValue))…")
            await bundle.governor.start()
            var phase = try await idlePhase(label: "With governor (\(ProfileArgument(options.profile).rawValue))", engine: engine, governor: bundle.governor)
            await bundle.governor.stop()
            let events = await bundle.governor.recentEvents()
            phase.governorActions = events.filter { if case .actionApplied = $0.kind { return true } else { return false } }.count
            phase.governorNotes = events.compactMap { e -> String? in
                switch e.kind {
                case .sampled, .stateChanged: return nil
                default: return EventText.render(e)
                }
            }
            report.phases.append(phase)
        } catch {
            Out.err("[bench] failed: \(describe(error)); stopping \(id).")
            try? await engine.stop(.graceful(saveQuickBoot: true))
            throw error
        }
        Out.err("[bench] stopping \(id) (quick-boot snapshot saved)…")
        if await engine.state() == .frozen { try await engine.thaw() }
        try await engine.stop(.graceful(saveQuickBoot: true))

        let md = report.markdown()
        if json { try Out.json(report) } else { Out.line(md) }
        if let output {
            try md.write(to: URL(fileURLWithPath: (output as NSString).expandingTildeInPath), atomically: true, encoding: .utf8)
            Out.err("[bench] wrote \(output)")
        }
    }

    private func idlePhase(label: String, engine: EngineInstance, governor: MemoryGovernor?) async throws -> BenchReport.IdlePhase {
        var phase = BenchReport.IdlePhase(label: label, minutes: minutes)
        let sampler = HostSampler()
        let deadline = ContinuousClock.now + .seconds(minutes * 60)
        var cpu: [Double] = []
        var first = true
        while true {
            if let pid = await engine.enginePID(), let s = sampler.sample(enginePID: pid).engine {
                if first { phase.footprintStart = s.footprintBytes; first = false }
                phase.footprintEnd = s.footprintBytes
                phase.footprintPeak = max(phase.footprintPeak ?? 0, s.footprintBytes)
                phase.residentEnd = s.residentBytes
                if let c = s.cpuPercent { cpu.append(c) }
                Out.progress("[bench] \(label): engine \(ByteCount.format(s.footprintBytes)), cpu \(s.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "-"), state \(await engine.state())")
            }
            if ContinuousClock.now >= deadline { break }
            try await Task.sleep(for: min(.seconds(sampleEvery), deadline - ContinuousClock.now))
        }
        Out.endProgress()
        if !cpu.isEmpty { phase.cpuAveragePercent = cpu.reduce(0, +) / Double(cpu.count) }
        var state = await engine.state()
        if state == .frozen, governor != nil {
            // Measure the guest after a thaw (adb hangs while frozen).
            try await engine.thaw()
            state = await engine.state()
        }
        if state == .running, let serial = await engine.serial(),
           let snap = try? await GuestSampler(shell: ADBClient(serial: serial)).sample() {
            phase.guestAvailableEnd = snap.memory.availableBytes
            phase.guestTotal = snap.memory.totalBytes
        }
        return phase
    }
}
