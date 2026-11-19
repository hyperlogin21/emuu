import Foundation
import Darwin
import CEmuuShim

/// A POSIX shared-memory region (`shm_open` + `mmap`) the emulator writes frames into
/// (`ImageTransport.MMAP` with the region's name as the handle). Anonymous memory: nothing is written to
/// disk (a `file://` handle would make the kernel flush every frame to a file).
///
/// The name is unlinked again in `deinit`; macOS keeps the memory alive for as long as either side has it
/// mapped. Names are ≤ 31 characters (`PSHMNAMLEN`).
public final class SharedMemoryRegion: @unchecked Sendable {
    public let name: String
    public let size: Int
    public let base: UnsafeMutableRawPointer
    private let fd: Int32

    public init(size: Int, name: String? = nil) throws {
        let name = name ?? Self.uniqueName()
        precondition(name.utf8.count <= 31, "shm names are limited to 31 bytes on macOS")
        let fd = emuu_shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw SharedMemoryError.failed("shm_open(\(name)): \(String(cString: strerror(errno)))") }
        guard ftruncate(fd, off_t(size)) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            shm_unlink(name)
            throw SharedMemoryError.failed("ftruncate: \(message)")
        }
        let p = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard let p, p != MAP_FAILED else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            shm_unlink(name)
            throw SharedMemoryError.failed("mmap: \(message)")
        }
        self.name = name
        self.size = size
        self.base = p
        self.fd = fd
    }

    deinit {
        munmap(base, size)
        Darwin.close(fd)
        shm_unlink(name)
    }

    /// `/emuu-<pid>-<counter>` (unique per process and region).
    static func uniqueName() -> String {
        let n = counter.withLock { c -> Int in c += 1; return c }
        return "/emuu-\(getpid())-\(n)"
    }

    private static let counter = LockedCounter()
}

public enum SharedMemoryError: Error, CustomStringConvertible, Sendable {
    case failed(String)
    public var description: String { if case .failed(let m) = self { return m } else { return "" } }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func withLock<R>(_ body: (inout Int) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
