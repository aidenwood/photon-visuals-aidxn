// OSC — Open Sound Control.
//
// The AV industry's lingua franca: TouchOSC, Lemur, lighting desks, QLab and
// most show-control software speak it. Supporting it means Photon drops into
// rigs that already exist rather than demanding its own control surface.
//
// Encoding and decoding live here, separate from the socket, so they can be
// tested against byte sequences. That split matters because OSC's bugs are all
// in the **alignment rules** — every element is padded to a 4-byte boundary,
// and getting that wrong produces messages that parse *almost* correctly.
//
// A parser that silently mis-aligns is worse than one that rejects: an operator
// sees a fader move the wrong parameter and has no way to tell why.

import Foundation
import Network

/// An OSC argument.
public enum OSCValue: Equatable, Sendable {
    case int32(Int32)
    case float32(Float)
    case string(String)
    case blob([UInt8])
    case bool(Bool)
    /// Present in the type tag but carrying no data.
    case null
    case impulse

    var tag: Character {
        switch self {
        case .int32: return "i"
        case .float32: return "f"
        case .string: return "s"
        case .blob: return "b"
        case .bool(let b): return b ? "T" : "F"
        case .null: return "N"
        case .impulse: return "I"
        }
    }

    /// Best-effort numeric reading, for binding to a parameter.
    public var asFloat: Float? {
        switch self {
        case .int32(let i): return Float(i)
        case .float32(let f): return f
        case .bool(let b): return b ? 1 : 0
        case .impulse: return 1
        case .string(let s): return Float(s)
        case .blob, .null: return nil
        }
    }
}

/// A decoded OSC message.
public struct OSCMessage: Equatable, Sendable {
    public var address: String
    public var values: [OSCValue]

    public init(address: String, values: [OSCValue] = []) {
        self.address = address
        self.values = values
    }

    /// First numeric argument, which is what a parameter binding wants.
    public var firstFloat: Float? { values.compactMap(\.asFloat).first }
}

public enum OSCError: Error, Equatable, CustomStringConvertible {
    case truncated
    case badAddress
    case missingTypeTag
    case unsupportedType(Character)

    public var description: String {
        switch self {
        case .truncated: return "packet ended mid-element"
        case .badAddress: return "address pattern must start with '/'"
        case .missingTypeTag: return "missing type tag string"
        case .unsupportedType(let c): return "unsupported OSC type '\(c)'"
        }
    }
}

/// OSC 1.0 encoding and decoding.
public enum OSC {
    /// Every OSC element is padded to a 4-byte boundary. This is the rule that
    /// everything else depends on, so it lives in one place.
    static func padded(_ n: Int) -> Int { (n + 3) & ~3 }

    // MARK: - Decode

    /// Decodes one message, or every message inside a bundle.
    public static func decode(_ bytes: [UInt8]) throws -> [OSCMessage] {
        guard !bytes.isEmpty else { throw OSCError.truncated }
        if bytes.starts(with: Array("#bundle".utf8)) {
            return try decodeBundle(bytes)
        }
        return [try decodeMessage(bytes)]
    }

    private static func decodeBundle(_ bytes: [UInt8]) throws -> [OSCMessage] {
        // "#bundle\0" (8) + timetag (8), then size-prefixed elements.
        var i = 16
        var out: [OSCMessage] = []
        while i + 4 <= bytes.count {
            let size = Int(readInt32(bytes, i))
            i += 4
            guard size >= 0, i + size <= bytes.count else { throw OSCError.truncated }
            out.append(contentsOf: try decode(Array(bytes[i..<(i + size)])))
            i += size
        }
        return out
    }

    private static func decodeMessage(_ bytes: [UInt8]) throws -> OSCMessage {
        var i = 0
        let address = try readString(bytes, &i)
        guard address.hasPrefix("/") else { throw OSCError.badAddress }

        // A message with no type tag is legal in OSC 1.0 but rare; treat a
        // missing tag as "no arguments" rather than failing, since some older
        // devices omit it.
        guard i < bytes.count else { return OSCMessage(address: address) }
        let tags = try readString(bytes, &i)
        guard tags.hasPrefix(",") else { throw OSCError.missingTypeTag }

        var values: [OSCValue] = []
        for tag in tags.dropFirst() {
            switch tag {
            case "i":
                guard i + 4 <= bytes.count else { throw OSCError.truncated }
                values.append(.int32(readInt32(bytes, i))); i += 4
            case "f":
                guard i + 4 <= bytes.count else { throw OSCError.truncated }
                values.append(.float32(Float(bitPattern: UInt32(bitPattern: readInt32(bytes, i)))))
                i += 4
            case "s":
                values.append(.string(try readString(bytes, &i)))
            case "b":
                guard i + 4 <= bytes.count else { throw OSCError.truncated }
                let n = Int(readInt32(bytes, i)); i += 4
                guard n >= 0, i + n <= bytes.count else { throw OSCError.truncated }
                values.append(.blob(Array(bytes[i..<(i + n)])))
                i += padded(n)
            case "T": values.append(.bool(true))
            case "F": values.append(.bool(false))
            case "N": values.append(.null)
            case "I": values.append(.impulse)
            default:
                throw OSCError.unsupportedType(tag)
            }
        }
        return OSCMessage(address: address, values: values)
    }

    private static func readInt32(_ b: [UInt8], _ i: Int) -> Int32 {
        // OSC is big-endian throughout.
        Int32(bitPattern:
            UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]))
    }

    private static func readString(_ b: [UInt8], _ i: inout Int) throws -> String {
        guard i < b.count else { throw OSCError.truncated }
        var end = i
        while end < b.count, b[end] != 0 { end += 1 }
        guard end < b.count else { throw OSCError.truncated }   // unterminated
        let s = String(decoding: b[i..<end], as: UTF8.self)
        i += padded(end - i + 1)
        return s
    }

    // MARK: - Encode

    /// Encodes a message to wire bytes.
    public static func encode(_ message: OSCMessage) -> [UInt8] {
        var out: [UInt8] = []
        appendString(&out, message.address)

        var tags = ","
        for v in message.values { tags.append(v.tag) }
        appendString(&out, tags)

        for v in message.values {
            switch v {
            case .int32(let i): appendInt32(&out, i)
            case .float32(let f): appendInt32(&out, Int32(bitPattern: f.bitPattern))
            case .string(let s): appendString(&out, s)
            case .blob(let b):
                appendInt32(&out, Int32(b.count))
                out.append(contentsOf: b)
                out.append(contentsOf: [UInt8](repeating: 0, count: padded(b.count) - b.count))
            case .bool, .null, .impulse:
                break   // carried entirely by the type tag
            }
        }
        return out
    }

    private static func appendInt32(_ out: inout [UInt8], _ v: Int32) {
        let u = UInt32(bitPattern: v)
        out.append(contentsOf: [
            UInt8((u >> 24) & 0xFF), UInt8((u >> 16) & 0xFF),
            UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF),
        ])
    }

    private static func appendString(_ out: inout [UInt8], _ s: String) {
        let bytes = Array(s.utf8)
        out.append(contentsOf: bytes)
        // At least one NUL, then pad to the 4-byte boundary.
        let total = padded(bytes.count + 1)
        out.append(contentsOf: [UInt8](repeating: 0, count: total - bytes.count))
    }
}

/// Receives OSC over UDP.
///
/// Fails soft like every other input: a port already in use costs OSC control,
/// never the show.
public final class OSCListener: @unchecked Sendable {
    private var listener: NWListener?
    private let lock = NSLock()
    private var pending: [OSCMessage] = []

    public private(set) var status: String = "stopped"
    public let port: UInt16

    public init(port: UInt16 = 7000) { self.port = port }

    @discardableResult
    public func start() -> Bool {
        guard listener == nil else { return true }
        guard let p = NWEndpoint.Port(rawValue: port) else {
            status = "invalid port"
            return false
        }
        do {
            let l = try NWListener(using: .udp, on: p)
            l.newConnectionHandler = { [weak self] conn in
                conn.start(queue: .global(qos: .utility))
                self?.receive(on: conn)
            }
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.status = "listening on \(p.rawValue)"
                case .failed(let e): self?.status = "failed: \(e.localizedDescription)"
                default: break
                }
            }
            l.start(queue: .global(qos: .utility))
            listener = l
            return true
        } catch {
            status = "could not listen on \(port): \(error.localizedDescription)"
            return false
        }
    }

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, _ in
            if let data, !data.isEmpty,
               let messages = try? OSC.decode([UInt8](data)) {
                self?.lock.withLock {
                    self?.pending.append(contentsOf: messages)
                    // Bounded, like MIDI: a chatty desk must not grow memory.
                    if let n = self?.pending.count, n > 512 {
                        self?.pending.removeFirst(n - 512)
                    }
                }
            }
            self?.receive(on: conn)
        }
    }

    /// Drains messages received since the last call.
    public func drain() -> [OSCMessage] {
        lock.withLock {
            let out = pending
            pending.removeAll(keepingCapacity: true)
            return out
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        status = "stopped"
    }
}
