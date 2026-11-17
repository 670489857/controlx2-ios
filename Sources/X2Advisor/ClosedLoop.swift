import Foundation

/// 闭环（微剂量模拟基础率）——**只算不发**的决策核。
///
/// # 为什么是「微剂量」而不是「临时基础率」
///
/// t:slim X2 固件拒绝一切基础率写入：`SetTempRate`(0xA4)、`SuspendPumping`(0x9C)、
/// `ResumePumping`(0x9A) 在 pumpX2 里全是 `supportedDevices=MOBI_ONLY`，
/// controlX2 的 README 也写着 `Temp Basal and Profile settings (Tandem Mobi only)`；
/// AAPS 文档同结论。所以「闭环」在 X2 上唯一能落地的形式是：
///
///    每 5 分钟，把这段时间本该由基础率缓慢滴入的胰岛素，用一针小额大剂量补进去。
///
/// 这叫 bolus-only loop。它有三个和真基础率不一样的代价，必须写在代码里而不是口头说：
///
/// 1. **只能加、不能减**。已经打进皮下的胰岛素收不回来。所以「血糖要往下掉」时，
///    唯一能做的是**停止后续微剂量**（以及提醒去泵上暂停），而不是像 AAPS 那样
///    把临时基础率设成 0 甚至负向补偿。
/// 2. **每针都进大剂量历史**。泵按大剂量语义记 IOB、记历史，密集的小针会让
///    泵的输注历史看起来像一串 bolus。这是这套方案的固有形状，不是 bug。
/// 3. **不能和 Control-IQ 同时跑**。泵自带闭环也在调基础率，两边叠加就是双倍给药。
///    所以 `controlIQEnabled == true` 时本引擎**必须**拒绝出针，这条没有开关。
///
/// # 这个核不负责什么
///
/// 不发报文、不碰 Bluetooth、不读时钟。喂它一组数，它回一个剂量和一句理由。
/// 这样每一条安全判断都能单独测，不会出现「线上跑挂了才发现预测是坏的」。
public enum ClosedLoop {

    /// 闭环参数。默认值是**保守起点**，不是处方。
    public struct Settings: Codable, Equatable, Sendable {
        /// 目标区间下沿（mg/dL）
        public var targetLow: Double = 100
        /// 目标区间上沿（mg/dL）。预测稳态高于这里才考虑追加
        public var targetHigh: Double = 130
        /// 胰岛素敏感系数 mg/dL per U
        public var isf: Double = 50
        /// 胰岛素作用时长（分钟）
        public var insulinDurationMinutes: Double = 360

        /// 单次微剂量上限（U）。这一针最多多少
        public var maxSingleMicroBolus: Double = 0.30
        /// 任意 60 分钟内微剂量总额的上限（U）。和「单次上限」是两道不同的闸门：
        /// 前者防一针打多，后者防一串小针在没人注意的时候堆起来
        public var maxHourlyMicroBolus: Double = 1.50
        /// IOB 超过这个值就停止追加
        public var maxIobUnits: Double = 4.0
        /// 血糖低于这个值立刻停止所有微剂量
        public var lowSuspendThreshold: Double = 80
        /// 预测在 N 分钟内跌破低血糖就停止追加
        public var predictedLowWindowMinutes: Int = 30
        /// 下降速度超过这个值（mg/dL/min）就停止追加
        public var maxFallingRate: Double = 2.0
        /// CGM 超过这么多分钟算过期
        public var maxCgmAgeMinutes: Double = 12
        /// 决策节拍（秒）。基础率按 5 分钟一段换算
        public var tickSeconds: Double = 300
        /// 泵的最小步进（U）。低于这个量不打，攒到下一拍
        public var minStepUnits: Double = 0.05
        /// 高血糖追加的总量上限，按「计划基础率×这段时长」的倍数算，
        /// 防止参数填错时一针冲太多
        public var maxCorrectionMultipleOfBasal: Double = 4.0

        /// 泵自己在跑的基础率（U/h）。
        ///
        /// Control-IQ 关掉之后，泵会按自己计划里的基础率继续输注。手机接管时，
        /// 这一段必须从「该补的量」里扣掉——否则泵打一份、App 再打一份，
        /// 两份基础率叠在一起，几小时后必然低血糖。
        ///
        /// 0 表示泵当前基础率已被设成 0（真接管）；设成 0.3 表示泵留着 0.3 U/h 的安全下限，
        /// App 只补差额——这样蓝牙断了也不会一点基础胰岛素都没有。
        public var pumpBasalUnitsPerHour: Double = 0

        /// 体重（kg）。只用来在界面上和泵的参数对齐核对，算法本身不用它
        public var weightKg: Double = 0
        /// 每日胰岛素总量（U）。用来给 ISF / 单针上限一个合理起点，也能当 24h 上限的参照
        public var totalDailyInsulinUnits: Double = 0
        /// 24 小时内本 App 最多打多少 U。0 表示不限
        public var maxDailyUnits: Double = 0

        public init() {}

        /// 参数合法性。返回 nil 表示可用；返回字符串就是不能启用的理由。
        /// 宁可整体不启用，也不要用半套参数跑——半套参数比默认值更危险。
        public var invalidReason: String? {
            if !(isf > 0) { return "胰岛素敏感系数必须大于 0" }
            if targetLow <= 0 || targetHigh <= targetLow { return "目标区间填写不正确" }
            if insulinDurationMinutes < 120 || insulinDurationMinutes > 480 {
                return "胰岛素作用时长应在 2–8 小时之间"
            }
            if maxSingleMicroBolus < minStepUnits { return "单次微剂量上限不能小于最小步进 0.05 U" }
            if maxHourlyMicroBolus < maxSingleMicroBolus { return "每小时上限不能小于单次上限" }
            if tickSeconds != 300 { return "决策节拍固定 5 分钟：改成别的值会让基础率换算和泵的节奏错位" }
            if pumpBasalUnitsPerHour < 0 { return "泵自己跑的基础率不能是负数" }
            if maxDailyUnits < 0 { return "24h 上限不能是负数" }
            if maxDailyUnits > 0 && maxDailyUnits < maxHourlyMicroBolus {
                return "24h 上限不能小于每小时上限"
            }
            return nil
        }
    }

    /// 一次决策的输入。全部是外部喂进来的观测值，引擎不自己去取。
    public struct Inputs: Equatable, Sendable {
        /// 当前血糖（mg/dL）。没有 CGM 就是 nil
        public var cgmMgdl: Double?
        /// CGM 数据已经多少分钟了
        public var cgmAgeMinutes: Double?
        /// 泵报的活性胰岛素（U）
        public var iobUnits: Double
        /// 当前时段计划里的基础率（U/h）
        public var basalProfileUnitsPerHour: Double?
        /// 今天（自然日）本 App 已经打出去的微剂量总额（U）
        public var deliveredTodayUnits: Double = 0
        /// 最近 60 分钟内本 App 已经打出去的微剂量总额（U）
        public var deliveredLastHourUnits: Double
        /// 预测稳态血糖（来自 `BGPPredictor` 的 eventualBg）
        public var eventualBg: Double?
        /// 预测跌破低血糖的时间（分钟），不跌破为 nil
        public var minutesToLow: Int?
        /// 当前血糖变化速度（mg/dL per minute），负值为下降
        public var trendPerMinute: Double
        /// 泵自带 Control-IQ 是否在跑。true 时必须拒绝出针
        public var controlIQEnabled: Bool?
        /// 上一拍没打、攒下来的余量（U）
        public var carriedUnits: Double
        /// 上一拍的微剂量是否还没结束（泵还在推）
        public var pumpBusy: Bool

        public init(cgmMgdl: Double? = nil,
                    cgmAgeMinutes: Double? = nil,
                    iobUnits: Double = 0,
                    basalProfileUnitsPerHour: Double? = nil,
                    deliveredTodayUnits: Double = 0,
                    deliveredLastHourUnits: Double = 0,
                    eventualBg: Double? = nil,
                    minutesToLow: Int? = nil,
                    trendPerMinute: Double = 0,
                    controlIQEnabled: Bool? = nil,
                    carriedUnits: Double = 0,
                    pumpBusy: Bool = false) {
            self.cgmMgdl = cgmMgdl
            self.cgmAgeMinutes = cgmAgeMinutes
            self.iobUnits = iobUnits
            self.basalProfileUnitsPerHour = basalProfileUnitsPerHour
            self.deliveredTodayUnits = deliveredTodayUnits
            self.deliveredLastHourUnits = deliveredLastHourUnits
            self.eventualBg = eventualBg
            self.minutesToLow = minutesToLow
            self.trendPerMinute = trendPerMinute
            self.controlIQEnabled = controlIQEnabled
            self.carriedUnits = carriedUnits
            self.pumpBusy = pumpBusy
        }
    }

    /// 为什么这一拍不出针。每一条都是可解释的、能对上具体数据的检查项。
    public enum Hold: String, Codable, Equatable, Sendable {
        case controlIQOn
        case controlIQUnknown
        case cgmMissing
        case cgmStale
        case glucoseLow
        case predictedLow
        case fallingFast
        case iobAtCap
        case hourlyCap
        case dailyCap
        case noBasalProfile
        case doseBelowStep
        case pumpBusy

        public var explanation: String {
            switch self {
            case .controlIQOn: return "泵的 Control-IQ 在跑，两个控制器叠加会双倍给药"
            case .controlIQUnknown: return "没读到 Control-IQ 状态，无法排除它在跑，这一拍不打"
            case .cgmMissing: return "没有血糖读数"
            case .cgmStale: return "血糖读数已过期"
            case .glucoseLow: return "血糖低于停止线，这一拍不出针（已给出的收不回来，只能停手）"
            case .predictedLow: return "预测会跌破低血糖，不出针"
            case .fallingFast: return "血糖下降太快，不出针"
            case .iobAtCap: return "活性胰岛素已到上限"
            case .hourlyCap: return "最近一小时微剂量已达上限"
            case .dailyCap: return "今天用掉的量已到 24h 上限"
            case .noBasalProfile: return "没读到当前基础率，没有可换算的量"
            case .doseBelowStep: return "这一拍算出来不足 0.05 U，攒到下一拍"
            case .pumpBusy: return "上一针还在推注，不叠针"
            }
        }
    }

    /// 一次决策结果
    public struct Decision: Equatable, Sendable {
        /// 这一拍要打多少 U。0 表示不打
        public var units: Double
        /// 不为 nil 就是这一拍被拦下的原因（此时 units 一定是 0）
        public var hold: Hold?
        /// 这一段应补的基础率量（U）
        public var basalEquiv: Double
        /// 高血糖追加重（U），已被单次上限与倍数上限截断
        public var correction: Double
        /// 决策后剩下来的余量（U），下一拍继续攒
        public var carriedOut: Double
        /// 给日志和界面看的整句话
        public var summary: String

        public var willDose: Bool { units > 0 }
    }

    /// 核心判断。纯函数：同样的输入永远给同样的输出。
    public static func decide(_ settings: Settings, _ inputs: Inputs) -> Decision {
        // 先把「该补多少」算出来，即便后面被拦，日志里也要能看到它算到了多少——
        // 只有拦住结果、不记过程，事后没法判断是算法偏了还是闸门挡住了。
        let requiredBasal = max(0, (inputs.basalProfileUnitsPerHour ?? 0) * settings.tickSeconds / 3600.0)
        let pumpBasalEquiv = max(0, settings.pumpBasalUnitsPerHour * settings.tickSeconds / 3600.0)
        // 净补量：计划要多少，减去泵自己已经在跑的那一份
        let basalEquiv = max(0, requiredBasal - pumpBasalEquiv)
        // 追加上限按「计划」算而不是按「净补」算：把泵的份额扣掉后净补可能趋近 0，
        // 按净值当倍数基准会让高血糖时的可打剂量莫名其妙地被压到没有
        let correction = computeCorrection(settings, inputs, basalEquiv: requiredBasal)

        func hold(_ reason: Hold, _ extra: String = "") -> Decision {
            Decision(units: 0,
                     hold: reason,
                     basalEquiv: basalEquiv,
                     correction: correction,
                     carriedOut: inputs.carriedUnits,
                     summary: reason.explanation + (extra.isEmpty ? "" : "（\(extra)）"))
        }

        // 读不到就等于「可能开着」。这里不能默认成关：默认关的代价是多打一针，
        // 默认不打的代价是少打一针。两种错都要防，但方向必须选后者。
        guard let ciq = inputs.controlIQEnabled else { return hold(.controlIQUnknown) }
        if ciq { return hold(.controlIQOn) }
        if inputs.pumpBusy { return hold(.pumpBusy) }
        guard let bg = inputs.cgmMgdl, bg > 0 else { return hold(.cgmMissing) }
        if let age = inputs.cgmAgeMinutes, age > settings.maxCgmAgeMinutes {
            return hold(.cgmStale, String(format: "%.0f 分钟前的读数", age))
        }
        if bg < settings.lowSuspendThreshold {
            return hold(.glucoseLow, String(format: "%.0f mg/dL", bg))
        }
        if let toLow = inputs.minutesToLow, toLow <= settings.predictedLowWindowMinutes {
            return hold(.predictedLow, "\(toLow) 分钟后")
        }
        if inputs.trendPerMinute < -settings.maxFallingRate {
            return hold(.fallingFast, String(format: "%.1f mg/dL/min", inputs.trendPerMinute))
        }
        if inputs.iobUnits >= settings.maxIobUnits {
            return hold(.iobAtCap, String(format: "IOB %.1f U", inputs.iobUnits))
        }
        guard inputs.basalProfileUnitsPerHour != nil else { return hold(.noBasalProfile) }
        if inputs.deliveredLastHourUnits >= settings.maxHourlyMicroBolus {
            return hold(.hourlyCap, String(format: "近一小时 %.2f U", inputs.deliveredLastHourUnits))
        }
        if settings.maxDailyUnits > 0, inputs.deliveredTodayUnits >= settings.maxDailyUnits {
            return hold(.dailyCap, String(format: "今天已打 %.1f U", inputs.deliveredTodayUnits))
        }

        // 血糖往目标以下走时，基线段不补——这是「只能减到 0」的物理边界。
        var planned = basalEquiv
        if let eventual = inputs.eventualBg, eventual < settings.targetLow {
            planned = 0
        }
        // IOB 接近上限时，把超额部分从这一段里扣掉，而不是照样按基础率补齐
        let iobHeadroom = max(0, settings.maxIobUnits - inputs.iobUnits)
        let wanted = min(planned + correction, iobHeadroom)

        let carried = max(0, inputs.carriedUnits) + wanted
        let step = settings.minStepUnits
        // 向下取整到步进：宁可少打一点，不要四舍五入往上
        let unitsRaw = floor(carried / step + 1e-9) * step
        let units = min(unitsRaw, settings.maxSingleMicroBolus, settings.maxHourlyMicroBolus - inputs.deliveredLastHourUnits)

        if units <= 0 {
            return hold(.doseBelowStep, String(format: "攒了 %.2f U", carried))
        }
        let leftover = max(0, carried - units)
        var parts: [String] = []
        if pumpBasalEquiv > 0 { parts.append(String(format: "泵已跑 %.2f", pumpBasalEquiv)) }
        if basalEquiv > 0 { parts.append(String(format: "基础率段 %.2f", basalEquiv)) }
        if correction > 0 { parts.append(String(format: "追加 %.2f", correction)) }
        if leftover > 0 { parts.append(String(format: "留下 %.2f", leftover)) }
        return Decision(units: units,
                        hold: nil,
                        basalEquiv: basalEquiv,
                        correction: correction,
                        carriedOut: leftover,
                        summary: String(format: "打 %.2f U", units) + (parts.isEmpty ? "" : "（" + parts.joined(separator: "、") + "）"))
    }

    /// 高血糖追加。三条上限同时生效：单次上限、这一段基础量的倍数、以及 IOB 剩余空间。
    private static func computeCorrection(_ settings: Settings, _ inputs: Inputs, basalEquiv: Double) -> Double {
        guard let bg = inputs.cgmMgdl, bg > 0 else { return 0 }
        // 没有预测就用地当前血糖；有预测就用预测稳态——预测里已经含了 IOB 的作用，
        // 再加一次 IOB 会重复扣减
        let anchor = inputs.eventualBg ?? bg
        guard anchor > settings.targetHigh else { return 0 }
        let raw = (anchor - settings.targetHigh) / settings.isf
        let multipleCap = max(basalEquiv * settings.maxCorrectionMultipleOfBasal, settings.minStepUnits)
        return min(max(0, raw), settings.maxSingleMicroBolus, multipleCap)
    }
}
