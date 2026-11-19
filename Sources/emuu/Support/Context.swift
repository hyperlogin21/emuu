import Foundation
import ArgumentParser
import EmuuBase
import EmuuEngine
import EmuuADB
import EmuuGRPC
import EmuuDisplay

/// `-i/--instance` shared by every command that acts on one instance.
struct InstanceOption: ParsableArguments {
    @Option(name: [.short, .customLong("instance")],
            help: "Instance name. Default: $EMUU_INSTANCE, else the only instance, else the only running one.")
    var instance: String?
}

/// Per-invocation wiring: paths, SDK, engine environment and adb.
struct CLIContext: Sendable {
    let environment: [String: String]
    let paths: EmuuPaths
    let engines: EngineEnvironment

    /// Builds the live environment (locates the SDK). Bootstraps the file log once.
    static func live(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> CLIContext {
        let paths = EmuuPaths.default(environment: environment)
        try paths.ensureDirectories()
        EmuuLogging.bootstrap(fileSink: LogFileSink(url: paths.mainLogFile), minimumFileLevel: .info)
        let sdk: AndroidSDK
        do {
            sdk = try SDKLocator(environment: environment).locate()
        } catch {
            throw CLIError("\(describe(error))\nRun `emuu doctor` for setup help.")
        }
        return CLIContext(environment: environment, paths: paths, engines: try EngineEnvironment(paths: paths, sdk: sdk))
    }

    var sdk: AndroidSDK { engines.sdk }
    var store: InstanceStore { engines.store }

    // MARK: instance resolution

    /// Picks the instance: explicit name, then `$EMUU_INSTANCE`, then the only instance, then the only
    /// running/supervised one.
    func resolveInstance(_ explicit: String?) throws -> InstanceConfig {
        let all = store.list()
        let raw = explicit ?? environment["EMUU_INSTANCE"]
        if let raw {
            guard let id = InstanceID(rawValue: raw) else { throw CLIError(describe(EmuuError.invalidInstanceID(raw))) }
            guard store.exists(id) else {
                throw CLIError("No instance named '\(raw)'. Known: \(all.map(\.id.rawValue).joined(separator: ", ").ifEmpty("none")). Create one with `emuu create \(raw)`.")
            }
            return try store.load(id)
        }
        return try InstanceResolution.pick(from: all, isActive: { config in
            store.isRunning(config.id) || SupervisorRegistry(paths: paths).liveSupervisor(for: config.id) != nil
        })
    }

    // MARK: adb

    func adbServer() -> ADBServer {
        ADBServer(endpoint: .fromEnvironment(environment), adbExecutable: sdk.adb)
    }

    /// An adb client for a running instance, after making sure it is usable (thawed/resumed through the
    /// supervisor when one runs, or directly otherwise).
    func readyDevice(_ config: InstanceConfig, wake: Bool = true) async throws -> ADBClient {
        let serial = try await ensureRunning(config, wake: wake)
        return ADBClient(serial: serial, server: adbServer())
    }

    /// Makes sure the engine is running and returns its serial. A frozen instance is thawed and a
    /// hibernated one resumed when `wake` is true (through its supervisor when present, so the governor
    /// sees the user activity). A stopped instance is an error: device commands never boot silently.
    func ensureRunning(_ config: InstanceConfig, wake: Bool = true) async throws -> DeviceSerial {
        let id = config.id
        if let sup = SupervisorRegistry(paths: paths).liveSupervisor(for: id) {
            let reply = try await ControlClient(socketPath: sup.socketPath).send(
                ControlRequest(command: wake ? .wake : .status), timeout: .seconds(wake ? 180 : 10))
            guard reply.ok, let status = reply.status else { throw CLIError(reply.message ?? "supervisor did not answer") }
            guard status.engineState == "running", let serial = status.serial else {
                throw CLIError("\(id) is \(status.engineState) (supervisor pid \(sup.pid)). \(wake ? "" : "Run `emuu thaw` or `emuu resume`.")")
            }
            return DeviceSerial(rawValue: serial)
        }
        let engine = try await engines.engine(for: id)
        let state = await engine.refresh()
        switch state {
        case .running:
            break
        case .frozen where wake:
            try await engine.thaw()
        case .hibernated where wake:
            Out.err("Resuming \(id) from hibernation…")
            try await engine.resume()
        case .booting:
            Out.err("Waiting for \(id) to finish booting…")
            try await engine.waitForBoot(timeout: .seconds(600))
        default:
            throw CLIError("\(id) is \(state). Start it with `emuu start \(id)`.")
        }
        guard let serial = await engine.serial() else { throw CLIError("\(id) has no adb serial (state \(await engine.state()))") }
        return serial
    }
}

extension CLIContext {
    /// The engine's gRPC endpoint (port + token from its discovery file), or nil when the engine is not
    /// running or was started without `-grpc` (by an older Emuu).
    func grpcEndpoint(_ id: InstanceID) async -> EmulatorGRPCEndpoint? {
        guard let engine = try? await engines.engine(for: id) else { return nil }
        _ = await engine.refresh()
        guard let pid = await engine.enginePID() else { return nil }
        return EmulatorDiscovery.endpoint(forPID: pid)
    }

    /// A display session (frames/input/clipboard/rotation over the engine's gRPC service) for an instance.
    func displaySession(_ id: InstanceID) -> EmulatorDisplaySession {
        let ctx = self
        return EmulatorDisplaySession(endpoint: { await ctx.grpcEndpoint(id) })
    }
}

/// Pure default-instance choice (unit-tested).
enum InstanceResolution {
    static func pick(from all: [InstanceConfig], isActive: (InstanceConfig) -> Bool) throws -> InstanceConfig {
        if all.count == 1 { return all[0] }
        if all.isEmpty { throw CLIError("No instances yet. Create one with `emuu create <name>` (run `emuu doctor` first).") }
        let active = all.filter(isActive)
        if active.count == 1 { return active[0] }
        throw CLIError("Several instances exist (\(all.map(\.id.rawValue).joined(separator: ", "))); pick one with -i <name> or set EMUU_INSTANCE.")
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

extension InstanceState {
    /// Stable lowercase name used in status JSON ("crashed" for any crash reason).
    var keyword: String {
        switch self {
        case .stopped: return "stopped"
        case .booting: return "booting"
        case .running: return "running"
        case .frozen: return "frozen"
        case .hibernating: return "hibernating"
        case .hibernated: return "hibernated"
        case .stopping: return "stopping"
        case .crashed: return "crashed"
        }
    }
}
