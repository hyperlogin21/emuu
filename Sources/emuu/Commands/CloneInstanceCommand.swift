import Foundation
import ArgumentParser
import EmuuBase
import EmuuEngine
import EmuuFarm

// MARK: clone-instance

/// `emuu clone-instance <source> <name>`: a full copy of an ordinary instance (Google sign-in, Play Store state,
/// apps and their data, settings), made with the farm's APFS clone machinery. A separate command rather than an
/// overload of `emuu clone <golden> <name>`: that command resolves its first argument as a sealed golden image,
/// and a golden is also an instance of the same name, so one command could not tell which was meant.
struct CloneInstance: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clone-instance",
        abstract: "Copy an instance with all its data (Google sign-in, apps, settings) into a new instance (APFS clone).",
        discussion: """
        The copy keeps everything on the source's data partition, including the Google account, so the new instance \
        is signed in too. It also keeps the source's Android identity (Android ID, Google services id): Google sees \
        every copy as the same device and account; whether Google keeps the session valid on several copies running \
        at once is not guaranteed.

        The source must not be running while it is copied (its disks are open and partly in memory). A stopped or \
        hibernated source is copied right away. A running one is refused unless --stop-source is given: then it is \
        hibernated (quick-boot snapshot saved, ~5–20 s), copied, and resumed, so its apps continue where they were.

        The quick-boot snapshot comes along by default, so the copy resumes in seconds exactly where the source \
        was; --cold-boot drops it (the copy boots Android from its disks instead).
        """)

    @Argument(help: "Instance to copy.") var source: String
    @Argument(help: "New instance name (letters, digits, '.', '_', '-').") var name: String
    @Option(help: "Display name of the copy (default: the new name).") var displayName: String?
    @Option(help: "Fixed console port for the copy (even, 5554-5584). Default: like the source (a free pair at each start, or a new fixed port if the source has one).")
    var port: Int?
    @Flag(help: "If the source is running: hibernate it for the copy and resume it afterwards.") var stopSource = false
    @Flag(help: "Do not carry the quick-boot snapshot; the copy cold-boots from its disks.") var coldBoot = false
    @Flag(help: "JSON output.") var json = false

    struct Report: Codable, Sendable {
        var source: String
        var instance: String
        var displayName: String
        var consolePort: Int?
        var carriedSnapshot: Bool
        var copyOnWrite: Bool
        var cloneSeconds: Double
        var apparentBytes: UInt64
        var sourcePaused: Bool
        var sourceStateAfter: String
    }

    func run() async throws {
        let ctx = try CLIContext.live()
        let src = try ctx.resolveInstance(source)
        let ids = Set(ctx.store.list().map(\.id.rawValue))
        if let problem = CloneNaming.problem(with: name, existingIDs: ids) { throw CLIError(problem) }
        let target = try InstanceID(validating: name)
        let fixedByOthers = Set(ctx.store.list().compactMap { $0.ports?.console })
        let ports: InstancePorts?
        do {
            ports = try ClonePorts.choose(requested: port, source: src.ports, fixedByOthers: fixedByOthers, isFree: { PortAllocator.isPortFree($0) })
        } catch { throw CLIError(describe(error)) }

        let engine = try await ctx.engines.engine(for: src.id)
        let state = await engine.refresh()
        let appOwner = RunStateStore.live(src.id, paths: ctx.paths).flatMap { $0.ownerKind == .app ? "the Emuu app (pid \($0.ownerPID))" : nil }
        let plan = CloneSourcePlan.decide(state: state, mayPause: stopSource, foreignOwner: appOwner, name: src.id.rawValue)

        if !InstanceStore.supportsClones(at: ctx.paths.avdHome) {
            Out.err("Note: \(ctx.paths.avdHome.path) is not on APFS (no clonefile support): making a full byte copy, which takes longer and uses the full disk space (\(ByteCount.format(InstanceCloner.apparentSize(ctx.paths.avdDirectory(for: src.id))))).")
        }

        var paused = false
        var refreeze = false
        switch plan {
        case .refuse(let why):
            throw CLIError(why)
        case .copyNow:
            break
        case .hibernateCopyResume(let r):
            refreeze = r
            Out.err("Hibernating \(src.id) for the copy (its state is saved and restored afterwards)…")
            try await EngineCommand.perform(.hibernate, instance: src.id.rawValue)
            let after = await (try ctx.engines.engine(for: src.id)).refresh()
            guard after == .hibernated || after == .stopped else {
                throw CLIError("\(src.id) did not hibernate (state \(after)); nothing was copied")
            }
            paused = true
        }

        var result: InstanceCloneResult?
        var failure: Error?
        do {
            result = try InstanceCloner(store: ctx.store).clone(src.id, to: target, displayName: displayName, ports: ports,
                                                                keepSnapshot: !coldBoot)
        } catch {
            failure = error
        }
        if paused {
            // Restore the source whatever happened to the copy.
            Out.err("Resuming \(src.id)…")
            do {
                try await EngineCommand.perform(.resume, instance: src.id.rawValue)
                if refreeze { try await EngineCommand.perform(.freeze, instance: src.id.rawValue) }
            } catch {
                Out.err("Warning: could not resume \(src.id): \(describe(error)). Start it with `emuu start \(src.id)` (it is hibernated, nothing is lost).")
            }
        }
        if let failure { throw CLIError("clone failed: \(describe(failure))") }
        guard let r = result else { return }
        let stateAfter = await (try ctx.engines.engine(for: src.id)).refresh()
        if json {
            return try Out.json(Report(source: src.id.rawValue, instance: r.config.id.rawValue, displayName: r.config.displayName,
                                       consolePort: r.config.ports?.console, carriedSnapshot: r.carriedSnapshot, copyOnWrite: r.copyOnWrite,
                                       cloneSeconds: Double(r.duration.components.seconds) + Double(r.duration.components.attoseconds) / 1e18,
                                       apparentBytes: r.apparentBytes, sourcePaused: paused, sourceStateAfter: stateAfter.description))
        }
        Out.line("Cloned \(src.id) → \(r.config.id) in \(Fmt.seconds(r.duration)) (\(r.copyOnWrite ? "APFS clone: no extra disk until the copies diverge" : "full copy"), \(ByteCount.format(r.apparentBytes)) apparent).")
        Out.line(r.carriedSnapshot
                 ? "The copy resumes where \(src.id) was: `emuu start \(r.config.id)`."
                 : "The copy cold-boots from its disks on first start: `emuu start \(r.config.id)`.")
        if paused { Out.line("\(src.id) was hibernated for the copy and is \(stateAfter) again.") }
        Out.line("Note: the copy presents to Google as the same device and account as \(src.id).")
    }
}
