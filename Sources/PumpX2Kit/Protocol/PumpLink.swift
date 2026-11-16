import Foundation

/// 传输抽象：把「写入一帧」与「收到一帧」从 BLE 实现中解耦，便于在无硬件时用 Mock 跑通会话逻辑。
public protocol PumpLink: AnyObject {
    /// 发送一帧已分片的 GATT 写包序列
    func write(_ packets: [[UInt8]], to characteristic: Characteristic) async throws
    /// 接收一帧（已重组、已校验 CRC）
    var frames: AsyncStream<AssembledFrame> { get }
    /// 配对完成后注入会话密钥，用于校验签名报文
    func updateAuthenticationKey(_ key: [UInt8]?)
    /// 往收发日志里写一条自由文本。
    ///
    /// 之前只有 GATT 收发会进日志，而解析失败、校验失败、状态机卡住都发生在报文
    /// 之后，日志里一片空白——现场只能看到「发了一条、回了一条、然后就没了」，
    /// 分不清是没解析、解析错、还是解析完没发下一条。
    func note(_ text: String)
}

public extension PumpLink {
    /// 默认空实现：Mock 与其他测试替身不必关心日志
    func note(_ text: String) {}
}

/// 无硬件环境下的回环实现：按注册表合成响应，用于跑通状态机与 UI。
public final class MockPumpLink: PumpLink {
    private let continuation: AsyncStream<AssembledFrame>.Continuation
    public let frames: AsyncStream<AssembledFrame>

    public init() {
        var c: AsyncStream<AssembledFrame>.Continuation!
        frames = AsyncStream { c = $0 }
        continuation = c
    }

    public func updateAuthenticationKey(_ key: [UInt8]?) {}

    public func write(_ packets: [[UInt8]], to characteristic: Characteristic) async throws {
        guard let first = packets.first, packets.count == 1 else { return }
        let opCode = first[2]
        let txId = first[3]
        // 仅实现只读类请求的最小回包
        switch opCode {
        case 0x36: // ApiVersionRequest
            continuation.yield(.init(opCode: 0x37, txId: txId, cargo: [0x01, 0x00, 0x03, 0x00],
                                     signed: false, hmacVerified: false))
        default:
            break
        }
    }
}
