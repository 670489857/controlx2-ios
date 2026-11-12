import Foundation

/// 组包：opCode | txId | len | cargo [| timeSinceReset | hmac-sha1] | crc16，按 18/40 字节切片并逆序编号。
public enum Packetize {
    public static let defaultMaxChunk = 18
    public static let controlMaxChunk = 40

    public static func maxChunkSize(for message: PumpMessage) -> Int {
        if message.characteristic == .control && message.meta.type == .request {
            return controlMaxChunk
        }
        return defaultMaxChunk
    }

    /// 生成一串待写入 GATT 的字节数组（每个元素是一个 GATT 写包）
    public static func encode(_ message: PumpMessage,
                              txId: UInt8,
                              authKey: [UInt8] = [],
                              pumpTimeSinceReset: UInt32 = 0,
                              maxChunk: Int? = nil) throws -> [[UInt8]] {
        let chunk = maxChunk ?? maxChunkSize(for: message)
        precondition(chunk > 0)

        var header = 3 + message.cargo.count
        if message.signed { header += 24 }
        guard header <= 0xFF else { throw ProtocolError.unexpectedCargoSize(found: header, expected: 0xFF) }

        var frame: [UInt8] = [message.opCode, txId, UInt8(header - 3)] + message.cargo
        if message.signed { frame += [UInt8](repeating: 0, count: 24) }
        precondition(frame.count == header)

        if message.signed {
            guard !authKey.isEmpty else { throw ProtocolError.notAuthenticated }
            // 时间戳位于 hmac 之前，参与签名
            let time = ByteUtil.u32be(pumpTimeSinceReset)
            frame.replaceSubrange((header - 24)..<(header - 20), with: time)
            let signedData = Array(frame[0..<(header - 20)])
            let hmac = HMAC.sha1(key: authKey, message: signedData)
            frame.replaceSubrange((header - 20)..<header, with: hmac)
        }

        frame += CRC16.checksum(frame)

        var packets: [[UInt8]] = []
        var offset = 0
        var chunks: [[UInt8]] = []
        while offset < frame.count {
            let end = min(offset + chunk, frame.count)
            chunks.append(Array(frame[offset..<end]))
            offset = end
        }
        var remaining = chunks.count - 1
        for c in chunks {
            packets.append([UInt8(remaining), txId] + c)
            remaining -= 1
        }
        return packets
    }
}

public struct AssembledFrame: Sendable {
    public let opCode: UInt8
    public let txId: UInt8
    public let cargo: [UInt8]
    public let signed: Bool
    public let hmacVerified: Bool
}

/// 收包重组：把同一事务的多片 GATT 通知拼回一帧，并校验长度、CRC 与签名。
public final class PacketAssembler {
    /// 配对完成后由会话注入；用于校验签名报文并剥离 24 字节签名尾
    public var authKey: [UInt8]?
    private var buffer: [UInt8] = []
    private var expectedRemaining: Int?
    private var txId: UInt8?

    public init() {}

    public func reset() {
        buffer.removeAll()
        expectedRemaining = nil
        txId = nil
    }

    /// 喂入一个 GATT 通知包；拼完整时返回帧，否则返回 nil
    public func ingest(_ packet: [UInt8]) throws -> AssembledFrame? {
        guard packet.count > 2 else { throw ProtocolError.emptyPacket }
        let remaining = Int(packet[0] & 0x0F)
        let packetTxId = packet[1]

        if let expected = expectedRemaining {
            guard remaining == expected - 1 else {
                throw ProtocolError.outOfOrderPacket(found: remaining, expected: expected - 1)
            }
            guard packetTxId == txId else {
                throw ProtocolError.unexpectedTransactionId(found: packetTxId, expected: txId ?? 0)
            }
        } else {
            expectedRemaining = remaining
            txId = packetTxId
        }

        buffer += Array(packet.dropFirst(2))
        expectedRemaining = remaining

        if remaining == 0 {
            let frame = buffer
            reset()
            return try PacketAssembler.validate(frame: frame, authKey: authKey)
        }
        return nil
    }

    public static func validate(frame: [UInt8], authKey: [UInt8]? = nil) throws -> AssembledFrame {
        guard frame.count >= 5 else { throw ProtocolError.truncated }
        let opCode = frame[0]
        let txId = frame[1]
        let len = Int(frame[2])
        guard frame.count == len + 5 else { throw ProtocolError.truncated }

        let payload = Array(frame[0..<(len + 3)])
        let crc = Array(frame[(len + 3)..<(len + 5)])
        guard CRC16.checksum(payload) == crc else { throw ProtocolError.invalidCRC }

        var cargo = Array(frame[3..<(len + 3)])
        var signed = false
        var hmacOK = false

        if let key = authKey, cargo.count >= 24 {
            let signedPart = Array(payload.dropLast(20))
            let hmac = Array(payload.suffix(20))
            if ByteUtil.constantTimeEquals(HMAC.sha1(key: key, message: signedPart), hmac) {
                signed = true
                hmacOK = true
                cargo = Array(cargo.dropLast(24))
            }
        }
        return AssembledFrame(opCode: opCode, txId: txId, cargo: cargo, signed: signed, hmacVerified: hmacOK)
    }
}
