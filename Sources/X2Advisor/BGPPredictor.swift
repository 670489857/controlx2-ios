import Foundation

/// 预测曲线上的一点
public struct PredictionPoint: Equatable, Sendable {
    public let date: Date
    public let mgdl: Double
    public init(date: Date, mgdl: Double) {
        self.date = date
        self.mgdl = mgdl
    }
}

/// 一次预测的完整结果
public struct PredictionResult: Equatable, Sendable {
    /// 从当前时刻起、每 5 分钟一个点，含 t = 0
    public let points: [PredictionPoint]
    /// 所有作用结束后的稳态血糖（Loop 里叫 eventualBG）
    public let eventualBg: Double
    /// 预测首次跌破低血糖阈值的时间（分钟），不跌破为 nil
    public let minutesToLow: Int?
    /// 预测首次超过高血糖阈值的时间（分钟），不超高为 nil
    public let minutesToHigh: Int?

    public var isPredictedLow: Bool { minutesToLow != nil }
}

/// 血糖预测器。
///
/// 模型是两项线性叠加，与 Loop 的 eventualBG 同构：
///
///     bg(t) = bg₀ − ISF · IOB · (1 − R(t)) + COB · (ISF / CR) · A(t)
///
/// 其中 R(t) 是胰岛素剩余活性比例（见 `InsulinActivityModel`），
/// A(t) 是碳水吸收比例，用指数模型 1 − exp(−t / τc)。
///
/// 刻意没有建模的三件事，理由是它们不影响"该不该补一针"这个判断，
/// 但会让曲线看起来更"准"而产生虚假信心：
///
/// - **基础率的持续作用**：Control-IQ 在跑时基础率本身在变，模型无法预知
///   它将来的调整，强行外推只是把假设当事实。本模型的定位是"如果从现在起
///   什么都不做，血糖会去哪里"，而不是"预测闭环下的血糖"。
/// - **运动与应激**：无法从协议数据中获知。
/// - **注射部位吸收差异**：个体内变异就有 ±20%，建模精度低于变异本身。
public struct BGPPredictor: Sendable {

    public let activity: InsulinActivityModel
    /// 碳水的吸收时间常数（分钟）。默认 3 小时，与混合餐的临床观察接近。
    public let carbAbsorptionMinutes: Double
    public let stepMinutes: Int

    public init(activity: InsulinActivityModel = InsulinActivityModel(),
                carbAbsorptionMinutes: Double = 180,
                stepMinutes: Int = 5) {
        self.activity = activity
        self.carbAbsorptionMinutes = carbAbsorptionMinutes > 0 ? carbAbsorptionMinutes : 180
        self.stepMinutes = max(stepMinutes, 1)
    }

    public struct Input: Sendable {
        public let currentBg: Double
        public let now: Date
        /// 净活性胰岛素（U）。可以为负——Control-IQ 的净 IOB 在长时间低基础时会为负，
        /// 表示"欠输的胰岛素"，此时胰岛素项变成升糖，这是正确的物理含义。
        public let iob: Double
        /// 胰岛素敏感系数，mg/dL per U
        public let isf: Double
        public let carbsOnBoard: Double
        /// 碳水比，g per U
        public let carbRatio: Double
        public let horizonMinutes: Int
        public let lowThreshold: Double
        public let highThreshold: Double

        public init(currentBg: Double, now: Date, iob: Double, isf: Double,
                    carbsOnBoard: Double = 0, carbRatio: Double = 10,
                    horizonMinutes: Int = 240,
                    lowThreshold: Double = 70, highThreshold: Double = 180) {
            self.currentBg = currentBg
            self.now = now
            self.iob = iob
            self.isf = isf
            self.carbsOnBoard = carbsOnBoard
            self.carbRatio = carbRatio
            self.horizonMinutes = horizonMinutes
            self.lowThreshold = lowThreshold
            self.highThreshold = highThreshold
        }
    }

    public func predict(_ input: Input) -> PredictionResult {
        let isf = max(input.isf, 1)  // ISF ≤ 0 无物理意义，退化为 1 避免除零与符号翻转
        let cr = max(input.carbRatio, 1)
        let horizon = max(input.horizonMinutes, stepMinutes)

        // 碳水吸收的时间常数：让 95% 在 carbAbsorptionMinutes 内完成
        let tauCarb = carbAbsorptionMinutes / 3.0
        /// 碳水在 t 分钟时已吸收的比例
        func absorbed(_ t: Double) -> Double {
            guard t > 0 else { return 0 }
            return 1 - exp(-t / tauCarb)
        }

        var points: [PredictionPoint] = []
        var minutesToLow: Int?
        var minutesToHigh: Int?

        var t = 0
        while t <= horizon {
            let tf = Double(t)
            let insulinDelta = -isf * input.iob * (1 - activity.remainingFraction(atMinutes: tf))
            let carbDelta = input.carbsOnBoard * isf / cr * absorbed(tf)
            let bg = input.currentBg + insulinDelta + carbDelta

            points.append(PredictionPoint(
                date: input.now.addingTimeInterval(tf * 60),
                mgdl: bg
            ))

            if minutesToLow == nil && bg <= input.lowThreshold { minutesToLow = t }
            if minutesToHigh == nil && bg >= input.highThreshold { minutesToHigh = t }
            t += stepMinutes
        }

        let eventual = input.currentBg
            - isf * input.iob
            + input.carbsOnBoard * isf / cr

        return PredictionResult(
            points: points,
            eventualBg: eventual,
            minutesToLow: minutesToLow,
            minutesToHigh: minutesToHigh
        )
    }
}
