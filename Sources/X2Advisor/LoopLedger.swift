import Foundation

/// 闭环每一拍的记录。和影子模式（`ShadowLog`）的区别是：这里记的是**真的打没打**。
///
/// 为什么单独一份账：闭环跑起来之后，最要紧的问题不是"算法算得对不对"，
/// 而是"过去一小时到底进去了多少胰岛素"。余额只能从账上查，不能靠界面上的
/// 一个数字猜。所以 `deliveredLastHour` 从账里算，不另存内存计数器——
/// App 被系统杀掉重开后，计数器会归零，账本不会。
public struct LoopRecord: Codable, Equatable, Sendable {
    public let timestamp: Date
    /// 这一拍实际下发的剂量（U）。0 表示没打
    public let units: Double
    /// 泵的受理结果。`true` 才是真的进去了；nil 表示没尝试或结果未知
    public let accepted: Bool?
    /// 被拦下的原因
    public let holdReason: String?
    public let bg: Int?
    public let iob: Double
    public let basalEquiv: Double
    public let correction: Double
    public let eventualBg: Double?
    /// 人类可读的一行说明，便于回看时不用自己拼字段
    public let summary: String
    /// 泵拒绝或超时的原文。超时时剂量可能已经进去了，必须留痕
    public let errorText: String?

    public init(timestamp: Date,
                units: Double,
                accepted: Bool?,
                holdReason: String?,
                bg: Int?,
                iob: Double,
                basalEquiv: Double,
                correction: Double,
                eventualBg: Double?,
                summary: String,
                errorText: String?) {
        self.timestamp = timestamp
        self.units = units
        self.accepted = accepted
        self.holdReason = holdReason
        self.bg = bg
        self.iob = iob
        self.basalEquiv = basalEquiv
        self.correction = correction
        self.eventualBg = eventualBg
        self.summary = summary
        self.errorText = errorText
    }
}

public final class LoopLedger: @unchecked Sendable {

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

    /// 追加一条。**整文件重写**而不是 `FileHandle.seekToEnd`。
    ///
    /// 闭环每小时 12 条，跑一周也就 2000 行（几百 KB），重写的代价可以忽略；
    /// 换来的是「写完就是写完」：不会再出现句柄复用、偏移没落盘这类丢行的情形。
    /// 台账是额度的唯一来源，丢一行就等于额度算少一针，这笔账不能省。
    public func append(_ record: LoopRecord) {
        guard let url = fileURL, let data = try? encoder.encode(record) else { return }
        lock.lock(); defer { lock.unlock() }
        var merged = (try? Data(contentsOf: url)) ?? Data()
        merged.append(data)
        merged.append(0x0A)
        try? merged.write(to: url, options: .atomic)
    }

    public func readAll() -> [LoopRecord] {
        guard let url = fileURL,
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(LoopRecord.self, from: data)
        }
    }

    public func reset() {
        guard let url = fileURL else { return }
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }

    /// 最近 60 分钟内**确实被泵受理**的微剂量总额。
    ///
    /// 只算 `accepted == true`：失败的和状态未知的都不算进额度，否则一次通讯抖动
    /// 就会把额度吃掉，闭环在接下来一小时里静默不动，而人不知道为什么。
    /// 反过来，状态未知（nil/accepted==false 且带超时）的那一笔会由执行层
    /// 标成「不确定」，仍然在人看得到的记录里。
    public func deliveredLastHour(now: Date = Date()) -> Double {
        readAll()
            .filter { $0.accepted == true && now.timeIntervalSince($0.timestamp) < 3600 }
            .reduce(0) { $0 + $1.units }
    }

    /// 今天（本地零点起）累计下发的量
    public func deliveredToday(now: Date = Date(), calendar: Calendar = .current) -> Double {
        let start = calendar.startOfDay(for: now)
        return readAll()
            .filter { $0.accepted == true && $0.timestamp >= start }
            .reduce(0) { $0 + $1.units }
    }

    /// 最近一条打成功的记录（界面用来显示"上一针"）
    public func lastAccepted() -> LoopRecord? {
        readAll().last { $0.accepted == true }
    }

    public struct Summary: Equatable, Sendable {
        public let total: Int
        public let dosedCount: Int
        public let acceptedUnits: Double
        public let holdBreakdown: [String: Int]

        public var doseRate: Double { total == 0 ? 0 : Double(dosedCount) / Double(total) }
    }

    public func summarize() -> Summary {
        var holds: [String: Int] = [:]
        var dosed = 0
        var units = 0.0
        for r in readAll() {
            if let reason = r.holdReason {
                holds[reason, default: 0] += 1
            } else {
                dosed += 1
            }
            if r.accepted == true { units += r.units }
        }
        return Summary(total: readAll().count, dosedCount: dosed,
                       acceptedUnits: units, holdBreakdown: holds)
    }

    public func exportCSV() -> String {
        var out = "timestamp,units,accepted,hold,bg,iob,basalEquiv,correction,eventualBg,summary,error\n"
        let iso = ISO8601DateFormatter()
        for r in readAll() {
            let fields = [
                iso.string(from: r.timestamp),
                String(format: "%.2f", r.units),
                r.accepted.map { $0 ? "1" : "0" } ?? "",
                r.holdReason ?? "",
                r.bg.map(String.init) ?? "",
                String(format: "%.2f", r.iob),
                String(format: "%.2f", r.basalEquiv),
                String(format: "%.2f", r.correction),
                r.eventualBg.map { String(format: "%.0f", $0) } ?? "",
                r.summary.replacingOccurrences(of: ",", with: "，"),
                (r.errorText ?? "").replacingOccurrences(of: ",", with: "，"),
            ]
            out += fields.joined(separator: ",") + "\n"
        }
        return out
    }
}
