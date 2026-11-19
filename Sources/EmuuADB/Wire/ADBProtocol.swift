import Foundation
import EmuuBase

/// Encoding helpers for the adb smart-socket protocol (client <-> adb server, see AOSP
/// `packages/modules/adb/SERVICES.TXT`, `SYNC.TXT`, `shell_protocol.h`).
///
/// - Requests are `<4 hex digits length><payload>`.
/// - Replies start with `OKAY`, or `FAIL<4 hex length><message>`.
/// - `host:*` queries that return data follow `OKAY` with `<4 hex length><data>`.
enum ADBWire {
    /// Max request payload: the length prefix is 4 hex digits.
    static let maxRequestLength = 0xFFFF

    static func request(_ service: String) throws -> Data {
        let payload = Data(service.utf8)
        guard payload.count <= maxRequestLength else {
            throw EmuuError.invalidConfiguration("adb request is \(payload.count) bytes; the protocol limit is \(maxRequestLength) (split the command)")
        }
        var out = Data(String(format: "%04x", payload.count).utf8)
        out.append(payload)
        return out
    }

    static func parseHexLength(_ data: Data) -> Int? {
        guard data.count == 4, let s = String(data: data, encoding: .ascii) else { return nil }
        return Int(s, radix: 16)
    }

    static func le32(_ v: UInt32) -> Data {
        withUnsafeBytes(of: v.littleEndian) { Data($0) }
    }

    static func readLE32(_ data: Data, at offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
    }

    /// Sync request/response packet: `<4-byte id><LE32 length or value><payload>`.
    static func syncPacket(_ id: String, _ payload: Data) -> Data {
        var out = Data(id.utf8)
        out.append(le32(UInt32(payload.count)))
        out.append(payload)
        return out
    }

    static func syncPacket(_ id: String, value: UInt32) -> Data {
        var out = Data(id.utf8)
        out.append(le32(value))
        return out
    }

    /// Max DATA payload per sync packet (SYNC_DATA_MAX).
    static let syncDataMax = 64 * 1024
}

/// Shell protocol v2 packet ids (`shell_protocol.h`).
enum ShellV2PacketID: UInt8 {
    case stdin = 0, stdout = 1, stderr = 2, exit = 3, closeStdin = 4, windowSizeChange = 5
}

extension ADBWire {
    static func shellV2Packet(_ id: ShellV2PacketID, _ payload: Data = Data()) -> Data {
        var out = Data([id.rawValue])
        out.append(le32(UInt32(payload.count)))
        out.append(payload)
        return out
    }
}

/// One line of `host:devices-l`.
public struct ADBDevice: Sendable, Hashable, Codable {
    public enum State: String, Sendable, Hashable, Codable {
        case device, offline, unauthorized, authorizing, connecting, bootloader, recovery, sideload, rescue, host
        case noPermissions = "no permissions"
        case unknown
    }

    public var serial: String
    public var state: State
    /// `product:`, `model:`, `device:`, `transport_id:` and any other `key:value` fields.
    public var properties: [String: String]

    public init(serial: String, state: State, properties: [String: String] = [:]) {
        self.serial = serial
        self.state = state
        self.properties = properties
    }

    public var model: String? { properties["model"] }
    public var transportID: Int? { properties["transport_id"].flatMap { Int($0) } }

    /// Parses `host:devices` / `host:devices-l` output. Tolerates the multi-word `no permissions` state.
    public static func parseList(_ text: String) -> [ADBDevice] {
        var result: [ADBDevice] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("List of devices") || line.hasPrefix("*") { continue }
            var tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard tokens.count >= 2 else { continue }
            let serial = tokens.removeFirst()
            var stateText = tokens.removeFirst()
            if stateText == "no", tokens.first == "permissions" {
                tokens.removeFirst()
                stateText = "no permissions"
                // drop the explanatory text adb appends in brackets/parentheses
                while let t = tokens.first, !t.contains(":") || t.hasPrefix("(") || t.hasPrefix("[") { tokens.removeFirst() }
            }
            var props: [String: String] = [:]
            for t in tokens {
                guard let colon = t.firstIndex(of: ":") else { continue }
                props[String(t[..<colon])] = String(t[t.index(after: colon)...])
            }
            result.append(ADBDevice(serial: serial, state: State(rawValue: stateText) ?? .unknown, properties: props))
        }
        return result
    }
}
