import Foundation
import Darwin
import EmuuBase

/// Footprint/CPU of the engine process tree (QEMU pid and its descendants).
public struct EngineProcessStats: Codable, Sendable, Hashable {
    public var pid: Int32
    /// Number of processes summed (engine + descendants that could be read).
    public var processCount: Int
    /// Sum of `ri_phys_footprint` (Activity Monitor "Memory").
    public var footprintBytes: UInt64
    /// Max over the tree of `ri_lifetime_max_phys_footprint` (peak since process start).
    public var lifetimeMaxFootprintBytes: UInt64
    public var residentBytes: UInt64
    /// user+system CPU seconds since start, summed over the tree.
    public var cpuSeconds: Double
    /// CPU utilisation since the previous sample, in percent of one core (nil on first sample).
    public var cpuPercent: Double?
}

/// Whole-Mac memory figures.
public struct HostSystemStats: Codable, Sendable, Hashable {
    public var physicalBytes: UInt64
    public var freeBytes: UInt64
    /// Physical memory occupied by the compressor.
    public var compressedBytes: UInt64
    public var swapUsedBytes: UInt64
    public var swapTotalBytes: UInt64
    /// Raw `kern.memorystatus_vm_pressure_level` (1 normal, 2 warning, 4 critical), if readable.
    public var kernelPressureLevel: Int32?
    public var pressure: MemoryPressureLevel
}

public struct HostSnapshot: Sendable, Hashable {
    public var engine: EngineProcessStats?
    public var system: HostSystemStats

    public init(engine: EngineProcessStats?, system: HostSystemStats) {
        self.engine = engine
        self.system = system
    }

    /// The shared-contract view.
    public var hostMemory: HostMemory {
        HostMemory(engineFootprintBytes: engine?.footprintBytes, engineResidentBytes: engine?.residentBytes,
                   systemPressure: system.pressure, physicalMemoryBytes: system.physicalBytes)
    }
}

public protocol HostMemorySampling: Sendable {
    /// Samples the engine tree rooted at `enginePID` (nil = system stats only).
    func sample(enginePID: Int32?) -> HostSnapshot
}

/// Real host sampler: `proc_pid_rusage(RUSAGE_INFO_V4)` over the engine process tree,
/// `host_statistics64(HOST_VM_INFO64)`, `vm.swapusage` and `kern.memorystatus_vm_pressure_level`.
/// All calls are cheap syscalls (microseconds); no subprocesses.
public final class HostSampler: HostMemorySampling, @unchecked Sendable {
    private struct Previous { var pid: Int32; var cpu: Double; var at: Duration }
    private let previous = Locked<Previous?>(nil)
    private let clock: any EmuuClock
    /// Overrides the system pressure (e.g. from `HostPressureMonitor`) when it is higher than the sysctl value.
    private let pressureHint: (@Sendable () -> MemoryPressureLevel?)?

    public init(clock: any EmuuClock = SystemClock(), pressureHint: (@Sendable () -> MemoryPressureLevel?)? = nil) {
        self.clock = clock
        self.pressureHint = pressureHint
    }

    public func sample(enginePID: Int32?) -> HostSnapshot {
        var system = Self.systemStats()
        if let hint = pressureHint?(), hint > system.pressure { system.pressure = hint }
        guard let pid = enginePID, var stats = Self.processTreeStats(root: pid) else {
            return HostSnapshot(engine: nil, system: system)
        }
        let now = clock.monotonicNow()
        stats.cpuPercent = previous.withLock { prev -> Double? in
            defer { prev = Previous(pid: pid, cpu: stats.cpuSeconds, at: now) }
            guard let p = prev, p.pid == pid else { return nil }
            let dt = (now - p.at).timeInterval
            guard dt > 0, stats.cpuSeconds >= p.cpu else { return nil }
            return (stats.cpuSeconds - p.cpu) / dt * 100
        }
        return HostSnapshot(engine: stats, system: system)
    }

    // MARK: process tree

    private static let timebase: (numer: UInt32, denom: UInt32) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (info.numer, max(1, info.denom))
    }()

    /// rusage for one pid, or nil if it cannot be read (gone, or not ours).
    public static func rusage(pid: Int32) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return rc == 0 ? info : nil
    }

    /// Direct children of `pid`.
    public static func childPIDs(of pid: Int32) -> [Int32] {
        var buf = [Int32](repeating: 0, count: 64)
        while true {
            let bytes = Int32(buf.count * MemoryLayout<Int32>.size)
            let n = buf.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, bytes) }
            if n <= 0 { return [] }
            // proc_listchildpids returns the number of pids; if the buffer is full, grow and retry.
            if Int(n) < buf.count { return Array(buf.prefix(Int(n))).filter { $0 > 0 } }
            if buf.count >= 4096 { return Array(buf.prefix(Int(n))).filter { $0 > 0 } }
            buf = [Int32](repeating: 0, count: buf.count * 4)
        }
    }

    /// Footprint/CPU summed over `root` and its descendants (bounded to 256 processes).
    public static func processTreeStats(root: Int32) -> EngineProcessStats? {
        guard let rootInfo = rusage(pid: root) else { return nil }
        var stats = EngineProcessStats(pid: root, processCount: 0, footprintBytes: 0, lifetimeMaxFootprintBytes: 0,
                                       residentBytes: 0, cpuSeconds: 0, cpuPercent: nil)
        func add(_ i: rusage_info_v4) {
            stats.processCount += 1
            stats.footprintBytes &+= i.ri_phys_footprint
            stats.lifetimeMaxFootprintBytes = max(stats.lifetimeMaxFootprintBytes, i.ri_lifetime_max_phys_footprint)
            stats.residentBytes &+= i.ri_resident_size
            let ticks = Double(i.ri_user_time) + Double(i.ri_system_time)
            stats.cpuSeconds += ticks * Double(timebase.numer) / Double(timebase.denom) / 1e9
        }
        add(rootInfo)
        var queue = childPIDs(of: root)
        var visited: Set<Int32> = [root]
        while let pid = queue.popLast(), visited.count < 256 {
            guard visited.insert(pid).inserted else { continue }
            if let info = rusage(pid: pid) { add(info) }
            queue.append(contentsOf: childPIDs(of: pid))
        }
        return stats
    }

    // MARK: system

    public static func systemStats() -> HostSystemStats {
        let physical = ProcessInfo.processInfo.physicalMemory
        let page = UInt64(getpagesize())
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let free = kr == KERN_SUCCESS ? UInt64(vm.free_count) * page : 0
        let compressed = kr == KERN_SUCCESS ? UInt64(vm.compressor_page_count) * page : 0

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapOK = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0

        let kernelLevel = sysctlInt32("kern.memorystatus_vm_pressure_level")
        return HostSystemStats(
            physicalBytes: physical, freeBytes: free, compressedBytes: compressed,
            swapUsedBytes: swapOK ? swap.xsu_used : 0, swapTotalBytes: swapOK ? swap.xsu_total : 0,
            kernelPressureLevel: kernelLevel, pressure: pressureLevel(kernelLevel: kernelLevel)
        )
    }

    /// Maps the kernel's level: 1 normal, 2 warning → `.high`, 4 critical → `.critical`.
    public static func pressureLevel(kernelLevel: Int32?) -> MemoryPressureLevel {
        switch kernelLevel {
        case 4?: return .critical
        case 2?: return .high
        default: return .normal
        }
    }

    static func sysctlInt32(_ name: String) -> Int32? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? v : nil
    }
}

/// Push notifications of macOS memory pressure changes (`DispatchSource.makeMemoryPressureSource`).
/// Keeps the latest level so `HostSampler(pressureHint:)` can use it, and calls `onChange` on each event.
public final class HostPressureMonitor: @unchecked Sendable {
    private let source: DispatchSourceMemoryPressure
    private let level = Locked<MemoryPressureLevel?>(nil)
    private let handler = Locked<(@Sendable (MemoryPressureLevel) -> Void)?>(nil)

    public init(queue: DispatchQueue = DispatchQueue(label: "dev.emuu.memory.pressure")) {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let ev = self.source.data
            let l: MemoryPressureLevel = ev.contains(.critical) ? .critical : ev.contains(.warning) ? .high : .normal
            self.level.set(l)
            self.handler.current?(l)
        }
        source.activate()
    }

    deinit { source.cancel() }

    /// Last level delivered by the kernel (nil until the first transition).
    public var latest: MemoryPressureLevel? { level.current }

    public func onChange(_ body: @escaping @Sendable (MemoryPressureLevel) -> Void) { handler.set(body) }
}
