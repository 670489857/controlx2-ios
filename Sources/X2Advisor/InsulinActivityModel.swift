import Foundation

/// 速效胰岛素的活性衰减模型（Walsh 分段线性）。
///
/// 剩余活性比例 R(t)：
///
///     t ≤ 0                 → 1
///     0 < t ≤ peak          → 1 − 0.5 · t / peak
///     peak < t ≤ DIA        → 0.5 · (DIA − t) / (DIA − peak)
///     t > DIA               → 0
///
/// 也就是"线性起效到峰值时消耗一半，再线性衰减到作用结束"。
///
/// 为什么不用更光滑的 Gamma 分布：试过 Gamma(shape = 2)，它在峰值时刻只消耗
/// 26% 的活性，而临床观察是 40–50%。这个差异的方向很要命——模型低估即将发生的
/// 降糖，就会多建议剂量。宁可曲线有折角，也不能让误差朝"多给胰岛素"的方向偏。
///
/// 分段线性的代价是预测曲线在峰值处有一个拐点。这是模型的真实形状，不是数值噪声，
/// 展示时不应当把它平滑掉。
public struct InsulinActivityModel: Equatable, Sendable {

    /// 活性峰值时间（分钟）
    public let peakMinutes: Double
    /// 作用持续时间（分钟），到时剩余活性归零
    public let durationMinutes: Double

    /// 峰值时刻已消耗的活性比例
    public static let fractionAtPeak = 0.5

    public static let defaultPeak: Double = 75
    public static let defaultDuration: Double = 360

    public init(peakMinutes: Double = InsulinActivityModel.defaultPeak,
                durationMinutes: Double = InsulinActivityModel.defaultDuration) {
        // 参数不合理时整体回退默认，而不是只修一个——半套参数比默认值更危险
        let peakOk = peakMinutes.isFinite && peakMinutes > 0
        let durationOk = durationMinutes.isFinite && durationMinutes > 0
        if peakOk && durationOk && peakMinutes < durationMinutes {
            self.peakMinutes = peakMinutes
            self.durationMinutes = durationMinutes
        } else {
            self.peakMinutes = InsulinActivityModel.defaultPeak
            self.durationMinutes = InsulinActivityModel.defaultDuration
        }
    }

    /// 剩余活性比例，0...1
    public func remainingFraction(atMinutes t: Double) -> Double {
        guard t.isFinite else { return 0 }
        if t <= 0 { return 1 }
        if t >= durationMinutes { return 0 }
        if t <= peakMinutes {
            return 1 - InsulinActivityModel.fractionAtPeak * t / peakMinutes
        }
        let tail = durationMinutes - t
        let span = durationMinutes - peakMinutes
        return InsulinActivityModel.fractionAtPeak * tail / span
    }

    /// 从 t1 到 t2 消耗掉的活性比例，即 R(t1) − R(t2)
    public func fractionConsumed(fromMinutes t1: Double, toMinutes t2: Double) -> Double {
        let a = remainingFraction(atMinutes: t1)
        let b = remainingFraction(atMinutes: t2)
        return min(max(a - b, 0), 1)
    }

    /// 作用结束时间，等于 DIA
    public var actionDurationMinutes: Double { durationMinutes }
}
