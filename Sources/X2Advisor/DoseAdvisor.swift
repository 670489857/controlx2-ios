import Foundation

/// 建议参数。默认值只是"安全保守的起点"，不是处方，实际值应由用户按医嘱填写，
/// 后续可以从泵的 `BolusCalcDataSnapshot` 读取，与泵内参数保持一致。
public struct AdvisorSettings: Codable, Equatable, Sendable {
    /// 目标血糖 mg/dL
    public var targetBg: Double = 110
    /// 胰岛素敏感系数 mg/dL per U
    public var isf: Double = 50
    /// 碳水比 g per U
    public var carbRatio: Double = 10
    /// 单次建议的硬上限，U。这是安全阀，不是算法输出。
    public var maxSingleDoseUnits: Double = 2.0
    /// 低于此血糖不做任何追加
    public var minBgToCorrect: Double = 120
    /// 低血糖阈值
    public var lowThreshold: Double = 70
    /// IOB 高于此值不做任何追加
    public var maxIobToCorrect: Double = 3.5
    /// 距上次 bolus 至少多少分钟
    public var minMinutesBetweenDoses: Double = 45
    /// CGM 数据超过多少分钟视为过期
    public var maxCgmAgeMinutes: Double = 15
    /// 趋势为下降时是否仍允许建议（默认不允许）
    public var allowCorrectionWhileFalling: Bool = false

    public init() {}
}

/// 建议被拒绝的原因。每一条都对应一个具体的、可解释的安全检查。
public enum HoldReason: String, Codable, Equatable, Sendable {
    /// 没有 CGM 数据
    case cgmMissing
    /// CGM 数据过期
    case cgmStale
    /// 当前血糖低于追加阈值
    case glucoseTooLow
    /// 趋势正在下降
    case fallingFast
    /// 预测将在观测窗内跌破低血糖
    case predictedLow
    /// IOB 已超过上限
    case iobTooHigh
    /// 距上次给药太近
    case doseTooRecent
    /// 预测稳态在目标附近，不需要动作
    case predictedInRange
    /// 算出来的剂量低于泵的最小步进
    case doseTooSmall

    /// 面向用户的说明。放在这里是因为它要跟判断逻辑严格对应，
    /// 分开维护容易出现"理由和实际检查项对不上"的错位。
    public var explanation: String {
        switch self {
        case .cgmMissing: return "没有血糖数据"
        case .cgmStale: return "血糖数据已过期，先恢复 CGM"
        case .glucoseTooLow: return "当前血糖低于追加阈值"
        case .fallingFast: return "血糖正在快速下降"
        case .predictedLow: return "预测会跌破低血糖，不给追加"
        case .iobTooHigh: return "活性胰岛素已偏高"
        case .doseTooRecent: return "距上次给药时间太短"
        case .predictedInRange: return "预测稳态在目标范围内"
        case .doseTooSmall: return "建议剂量小于泵的最小步进"
        }
    }
}

/// 一次判断的结论
public enum DoseAdvice: Equatable, Sendable {
    case hold(HoldReason)
    /// units 已按 `maxSingleDoseUnits` 截断；`capped` 为真表示被截断过
    case correct(units: Double, eventualBg: Double, capped: Bool)

    public var suggestedUnits: Double {
        if case let .correct(u, _, _) = self { return u }
        return 0
    }

    public var holdReason: HoldReason? {
        if case let .hold(r) = self { return r }
        return nil
    }
}

/// 剂量建议器。
///
/// 它不是闭环控制器——不产生持续的基础率指令，只回答一个问题：
/// **"按现在的数据和参数，此刻是否值得补一针，补多少。"**
///
/// 这个区别是刻意的。t:slim X2 的协议层没有临时基础率指令
/// （`SetTempRateRequest` 标了 MOBI_ONLY），也没有远程暂停
/// （`SuspendPumpingRequest` 同样 MOBI_ONLY）。也就是说在这台泵上，
/// 任何自动下发都只有"加速"一个方向，没有"刹车"。
/// 在这种执行器条件下做全自动闭环，是把控制回路建在一个不可撤销的通道上，
/// 所以这里只做建议，把执行留给人确认。
public struct DoseAdvisor: Sendable {

    public let settings: AdvisorSettings
    public let predictor: BGPPredictor
    /// 泵的最小 bolus 步进，0.05 U
    public static let minimumDoseStep = 0.05

    public init(settings: AdvisorSettings = AdvisorSettings(),
                predictor: BGPPredictor = BGPPredictor()) {
        self.settings = settings
        self.predictor = predictor
    }

    public struct Input: Sendable {
        public let now: Date
        public let latest: GlucoseSample?
        public let iob: Double
        public let carbsOnBoard: Double
        public let lastBolusAt: Date?
        /// 最近 15 分钟拟合斜率，优先用于"是否下降"的判断
        public let measuredSlope: Double?

        public init(now: Date, latest: GlucoseSample?, iob: Double,
                    carbsOnBoard: Double = 0, lastBolusAt: Date?,
                    measuredSlope: Double? = nil) {
            self.now = now
            self.latest = latest
            self.iob = iob
            self.carbsOnBoard = carbsOnBoard
            self.lastBolusAt = lastBolusAt
            self.measuredSlope = measuredSlope
        }
    }

    public func advise(_ input: Input) -> DoseAdvice {
        let s = settings

        // 1. 数据可用性
        guard let sample = input.latest else { return .hold(.cgmMissing) }
        let ageMinutes = input.now.timeIntervalSince(sample.timestamp) / 60
        guard ageMinutes >= -2, ageMinutes <= s.maxCgmAgeMinutes else { return .hold(.cgmStale) }

        // 2. 当前血糖下限
        guard Double(sample.mgdl) >= s.minBgToCorrect else { return .hold(.glucoseTooLow) }

        // 3. 趋势。优先用实测斜率，缺失时退回泵的趋势码。
        //    泵的趋势码粒度粗（0.5 mg/dL/min 一档），但比没有好。
        let slope = input.measuredSlope ?? sample.trend?.mgdlPerMinute
        if !s.allowCorrectionWhileFalling, let slope {
            if slope <= -1.0 { return .hold(.fallingFast) }
        }

        // 4. IOB 上限
        guard input.iob <= s.maxIobToCorrect else { return .hold(.iobTooHigh) }

        // 5. 给药间隔
        if let last = input.lastBolusAt {
            let elapsed = input.now.timeIntervalSince(last) / 60
            if elapsed >= 0, elapsed < s.minMinutesBetweenDoses { return .hold(.doseTooRecent) }
        }

        // 6. 预测。窗口 4 小时，够覆盖速效胰岛素的主要作用期。
        let prediction = predictor.predict(.init(
            currentBg: Double(sample.mgdl),
            now: input.now,
            iob: input.iob,
            isf: s.isf,
            carbsOnBoard: input.carbsOnBoard,
            carbRatio: s.carbRatio,
            horizonMinutes: 240,
            lowThreshold: s.lowThreshold,
            highThreshold: 180
        ))

        // 7. 预测将低血糖，一票否决。这一条排在剂量计算之前，
        //    因为"预测低血糖"比"预测稳态偏高"优先级更高。
        if let t = prediction.minutesToLow, t <= 120 {
            return .hold(.predictedLow)
        }

        // 8. 是否需要追加
        guard prediction.eventualBg > s.targetBg else { return .hold(.predictedInRange) }

        var units = (prediction.eventualBg - s.targetBg) / s.isf
        units = (units / DoseAdvisor.minimumDoseStep).rounded() * DoseAdvisor.minimumDoseStep

        guard units >= DoseAdvisor.minimumDoseStep else { return .hold(.doseTooSmall) }

        var capped = false
        if units > s.maxSingleDoseUnits {
            units = s.maxSingleDoseUnits
            capped = true
        }
        // 浮点乘法后的两位收敛，避免 1.1500000000000001 这类展示噪声
        units = (units * 100).rounded() / 100

        return .correct(units: units, eventualBg: prediction.eventualBg, capped: capped)
    }
}
