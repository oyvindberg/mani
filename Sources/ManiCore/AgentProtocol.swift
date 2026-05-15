import Foundation

// Wire protocol between Mani and the per-task `mani-agent` helper
// process. Both sides import this from ManiCore so frame layout
// stays in lockstep.
//
// Every frame: [1 byte type][4 bytes big-endian payload length][payload]
// Max payload: 64 KB. Larger PTY reads are split into multiple
// frames by the agent; bigger client writes get rejected.
//
// Why so minimal: the agent is a transparent byte pipe between the
// inner PTY's master FD and Mani's renderer. There's no terminal
// emulation, no capability negotiation, no acks. The only "smart"
// frames are RESIZE, EXIT, TERMINATE — control surface for the
// out-of-band PTY operations Mani needs.
public enum AgentFrameType: UInt8 {
    // Agent → client
    case output    = 0x01    // payload: raw bytes from the PTY master
    case exit      = 0x04    // payload: 4-byte BE Int32 exit code

    // Client → agent
    case input     = 0x02    // payload: bytes to write to PTY master
    case resize    = 0x03    // payload: [2 bytes rows BE][2 bytes cols BE]
    case terminate = 0x05    // payload: empty; agent SIGTERMs child + exits
}

public enum AgentProtocol {
    public static let maxPayloadSize = 64 * 1024

    // Encode a single frame ready for socket write.
    public static func encode(_ type: AgentFrameType, payload: Data) -> Data {
        var out = Data()
        out.append(type.rawValue)
        let len = UInt32(payload.count)
        out.append(UInt8((len >> 24) & 0xff))
        out.append(UInt8((len >> 16) & 0xff))
        out.append(UInt8((len >> 8) & 0xff))
        out.append(UInt8(len & 0xff))
        out.append(payload)
        return out
    }

    // Convenience encoders for the control frames.
    public static func resizeFrame(rows: UInt16, cols: UInt16) -> Data {
        var payload = Data(count: 4)
        payload[0] = UInt8((rows >> 8) & 0xff)
        payload[1] = UInt8(rows & 0xff)
        payload[2] = UInt8((cols >> 8) & 0xff)
        payload[3] = UInt8(cols & 0xff)
        return encode(.resize, payload: payload)
    }

    public static func exitFrame(code: Int32) -> Data {
        let u = UInt32(bitPattern: code)
        var payload = Data(count: 4)
        payload[0] = UInt8((u >> 24) & 0xff)
        payload[1] = UInt8((u >> 16) & 0xff)
        payload[2] = UInt8((u >> 8) & 0xff)
        payload[3] = UInt8(u & 0xff)
        return encode(.exit, payload: payload)
    }

    public static func decodeResize(_ payload: Data) -> (rows: UInt16, cols: UInt16)? {
        guard payload.count == 4 else { return nil }
        let bytes = [UInt8](payload)
        let rows = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        let cols = (UInt16(bytes[2]) << 8) | UInt16(bytes[3])
        return (rows, cols)
    }

    public static func decodeExit(_ payload: Data) -> Int32? {
        guard payload.count == 4 else { return nil }
        let bytes = [UInt8](payload)
        let u = (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | UInt32(bytes[3])
        return Int32(bitPattern: u)
    }
}

// Streaming decoder. Feed bytes as they arrive on the socket;
// completed frames pop out via `next()`. Holds a single buffer that
// grows up to one frame's worth + header.
//
// Internal buffer is [UInt8] (always 0-based) rather than Data —
// Data's indices DO NOT reset after removeFirst(), so absolute-
// offset subscripts crash with a runtime trap on the second frame.
// This bit us once in peekFirstLine; not repeating it here.
public final class AgentFrameDecoder {
    public struct Frame {
        public let type: AgentFrameType
        public let payload: Data
    }

    private var buffer: [UInt8] = []

    public init() {}

    public func append(_ data: Data) {
        buffer.append(contentsOf: data)
    }

    // Pop the next complete frame, or nil if no full frame is in the
    // buffer yet.
    public func next() -> Frame? {
        guard buffer.count >= 5 else { return nil }
        guard let type = AgentFrameType(rawValue: buffer[0]) else {
            // Unknown type — drop this byte and retry. Defensive
            // against a desynchronized stream; should never happen
            // in practice.
            buffer.removeFirst()
            return next()
        }
        let len = (UInt32(buffer[1]) << 24)
            | (UInt32(buffer[2]) << 16)
            | (UInt32(buffer[3]) << 8)
            | UInt32(buffer[4])
        let total = 5 + Int(len)
        guard buffer.count >= total else { return nil }
        let payload = Data(buffer[5..<total])
        buffer.removeFirst(total)
        return Frame(type: type, payload: payload)
    }
}
