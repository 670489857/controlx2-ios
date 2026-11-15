import Foundation

/// 协议层收发记录。环形缓冲，只为排障存在。
///
/// 前三轮失败都停在"连不上/配对失败"这种笼统描述上，无法区分是报文没发出去、
/// 泵没回、还是回了个不相干的东西。有这份记录，一次导出就能定位到具体报文。
public final class ProtocolTrace: @unchecked Sendable {

    public enum Kind: String, Sendable {
        case tx = "TX"
        case rx = "RX"
        case note = "--"
    }

    public struct Entry: Sendable {
        public let at: Date
        public let kind: Kind
        public let text: String

        public var line: String {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return "\(f.string(from: at)) \(kind.rawValue) \(text)"
        }
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private let capacity: Int

    public init(capacity: Int = 600) {
        self.capacity = capacity
    }

    public func add(_ kind: Kind, _ text: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(Entry(at: Date(), kind: kind, text: text))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// 记录一个 GATT 包：分片头 + 帧体，十六进制。
    public func addPacket(_ kind: Kind, _ bytes: [UInt8], note: String? = nil) {
        var line = "\(bytes.count)B \(Self.hex(bytes))"
        if let note, !note.isEmpty { line += "  [\(note)]" }
        add(kind, line)
    }

    public func snapshot() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }

    public func dump() -> String {
        snapshot().map(\.line).joined(separator: "\n")
    }

    public static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
