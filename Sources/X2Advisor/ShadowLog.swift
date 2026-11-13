import Foundation

/// 影子模式下的一条记录。
///
/// 影子模式是这套东西的默认工作方式：每个周期算一次"如果自动，此刻会给多少"，
/// 但**一条指令都不发**，只把结论落盘。
///
/// 这不是缩水的实现，而是 t:slim X2 上唯一诚实的验证方式。原因是这台泵
/// 没有远程暂停（`SuspendPumpingRequest` 是 MOBI_ONLY），一旦自动发出的胰岛素
/// 是错的，没有任何软件手段可以收回。所以先用两周影子数据回答两个问题：
///
/// 1. 建议的频率和剂量是否符合预期，有没有出现明显违背常识的抖动
/// 2. 如果当时真的给了，血糖会怎么走（用后续真实 CGM 回看）
///
/// 这两条过了，才有讨论"要不要打开自动"的资格。
public struct ShadowRecord: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let bg: Int
    public let trendCode: Int?
    public let iob: Double
    public let carbsOnBoard: Double
    /// 预测稳态血糖
    public let eventualBg: Double
    /// 建议剂量，0 表示 hold
    public let suggestedUnits: Double
    /// hold 原因；给了剂量时为 nil
    public let holdReason: String?
    /// 是否被单次上限截断
    public let capped: Bool

    public init(timestamp: Date, bg: Int, trendCode: Int?, iob: Double,
                carbsOnBoard: Double, eventualBg: Double,
                suggestedUnits: Double, holdReason: String?, capped: Bool) {
        self.timestamp = timestamp
        self.bg = bg
        self.trendCode = trendCode
        self.iob = iob
        self.carbsOnBoard = carbsOnBoard
        self.eventualBg = eventualBg
        self.suggestedUnits = suggestedUnits
        self.holdReason = holdReason
        self.capped = capped
    }
}

/// 追加式记录。用 JSONL 而不是单个 JSON 数组：一次崩溃最多损坏最后一行，
/// 前面几百条仍然可读，这对"要连续跑两周"的数据集是必要的。
public final class ShadowLog: @unchecked Sendable {

    private let fileURL: URL?
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        self.encoder = e
        decoder.dateDecodingStrategy = .iso8601
    }

    public func append(_ record: ShadowRecord) {
        guard let url = fileURL, let data = try? encoder.encode(record) else { return }
        lock.lock(); defer { lock.unlock() }
        var line = data
        line.append(0x0A)  // '\n'
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    /// 读回全部记录。坏行跳过而不是整体失败——这正是选 JSONL 的原因。
    public func readAll() -> [ShadowRecord] {
        guard let url = fileURL,
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(ShadowRecord.self, from: data)
        }
    }

    /// 清空记录。只在用户明确要求时调用。
    public func reset() {
        guard let url = fileURL else { return }
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }

    /// 导出 CSV，便于在 Excel 里核对，或交给医生看
    public func exportCSV() -> String {
        var out = "timestamp,bg,trend,iob,cob,eventualBg,suggestedUnits,holdReason,capped\n"
        let iso = ISO8601DateFormatter()
        for r in readAll() {
            let fields = [
                iso.string(from: r.timestamp),
                String(r.bg),
                r.trendCode.map(String.init) ?? "",
                String(format: "%.3f", r.iob),
                String(format: "%.1f", r.carbsOnBoard),
                String(format: "%.1f", r.eventualBg),
                String(format: "%.2f", r.suggestedUnits),
                r.holdReason ?? "",
                r.capped ? "1" : "0",
            ]
            out += fields.joined(separator: ",") + "\n"
        }
        return out
    }

    /// 统计摘要，用来快速判断建议是否"太吵"
    public struct Summary: Equatable, Sendable {
        public let total: Int
        public let correctCount: Int
        public let totalSuggestedUnits: Double
        public let holdBreakdown: [String: Int]

        public var correctRate: Double {
            total == 0 ? 0 : Double(correctCount) / Double(total)
        }
    }

    public func summarize() -> Summary {
        let records = readAll()
        var holds: [String: Int] = [:]
        var correctCount = 0
        var totalUnits = 0.0
        for r in records {
            if let reason = r.holdReason {
                holds[reason, default: 0] += 1
            } else {
                correctCount += 1
                totalUnits += r.suggestedUnits
            }
        }
        return Summary(total: records.count, correctCount: correctCount,
                       totalSuggestedUnits: totalUnits, holdBreakdown: holds)
    }
}
