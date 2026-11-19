import Foundation
import EmuuBase

/// What one farm device costs the host, for a given profile. Values come from measurements on the development
/// Mac (docs/BENCHMARKS.md, "Farm"); `perDeviceBytes` is the *real* memory cost (the rise of the Mac's
/// anonymous + wired + compressor pages when one more engine runs a test loop), not the engine's
/// `phys_footprint`: the kernel ledger charges the guest RAM twice (the QEMU mapping plus the Hypervisor.framework
/// stage-2 mapping of the same pages), so `phys_footprint` ≈ 2 × guest RAM + overhead while the Mac only loses
/// ≈ 1 × guest RAM + overhead.
public struct DeviceCost: Codable, Sendable, Hashable {
    public var guestRAMMB: Int
    public var cores: Int
    /// Real host memory per device, steady state under a test loop (bytes).
    public var perDeviceBytes: UInt64
    /// Engine `phys_footprint` per device (bytes), for reference: Activity Monitor shows this number.
    public var footprintBytes: UInt64
    /// Disk written per device beyond the shared clone blocks after a typical test session (bytes).
    public var diskBytes: UInt64

    public init(guestRAMMB: Int, cores: Int, perDeviceBytes: UInt64, footprintBytes: UInt64, diskBytes: UInt64) {
        self.guestRAMMB = guestRAMMB
        self.cores = cores
        self.perDeviceBytes = perDeviceBytes
        self.footprintBytes = footprintBytes
        self.diskBytes = diskBytes
    }

    /// Estimate for a guest size that was not measured: guest RAM + the measured engine overhead.
    public static func estimate(guestRAMMB: Int, cores: Int) -> DeviceCost {
        let mib = UInt64(1 << 20)
        return DeviceCost(guestRAMMB: guestRAMMB, cores: cores,
                          perDeviceBytes: UInt64(guestRAMMB) * mib + engineOverheadBytes,
                          footprintBytes: UInt64(guestRAMMB) * 2 * mib + 400 * mib,
                          diskBytes: 600 * mib)
    }

    /// Engine + gfxstream + MoltenVK beyond guest RAM: measured real cost (footprint(1)) minus guest RAM after a
    /// 10-minute test loop was 780–810 MiB for both 2048 and 1536 MB guests (docs/BENCHMARKS.md); rounded up.
    public static let engineOverheadBytes: UInt64 = 850 << 20
}

/// The host as the capacity guard sees it.
public struct HostFacts: Codable, Sendable, Hashable {
    public var physicalMemoryBytes: UInt64
    /// Logical CPUs (`hw.logicalcpu`).
    public var cpuCores: Int
    /// macOS's own estimate of available memory (`kern.memorystatus_level` %, the "System-wide memory free
    /// percentage" of `memory_pressure`) × physical memory.
    public var availableBytes: UInt64?
    public var pressure: MemoryPressureLevel

    public init(physicalMemoryBytes: UInt64, cpuCores: Int, availableBytes: UInt64?, pressure: MemoryPressureLevel) {
        self.physicalMemoryBytes = physicalMemoryBytes
        self.cpuCores = cpuCores
        self.availableBytes = availableBytes
        self.pressure = pressure
    }

    /// Reads the live host (sysctl only).
    public static func current() -> HostFacts {
        func int(_ name: String) -> Int64? {
            var v: Int64 = 0
            var size = MemoryLayout<Int64>.size
            guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
            return size == 4 ? Int64(Int32(truncatingIfNeeded: v)) : v
        }
        let phys = ProcessInfo.processInfo.physicalMemory
        let level = int("kern.memorystatus_level").map { UInt64(max(0, min(100, $0))) }
        let pressure: MemoryPressureLevel
        switch int("kern.memorystatus_vm_pressure_level") ?? 1 {
        case 4: pressure = .critical
        case 2: pressure = .high
        default: pressure = .normal
        }
        return HostFacts(physicalMemoryBytes: phys, cpuCores: Int(int("hw.logicalcpu") ?? 8),
                         availableBytes: level.map { phys / 100 * $0 }, pressure: pressure)
    }
}

/// How many farm devices this host can run: a static ceiling from RAM, CPU and ports, and a live admission
/// check from macOS's current memory state. Pure; the formula is documented in docs/BENCHMARKS.md.
///
///     reserve      = max(minimumReserve, reserveFraction × physical RAM)      (macOS + the user's apps)
///     byMemory     = ⌊(physical RAM − reserve) / perDeviceBytes⌋
///     byCPU        = ⌊host logical cores × cpuOvercommit / cores per device⌋
///     byPorts      = 16 (console ports 5554…5584: adb's automatic emulator scan range)
///     ceiling      = min(byMemory, byCPU, byPorts)
///
/// Admission of one more device additionally needs macOS pressure `normal` and
/// `available − perDeviceBytes ≥ admissionFloorFraction × physical RAM`.
public struct CapacityPolicy: Codable, Sendable, Hashable {
    public var minimumReserveBytes: UInt64 = 8 << 30
    public var reserveFraction: Double = 0.40
    public var cpuOvercommit: Double = 1.0
    public var admissionFloorFraction: Double = 0.10

    public init() {}

    public static let `default` = CapacityPolicy()

    public func reserveBytes(physical: UInt64) -> UInt64 {
        max(minimumReserveBytes, UInt64(Double(physical) * reserveFraction))
    }
}

public struct CapacityReport: Codable, Sendable, Hashable {
    public var ceiling: Int
    public var byMemory: Int
    public var byCPU: Int
    public var byPorts: Int
    /// The factor that sets the ceiling: "memory", "cpu" or "ports".
    public var limitedBy: String
    public var reserveBytes: UInt64
    public var perDeviceBytes: UInt64
    public var physicalMemoryBytes: UInt64
    public var cpuCores: Int
    public var coresPerDevice: Int
    /// Live: may one more device start now (given `running` devices)? With the reason when not.
    public var admitNow: Bool
    public var admitReason: String
    public var availableBytes: UInt64?
    public var pressure: MemoryPressureLevel
}

public enum CapacityGuard {
    public static let maxDevicesByPorts = FarmPorts.consolePorts.count

    public static func evaluate(host: HostFacts, cost: DeviceCost, running: Int = 0,
                                policy: CapacityPolicy = .default) -> CapacityReport {
        let reserve = policy.reserveBytes(physical: host.physicalMemoryBytes)
        let usable = host.physicalMemoryBytes > reserve ? host.physicalMemoryBytes - reserve : 0
        let byMemory = cost.perDeviceBytes == 0 ? 0 : Int(usable / cost.perDeviceBytes)
        let byCPU = Int((Double(host.cpuCores) * policy.cpuOvercommit / Double(max(1, cost.cores))).rounded(.down))
        let byPorts = maxDevicesByPorts
        let ceiling = max(0, min(byMemory, byCPU, byPorts))
        let limitedBy = ceiling == byMemory ? "memory" : ceiling == byCPU ? "cpu" : "ports"
        var admit = true
        var reason = "ok"
        if running >= ceiling {
            admit = false
            reason = "at capacity: \(running) of \(ceiling) devices (limited by \(limitedBy))"
        } else if host.pressure != .normal {
            admit = false
            reason = "macOS memory pressure is \(host.pressure)"
        } else if let avail = host.availableBytes {
            let floor = UInt64(Double(host.physicalMemoryBytes) * policy.admissionFloorFraction)
            if avail < cost.perDeviceBytes + floor {
                admit = false
                reason = "only \(ByteCount.format(avail)) available; one device needs \(ByteCount.format(cost.perDeviceBytes)) + \(ByteCount.format(floor)) floor"
            }
        }
        return CapacityReport(ceiling: ceiling, byMemory: byMemory, byCPU: byCPU, byPorts: byPorts, limitedBy: limitedBy,
                              reserveBytes: reserve, perDeviceBytes: cost.perDeviceBytes,
                              physicalMemoryBytes: host.physicalMemoryBytes, cpuCores: host.cpuCores, coresPerDevice: cost.cores,
                              admitNow: admit, admitReason: reason, availableBytes: host.availableBytes, pressure: host.pressure)
    }
}
