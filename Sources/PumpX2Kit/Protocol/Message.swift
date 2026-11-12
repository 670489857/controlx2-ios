import Foundation

public enum MessageType: String, Sendable {
    case request, response
}

/// 对应 pumpX2 的 `@MessageProps`
public struct MessageMeta: Sendable, Equatable {
    public let opCode: UInt8
    public let size: Int
    public let type: MessageType
    public let characteristic: Characteristic
    public let signed: Bool
    public let stream: Bool
    public let variableSize: Bool

    public init(opCode: UInt8, size: Int, type: MessageType, characteristic: Characteristic,
                signed: Bool = false, stream: Bool = false, variableSize: Bool = false) {
        self.opCode = opCode
        self.size = size
        self.type = type
        self.characteristic = characteristic
        self.signed = signed
        self.stream = stream
        self.variableSize = variableSize
    }

    public var opCodeInt: Int { Int(Int8(bitPattern: opCode)) }
}

/// 一条协议消息：元数据 + 原始 cargo。
/// 具体字段的语义解析放在 `Messages/` 下的扩展里，未移植的消息保持 raw 形态。
public struct PumpMessage: Sendable {
    public let meta: MessageMeta
    public var cargo: [UInt8]

    public init(meta: MessageMeta, cargo: [UInt8]) {
        self.meta = meta
        self.cargo = cargo
    }

    public var opCode: UInt8 { meta.opCode }
    public var signed: Bool { meta.signed }
    public var characteristic: Characteristic { meta.characteristic }

    public static func request(characteristic: Characteristic, opCode: UInt8,
                               cargo: [UInt8] = [], signed: Bool = false) -> PumpMessage {
        PumpMessage(meta: MessageMeta(opCode: opCode, size: cargo.count, type: .request,
                                      characteristic: characteristic, signed: signed),
                    cargo: cargo)
    }
}

public enum ProtocolError: Error, Equatable {
    case unexpectedOpCode(found: UInt8, expected: UInt8)
    case unexpectedTransactionId(found: UInt8, expected: UInt8)
    case unexpectedCargoSize(found: Int, expected: Int)
    case invalidCRC
    case invalidSignature
    case truncated
    case emptyPacket
    case outOfOrderPacket(found: Int, expected: Int)
    case unregisteredMessage
    case notAuthenticated
}
