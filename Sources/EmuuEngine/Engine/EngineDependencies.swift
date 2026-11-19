import Foundation
import EmuuBase

/// Everything `EngineInstance` touches outside itself, injectable for tests.
public struct EngineDependencies: Sendable {
    public var runner: any ProcessRunner
    public var clock: any EmuuClock
    public var host: any HostProcessInspecting
    public var consoleConnector: any ConsoleConnector
    /// Console auth token; nil reads the file the console's greeting names.
    public var consoleToken: String?
    public var isPortFree: @Sendable (Int) -> Bool
    /// True if an engine holds `<avd>/multiinstance.lock`.
    public var isAVDLocked: @Sendable (URL) -> Bool

    public init(runner: any ProcessRunner = SystemProcessRunner(),
                clock: any EmuuClock = SystemClock(),
                host: any HostProcessInspecting = SystemHostProcesses(),
                consoleConnector: any ConsoleConnector = TCPConsoleConnector(),
                consoleToken: String? = nil,
                isPortFree: @escaping @Sendable (Int) -> Bool = { PortAllocator.isPortFree($0) },
                isAVDLocked: @escaping @Sendable (URL) -> Bool = { AVDLockProbe.isHeld(avdDirectory: $0) }) {
        self.runner = runner
        self.clock = clock
        self.host = host
        self.consoleConnector = consoleConnector
        self.consoleToken = consoleToken
        self.isPortFree = isPortFree
        self.isAVDLocked = isAVDLocked
    }

    public static func live() -> EngineDependencies { EngineDependencies() }
}

/// Poll intervals and timeouts. Defaults are for real engines; tests shrink them.
public struct EngineTimings: Sendable, Hashable {
    public var bootPollInterval: Duration = .seconds(1)
    /// Per-call limit for the `adb shell getprop` boot probe.
    public var adbProbeTimeout: Duration = .seconds(10)
    public var exitPollInterval: Duration = .milliseconds(100)
    /// After console `kill`: the engine saves the quick-boot snapshot (measured 1.0–1.6 s for a 2 GB guest)
    /// and exits. Beyond this, SIGTERM.
    public var gracefulExitTimeout: Duration = .seconds(90)
    /// After SIGTERM (which also saves), before SIGKILL.
    public var termGrace: Duration = .seconds(30)
    public var killGrace: Duration = .seconds(10)
    /// Liveness polling for engines adopted from another process.
    public var adoptedPollInterval: Duration = .seconds(2)
    /// How long to wait for the kernel to report a SIGSTOP/SIGCONT took effect.
    public var signalSettle: Duration = .seconds(2)

    public init() {}

    public static let `default` = EngineTimings()
}
