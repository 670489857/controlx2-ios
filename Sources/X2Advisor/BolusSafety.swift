import Foundation

/// 打药前的安全闸门。
///
/// 这一层的职责很具体：把「用户想打多少」和「此刻允许打多少」分开。
/// 协议层只负责把报文发对，剂量边界必须在这里拦，理由写清楚，界面照原样显示。
///
/// 每条闸门都对应一个能在泵屏幕或读数上核对的事实，不做任何猜测：
/// 单次上限、24 小时累计、与上次的间隔、当前血糖、药筒余量。
/// 缺失的数据不当作 0——药筒余量读不到就不放行，而不是假设「还有很多」。
public struct BolusPolicy: Codable, Equatable, Sendable {
    /// 单次上限（U）。默认 5 U，用户可改，改完立即生效。
    /// **填 0 表示不限**——这条闸门整条不参与判断，而不是「上限 0 U」。
    public var maxSingleUnits: Double = 5.0
    /// 24 小时累计上限（U）。**填 0 表示不限**。
    /// 关掉之后台账仍然记录，只是不再拦；界面会把累计量继续显示出来。
    public var max24hUnits: Double = 12.0
    /// 两次大剂量之间的最小间隔（分钟）。**填 0 表示不要求间隔**。
    public var minIntervalMinutes: Double = 60
    /// 低于此血糖不放大剂量（mg/dL）
    public var lowGlucoseThreshold: Double = 80
    /// 泵的最小步进（U）
    public var minimumUnits: Double = 0.05
    /// IOB 高于此值时提示（只提示，不拦）
    public var warnIobUnits: Double = 5.0
    /// 药筒余量要留出的余量（U）：换筒/排气时会用掉一点
    public var reservoirMarginUnits: Double = 0.5

    public init() {}
}

public struct BolusContext: Sendable {
    public var requestedUnits: Double
    public var now: Date
    public var policy: BolusPolicy
    /// 本机记录的最近一次大剂量时间
    public var lastBolusAt: Date?
    /// 本机记录的 24 小时内已给总量（U）
    public var delivered24h: Double
    /// 药筒余量（U）。读不到传 nil
    public var reservoirUnits: Double?
    /// 当前血糖 mg/dL。没有 CGM 时传 nil
    public var glucoseMgdl: Int?
    /// 活性胰岛素（U）
    public var iobUnits: Double?

    public init(requestedUnits: Double, now: Date, policy: BolusPolicy,
                lastBolusAt: Date?, delivered24h: Double,
                reservoirUnits: Double?, glucoseMgdl: Int?, iobUnits: Double?) {
        self.requestedUnits = requestedUnits
        self.now = now
        self.policy = policy
        self.lastBolusAt = lastBolusAt
        self.delivered24h = delivered24h
        self.reservoirUnits = reservoirUnits
        self.glucoseMgdl = glucoseMgdl
        self.iobUnits = iobUnits
    }
}

public enum BolusBlockReason: String, Codable, Equatable, Sendable {
    case doseTooSmall
    case aboveSingleLimit
    case aboveDailyLimit
    case tooSoon
    case lowGlucose
    case reservoirLow
    case reservoirUnknown

    public var explanation: String {
        switch self {
        case .doseTooSmall: return "剂量小于泵的最小步进 0.05 U"
        case .aboveSingleLimit: return "超过你设定的单次上限"
        case .aboveDailyLimit: return "加上这一针会超过 24 小时累计上限"
        case .tooSoon: return "距上一次大剂量太近"
        case .lowGlucose: return "当前血糖低于阈值，先处理低血糖"
        case .reservoirLow: return "药筒余量不够这一针"
        case .reservoirUnknown: return "药筒余量读不到，先刷新读数"
        }
    }
}

public struct BolusBlock: Equatable, Sendable {
    public let reason: BolusBlockReason
    /// 具体到数字的说明，例如「3.00 U > 上限 2.00 U」
    public let detail: String
}

public struct BolusDecision: Equatable, Sendable {
    /// 是否放行。false 时 `blocks` 至少有一条
    public let allowed: Bool
    /// 实际会打进去的量：已向下取整到 0.05 U
    public let units: Double
    public let blocks: [BolusBlock]
    /// 不拦截、但要让用户看见的提示
    public let warnings: [String]

    public var primaryBlock: BolusBlock? { blocks.first }
}

public enum BolusGuard {

    /// 0.05 U 向下取整。四舍五入会多打 0.02 U，方向永远是「宁可少一点」。
    public static func roundDown(_ units: Double, step: Double = 0.05) -> Double {
        guard units > 0, step > 0 else { return 0 }
        let steps = (units / step + 1e-9).rounded(.down)
        return (steps * step * 1000).rounded() / 1000
    }

    public static func evaluate(_ ctx: BolusContext) -> BolusDecision {
        let p = ctx.policy
        let units = roundDown(ctx.requestedUnits, step: p.minimumUnits)
        var blocks: [BolusBlock] = []
        var warnings: [String] = []

        if units < p.minimumUnits - 1e-9 {
            blocks.append(BolusBlock(reason: .doseTooSmall,
                                     detail: String(format: "取整后 %.2f U，泵最小 0.05 U", units)))
        }
        // 上限为 0 = 这条闸门关掉。写成 `> 0` 而不是 `!= 0`：负数（手滑输进去的）
        // 同样当「不限」，不能让一个负号变成「任何剂量都超限」这种更奇怪的行为。
        if p.maxSingleUnits > 0, units > p.maxSingleUnits + 1e-9 {
            blocks.append(BolusBlock(reason: .aboveSingleLimit,
                                     detail: String(format: "%.2f U > 单次上限 %.2f U", units, p.maxSingleUnits)))
        }
        if p.max24hUnits > 0, ctx.delivered24h + units > p.max24hUnits + 1e-9 {
            blocks.append(BolusBlock(reason: .aboveDailyLimit,
                                     detail: String(format: "24 小时已给 %.2f U，再加 %.2f U 会超过 %.2f U",
                                                    ctx.delivered24h, units, p.max24hUnits)))
        }
        if p.minIntervalMinutes > 0, let last = ctx.lastBolusAt {
            let minutes = ctx.now.timeIntervalSince(last) / 60
            if minutes < p.minIntervalMinutes - 1e-9 {
                blocks.append(BolusBlock(reason: .tooSoon,
                                         detail: String(format: "距上次 %.0f 分钟，要求至少 %.0f 分钟",
                                                        minutes, p.minIntervalMinutes)))
            }
        }
        if let bg = ctx.glucoseMgdl, Double(bg) < p.lowGlucoseThreshold {
            blocks.append(BolusBlock(reason: .lowGlucose,
                                     detail: String(format: "血糖 %d mg/dL < %.0f mg/dL", bg, p.lowGlucoseThreshold)))
        }
        switch ctx.reservoirUnits {
        case .none:
            blocks.append(BolusBlock(reason: .reservoirUnknown, detail: "没有读到 CurrentInsulinStatus"))
        case let .some(remaining):
            if remaining - p.reservoirMarginUnits < units {
                blocks.append(BolusBlock(reason: .reservoirLow,
                                         detail: String(format: "余量 %.2f U，这一针 %.2f U（留 %.2f U 余量）",
                                                        remaining, units, p.reservoirMarginUnits)))
            }
        }

        if ctx.glucoseMgdl == nil {
            warnings.append("没有血糖读数：无法判断是否低血糖，请自己先测")
        }
        if let iob = ctx.iobUnits {
            if iob > p.warnIobUnits {
                warnings.append(String(format: "活性胰岛素 %.2f U 偏高，注意叠加", iob))
            }
        } else {
            warnings.append("没有 IOB 读数：泵可能尚未返回，或在用别的曲线")
        }
        if ctx.delivered24h > 0 {
            // 即使 24 小时上限关掉了，累计量也照样报——关的是拦截，不是记录
            warnings.append(String(format: "本机台账 24 小时累计 %.2f U（不含在泵上直接打的）", ctx.delivered24h))
        }

        return BolusDecision(allowed: blocks.isEmpty && units >= p.minimumUnits - 1e-9,
                             units: units, blocks: blocks, warnings: warnings)
    }
}

/// 本机的大剂量台账。
///
/// 只记「这个 App 发出去的」，泵上直接按的针不在这里。作用有两个：
/// 24 小时累计上限、以及距上次给药多久。所以界面必须把这句话写出来，
/// 否则用户会把它当成完整的胰岛素总量。
public struct BolusRecord: Codable, Equatable, Sendable {
    public let at: Date
    public let units: Double
    /// 有没有被泵回读确认。true = 泵报的实际输注量；false = 只拿到受理、没回读到实际量；
    /// nil = 旧记录（那时还没有这个概念）。
    public var confirmed: Bool?

    public init(at: Date, units: Double, confirmed: Bool? = nil) {
        self.at = at
        self.units = units
        self.confirmed = confirmed
    }
}

public struct BolusLedger: Codable, Equatable, Sendable {
    public var records: [BolusRecord]

    public init(records: [BolusRecord] = []) {
        self.records = records
    }

    public mutating func append(units: Double, at: Date = Date(), confirmed: Bool? = true) {
        guard units > 0 else { return }
        records.append(BolusRecord(at: at, units: units, confirmed: confirmed))
        prune(now: at)
    }

    /// 丢掉窗口之外（默认 24 小时）的记录，避免台账无限增长。
    public mutating func prune(now: Date, windowHours: Double = 24) {
        let window = windowHours * 3600
        records = records.filter { now.timeIntervalSince($0.at) <= window && $0.at <= now }
    }

    public func delivered(now: Date, windowHours: Double = 24) -> Double {
        let window = windowHours * 3600
        let sum = records
            .filter { now.timeIntervalSince($0.at) <= window && $0.at <= now }
            .reduce(0) { $0 + $1.units }
        return (sum * 1000).rounded() / 1000
    }

    public func last(now: Date) -> BolusRecord? {
        records.filter { $0.at <= now }.max(by: { $0.at < $1.at })
    }

    public func jsonData() -> Data? {
        try? JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data?) -> BolusLedger {
        guard let data, let l = try? JSONDecoder().decode(BolusLedger.self, from: data) else {
            return BolusLedger()
        }
        return l
    }
}
