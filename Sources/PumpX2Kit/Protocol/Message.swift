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
    /// 同一 opCode 已有在途请求。并发发两个事务，泵会判定为并发认证并断链。
    case concurrentRequest(opCode: UInt8)
    /// JPAKE 某一轮失败。带上 opCode 与轮次，排障时不必再靠猜。
    case authStepFailed(step: Int, opCode: UInt8, reason: String)
}

extension ProtocolError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unexpectedOpCode(found, expected):
            return String(format: "报文类型不符：收到 0x%02x，期望 0x%02x", found, expected)
        case let .unexpectedTransactionId(found, expected):
            return "事务号不连续：收到 \(found)，期望 \(expected)"
        case let .unexpectedCargoSize(found, expected):
            return "报文体长度不符：\(found) 字节，期望 \(expected)"
        case .invalidCRC: return "报文校验和不通过"
        case .invalidSignature: return "报文签名不通过"
        case .truncated: return "报文不完整或等待回复超时"
        case .emptyPacket: return "收到空的数据包"
        case let .outOfOrderPacket(found, expected):
            return "报文分片乱序：收到第 \(found) 片，期望第 \(expected) 片"
        case .unregisteredMessage: return "收到未登记的报文类型"
        case .notAuthenticated: return "链路尚未认证，无法发送签名报文"
        case let .concurrentRequest(opCode):
            return String(format: "已有同类型请求在途（0x%02x），已阻止重复发送", opCode)
        case let .authStepFailed(step, opCode, reason):
            return String(format: "配对第 %d 步（0x%02x）失败：%@", step, opCode, reason)
        }
    }
}
