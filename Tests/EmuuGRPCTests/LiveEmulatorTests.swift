import Testing
import Foundation
@testable import EmuuGRPC

/// Opt-in: `EMUU_GRPC_PID=<qemu pid> swift test --filter LiveEmulatorTests` against a running engine started
/// with `-grpc <port> -grpc-use-token`. Read-only except for a no-op rotation round trip.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["EMUU_GRPC_PID"] != nil))
struct LiveEmulatorTests {
    let endpoint: EmulatorGRPCEndpoint = {
        let pid = Int32(ProcessInfo.processInfo.environment["EMUU_GRPC_PID"]!)!
        return EmulatorDiscovery.endpoint(forPID: pid)!
    }()

    @Test func statusAndScreenshot() async throws {
        let c = try EmulatorController(endpoint: endpoint)
        defer { c.close() }
        let s = try await c.status()
        #expect(s.version.hasPrefix("36."))
        let png = try await c.screenshot(EmulatorImageFormat(format: .png))
        #expect(png.image.starts(with: [0x89, 0x50, 0x4e, 0x47]))
        print("LIVE status \(s.version) booted=\(s.booted) png \(png.width)x\(png.height) \(png.image.count) B")
    }

    @Test func badTokenIsRejected() async throws {
        let c = try EmulatorController(endpoint: EmulatorGRPCEndpoint(port: endpoint.port, token: "wrong"))
        defer { c.close() }
        await #expect(throws: GRPCStatus.self) { _ = try await c.status() }
    }

    @Test func streamsIntoSharedMemory() async throws {
        let c = try EmulatorController(endpoint: endpoint)
        defer { c.close() }
        let side = 2048
        let region = try SharedMemoryRegion(size: side * side * 4)
        let got = Locked2<[EmulatorImage]>([])
        let handle = try c.streamScreenshots(EmulatorImageFormat(width: side, height: side, mmapHandle: region.name)) { img in
            got.with { $0.append(img) }
        } onEnd: { _ in }
        try await Task.sleep(for: .seconds(1))
        handle.cancel()
        let frames = got.with { $0 }
        #expect(!frames.isEmpty)
        let first = try #require(frames.first)
        #expect(first.image.isEmpty)
        var nonZero = 0
        for i in stride(from: 0, to: first.width * first.height * 4, by: 4099) where region.base.load(fromByteOffset: i, as: UInt8.self) != 0 { nonZero += 1 }
        #expect(nonZero > 10)
        print("LIVE mmap frames=\(frames.count) first=\(first.width)x\(first.height) rot=\(first.format.rotation) nonzero=\(nonZero)")
    }
}

final class Locked2<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    func with<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&v) }
}
