import Foundation
import Darwin
import EmuuBase

/// In-process fake adb server speaking the smart-socket protocol on 127.0.0.1:<random port>.
/// Supports host:version, host:devices(-l), host-serial:<s>:features, host:transport:<s>, and on a
/// transport: shell,v2,raw:, exec:, sync: (SEND/RECV/STAT/QUIT).
final class FakeADBServer: @unchecked Sendable {
    struct ShellReply: Sendable {
        var stdout: String = ""
        var stderr: String = ""
        var exit: UInt8 = 0
        var delay: TimeInterval = 0
    }

    /// Connection given to exec handlers so they can read the stdin stream.
    final class Conn: @unchecked Sendable {
        let fd: Int32
        init(fd: Int32) { self.fd = fd }

        func readExactly(_ n: Int) -> Data? {
            var out = Data()
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            while out.count < n {
                let r = Darwin.read(fd, &buf, min(buf.count, n - out.count))
                if r <= 0 { return nil }
                out.append(contentsOf: buf[0..<r])
            }
            return out
        }

        func write(_ data: Data) {
            data.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let w = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                    if w <= 0 { return }
                    off += w
                }
            }
        }

        func write(_ s: String) { write(Data(s.utf8)) }
    }

    private struct State {
        var devices: [(serial: String, state: String)] = [("emulator-5580", "device")]
        var features = "shell_v2,cmd,stat_v2,abb_exec"
        var supportsShellV2 = true
        var supportsExec = true
        var shellHandler: (@Sendable (String) -> ShellReply)?
        var execHandler: (@Sendable (String, Conn) -> Data)?
        var files: [String: Data] = [:]
        var pushModes: [String: Int] = [:]
        var failPushPaths: Set<String> = []
        var requests: [String] = []
        var connections = 0
    }

    private let state = Locked(State())
    private let listenFD: Int32
    let port: UInt16
    private let stopped = Locked(false)

    init(port requested: UInt16 = 0) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = requested.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard rc == 0, listen(fd, 64) == 0 else {
            close(fd)
            throw EmuuError.io(path: "127.0.0.1:\(requested)", message: "bind/listen failed: \(String(cString: strerror(errno)))")
        }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        listenFD = fd
        port = UInt16(bigEndian: bound.sin_port)
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.start()
    }

    deinit { stop() }

    func stop() {
        let was = stopped.withLock { s -> Bool in defer { s = true }; return s }
        if !was {
            Darwin.shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
        }
    }

    // MARK: Configuration

    func setDevices(_ devices: [(String, String)]) { state.withLock { $0.devices = devices.map { (serial: $0.0, state: $0.1) } } }
    func setShellV2Supported(_ v: Bool) { state.withLock { $0.supportsShellV2 = v } }
    func setExecSupported(_ v: Bool) { state.withLock { $0.supportsExec = v } }
    func onShell(_ handler: @escaping @Sendable (String) -> ShellReply) { state.withLock { $0.shellHandler = handler } }
    func onExec(_ handler: @escaping @Sendable (String, Conn) -> Data) { state.withLock { $0.execHandler = handler } }
    func setFile(_ path: String, _ data: Data) { state.withLock { $0.files[path] = data } }
    func failPush(to path: String) { state.withLock { _ = $0.failPushPaths.insert(path) } }

    var files: [String: Data] { state.withLock { $0.files } }
    var pushModes: [String: Int] { state.withLock { $0.pushModes } }
    var requests: [String] { state.withLock { $0.requests } }
    var connectionCount: Int { state.withLock { $0.connections } }

    // MARK: Server loop

    private func acceptLoop() {
        while !stopped.current {
            let c = accept(listenFD, nil, nil)
            if c < 0 { if stopped.current { return } else { continue } }
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            state.withLock { $0.connections += 1 }
            let t = Thread { [self] in
                handle(Conn(fd: c))
                close(c)
            }
            t.start()
        }
    }

    private func readRequest(_ conn: Conn) -> String? {
        guard let lenData = conn.readExactly(4), let len = Int(String(decoding: lenData, as: UTF8.self), radix: 16),
              let payload = conn.readExactly(len) else { return nil }
        let s = String(decoding: payload, as: UTF8.self)
        state.withLock { $0.requests.append(s) }
        return s
    }

    private func okay(_ conn: Conn) { conn.write("OKAY") }

    private func fail(_ conn: Conn, _ message: String) {
        conn.write("FAIL" + String(format: "%04x", message.utf8.count) + message)
    }

    private func okayWithPayload(_ conn: Conn, _ s: String) {
        conn.write("OKAY" + String(format: "%04x", s.utf8.count) + s)
    }

    private func handle(_ conn: Conn) {
        var transportSerial: String?
        while let req = readRequest(conn) {
            let snapshot = state.current
            if transportSerial == nil {
                if req == "host:version" { okayWithPayload(conn, "0029"); return }
                if req == "host:devices-l" || req == "host:devices" {
                    let text = snapshot.devices.map { "\($0.serial)\t\($0.state) product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1\n" }.joined()
                    okayWithPayload(conn, text)
                    return
                }
                if req.hasPrefix("host-serial:"), req.hasSuffix(":features") {
                    let serial = String(req.dropFirst("host-serial:".count).dropLast(":features".count))
                    if snapshot.devices.contains(where: { $0.serial == serial }) { okayWithPayload(conn, snapshot.features) }
                    else { fail(conn, "device '\(serial)' not found") }
                    return
                }
                if req.hasPrefix("host:transport:") {
                    let serial = String(req.dropFirst("host:transport:".count))
                    guard let dev = snapshot.devices.first(where: { $0.serial == serial }) else {
                        fail(conn, "device '\(serial)' not found"); return
                    }
                    if dev.state != "device" { fail(conn, "device \(dev.state)"); return }
                    okay(conn)
                    transportSerial = serial
                    continue
                }
                fail(conn, "unknown host service"); return
            }
            // Device services
            if req.hasPrefix("shell,v2,raw:") {
                guard snapshot.supportsShellV2 else { fail(conn, "unknown service shell,v2"); return }
                okay(conn)
                // Client sends CLOSE_STDIN first.
                guard let hdr = conn.readExactly(5) else { return }
                let len = Int(hdr[1]) | Int(hdr[2]) << 8 | Int(hdr[3]) << 16 | Int(hdr[4]) << 24
                if len > 0 { _ = conn.readExactly(len) }
                let cmd = String(req.dropFirst("shell,v2,raw:".count))
                let reply = snapshot.shellHandler?(cmd) ?? ShellReply(stderr: "/system/bin/sh: \(cmd): inaccessible or not found\n", exit: 127)
                if reply.delay > 0 { Thread.sleep(forTimeInterval: reply.delay) }
                if !reply.stdout.isEmpty { conn.write(packet(1, Data(reply.stdout.utf8))) }
                if !reply.stderr.isEmpty { conn.write(packet(2, Data(reply.stderr.utf8))) }
                conn.write(packet(3, Data([reply.exit])))
                return
            }
            if req.hasPrefix("exec:") {
                guard snapshot.supportsExec else { fail(conn, "unknown service exec"); return }
                okay(conn)
                let cmd = String(req.dropFirst(5))
                let out = snapshot.execHandler?(cmd, conn) ?? Data()
                conn.write(out)
                return
            }
            if req == "sync:" {
                okay(conn)
                handleSync(conn)
                return
            }
            fail(conn, "unknown service"); return
        }
    }

    private func packet(_ id: UInt8, _ payload: Data) -> Data {
        var d = Data([id])
        var len = UInt32(payload.count).littleEndian
        d.append(Data(bytes: &len, count: 4))
        d.append(payload)
        return d
    }

    private func le32(_ v: UInt32) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 4) }

    private func handleSync(_ conn: Conn) {
        while let hdr = conn.readExactly(8) {
            let id = String(decoding: hdr.prefix(4), as: UTF8.self)
            let len = Int(hdr[4]) | Int(hdr[5]) << 8 | Int(hdr[6]) << 16 | Int(hdr[7]) << 24
            switch id {
            case "SEND":
                guard let spec = conn.readExactly(len) else { return }
                let s = String(decoding: spec, as: UTF8.self)
                let comma = s.lastIndex(of: ",")!
                let path = String(s[..<comma])
                let mode = Int(s[s.index(after: comma)...]) ?? 0
                var content = Data()
                while let h = conn.readExactly(8) {
                    let pid = String(decoding: h.prefix(4), as: UTF8.self)
                    let plen = Int(h[4]) | Int(h[5]) << 8 | Int(h[6]) << 16 | Int(h[7]) << 24
                    if pid == "DATA" {
                        guard let d = conn.readExactly(plen) else { return }
                        content.append(d)
                    } else if pid == "DONE" {
                        break
                    } else { return }
                }
                if state.current.failPushPaths.contains(path) {
                    let msg = "No space left on device"
                    conn.write(Data("FAIL".utf8) + le32(UInt32(msg.utf8.count)) + Data(msg.utf8))
                } else {
                    state.withLock { $0.files[path] = content; $0.pushModes[path] = mode }
                    conn.write(Data("OKAY".utf8) + le32(0))
                }
            case "STAT":
                guard let p = conn.readExactly(len) else { return }
                let path = String(decoding: p, as: UTF8.self)
                if let data = state.current.files[path] {
                    conn.write(Data("STAT".utf8) + le32(0o100644) + le32(UInt32(data.count)) + le32(1_700_000_000))
                } else {
                    conn.write(Data("STAT".utf8) + le32(0) + le32(0) + le32(0))
                }
            case "RECV":
                guard let p = conn.readExactly(len) else { return }
                let path = String(decoding: p, as: UTF8.self)
                guard let data = state.current.files[path] else {
                    let msg = "remote object '\(path)' does not exist"
                    conn.write(Data("FAIL".utf8) + le32(UInt32(msg.utf8.count)) + Data(msg.utf8))
                    continue
                }
                var off = 0
                while off < data.count {
                    let chunk = data[data.startIndex + off ..< data.startIndex + min(data.count, off + 65536)]
                    conn.write(Data("DATA".utf8) + le32(UInt32(chunk.count)) + Data(chunk))
                    off += chunk.count
                }
                conn.write(Data("DONE".utf8) + le32(0))
            case "QUIT":
                return
            default:
                return
            }
        }
    }
}
