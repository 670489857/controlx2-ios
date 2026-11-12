import Foundation

/// 协议元数据注册表：按 (特征值, opCode) 查表，得到长度、是否签名、是否流式等。
/// 数据来自 pumpX2 的 @MessageProps 注解，由 Tools/generate_registry.py 生成。
public enum MessageRegistry {
    public struct Entry: Sendable {
        public let opCode: UInt8
        public let size: Int
        public let type: MessageType
        public let characteristic: Characteristic
        public let signed: Bool
        public let stream: Bool
        public let name: String

        public init(opCode: UInt8, size: Int, type: MessageType, characteristic: Characteristic,
                    signed: Bool, stream: Bool, name: String) {
            self.opCode = opCode
            self.size = size
            self.type = type
            self.characteristic = characteristic
            self.signed = signed
            self.stream = stream
            self.name = name
        }

        public var meta: MessageMeta {
            MessageMeta(opCode: opCode, size: size, type: type, characteristic: characteristic,
                        signed: signed, stream: stream)
        }
    }

    private static let index: [Key: Entry] = {
        var m: [Key: Entry] = [:]
        for e in generatedEntries { m[Key(characteristic: e.characteristic, opCode: e.opCode)] = e }
        return m
    }()

    struct Key: Hashable {
        let characteristic: Characteristic
        let opCode: UInt8
    }

    public static var count: Int { generatedEntries.count }

    public static func entry(_ opCode: UInt8, _ characteristic: Characteristic) -> Entry? {
        index[Key(characteristic: characteristic, opCode: opCode)]
    }

    public static func meta(_ opCode: UInt8, _ characteristic: Characteristic) -> MessageMeta {
        if let e = entry(opCode, characteristic) { return e.meta }
        // 未注册的报文退化为「未知长度」，由帧头决定
        return MessageMeta(opCode: opCode, size: 0, type: .response, characteristic: characteristic)
    }

    public static func name(_ opCode: UInt8, _ characteristic: Characteristic) -> String {
        entry(opCode, characteristic)?.name ?? String(format: "Unknown(0x%02X)", opCode)
    }
}
