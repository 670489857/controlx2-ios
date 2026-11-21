import Foundation

/// 「手机接管」前的自检。
///
/// 关掉泵自带 Control-IQ 之后，泵侧不再有任何自动干预：不纠高、不预测性停基础率。
/// 这套自检就是列出"接管必须成立的前提"，任何一条不成立就不允许真发针——
/// 因为错误的代价不对称：少打一针血糖会高几小时，多打一针可能直接低血糖。
///
/// 判定是三档，不是二档：
/// - `blocker`：硬性条件，必须满足
/// - `warning`：可以继续，但必须由用户逐条确认（例如"断链后没有基础胰岛素"）
/// - `info`：只提示，不拦
public struct TakeoverCheck {

    public enum Severity: String, Equatable, Sendable {
        case blocker
        case warning
        case info
    }

    public struct Item: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let detail: String
        public let severity: Severity
        /// true = 这一条已经满足
        public let passed: Bool

        public init(id: String, title: String, detail: String, severity: Severity, passed: Bool) {
            self.id = id
            self.title = title
            self.detail = detail
            self.severity = severity
            self.passed = passed
        }
    }

    /// 外部喂进来的观测值。引擎不自己去读泵，方便单测。
    public struct Facts: Equatable, Sendable {
        public var linkReady: Bool = false
        /// 泵上报的 Control-IQ 开关。nil = 读不到
        public var controlIQEnabled: Bool?
        /// 泵当前实际基础率（U/h）。nil = 读不到
        public var pumpBasalRateNow: Double?
        /// 用户在 App 里填的「泵自己在跑的基础率」
        public var pumpBasalSetting: Double = 0
        public var pumpBatteryPercent: Int?
        public var reservoirUnits: Double?
        public var pumpMaxBolusUnits: Double?
        public var bolusEnabled: Bool = false
        public var bolusRiskAccepted: Bool = false
        public var loopSettingsInvalidReason: String?
        /// 当前血糖读数年龄（分钟），无数据为 nil
        public var cgmAgeMinutes: Double?
        /// 血糖是否来自 Nightscout（此时泵侧可能完全没有 CGM）
        public var usingNightscout: Bool = false
        public var pumpHasCgm: Bool = false
        public var backgroundAudioEnabled: Bool = false
        /// 泵时钟是否已经与真实时间对齐（未设置时是 2008 年那种）
        public var pumpClockLooksValid: Bool = true
        /// 闭环单针上限，用来和泵的单次上限比较
        public var loopMaxSingleMicroBolus: Double = 0.30
        public var lowSuspendThreshold: Double = 80
        public var currentBg: Double?
        public var iobUnits: Double?

        public init() {}
    }

    public struct Report: Equatable, Sendable {
        public let items: [Item]

        public init(items: [Item]) { self.items = items }

        public var blockers: [Item] { items.filter { $0.severity == .blocker && !$0.passed } }
        public var warnings: [Item] { items.filter { $0.severity == .warning && !$0.passed } }
        public var passes: [Item] { items.filter { $0.passed } }

        /// 允许真发针的前提：无硬性未满足项；有警告时必须逐条确认
        public func canProceed(warningsAcknowledged: Bool) -> Bool {
            blockers.isEmpty && (warnings.isEmpty || warningsAcknowledged)
        }

        /// 给界面用的一句话，指出最先要修的那一条
        public var firstBlockReason: String? {
            if let first = blockers.first { return "\(first.title)：\(first.detail)" }
            if let first = warnings.first { return "需确认 — \(first.title)：\(first.detail)" }
            return nil
        }
    }

    /// 基础率一致性容差。泵的最小步进是 0.05 U/h，超过一档才算不一致
    public static let basalTolerance: Double = 0.06

    public static func evaluate(_ f: Facts) -> Report {
        var items: [Item] = []

        items.append(Item(id: "link",
                          title: "泵链路已连接",
                          detail: f.linkReady ? "蓝牙会话已认证" : "先连上泵并完成认证",
                          severity: .blocker,
                          passed: f.linkReady))

        // Control-IQ：读不到就等于「可能开着」。默认开的代价是多一针，默认关的代价是少一针
        if let ciq = f.controlIQEnabled {
            items.append(Item(id: "ciq",
                              title: "泵的 Control-IQ 已关闭",
                              detail: ciq ? "泵内算法开着，两边同时调胰岛素会叠加"
                                          : "泵内算法已关闭，基础率交给你个人计划",
                              severity: .blocker,
                              passed: !ciq))
        } else {
            items.append(Item(id: "ciq",
                              title: "泵的 Control-IQ 状态",
                              detail: "读不到（可能刚重连）。无法排除它在跑，不允许真发",
                              severity: .blocker,
                              passed: false))
        }

        // 基础率一致性：这是最容易出错、后果最直接的一条
        if let actual = f.pumpBasalRateNow {
            let diff = f.pumpBasalSetting - actual
            if diff < -basalTolerance {
                items.append(Item(id: "basal",
                                  title: "泵基础率与 App 填写不一致",
                                  detail: String(format: "泵当前 %.2f U/h，App 填 %.2f U/h。App 会多补，两份叠加", actual, f.pumpBasalSetting),
                                  severity: .blocker,
                                  passed: false))
            } else if diff > basalTolerance {
                items.append(Item(id: "basal",
                                  title: "泵基础率与 App 填写不一致",
                                  detail: String(format: "泵当前 %.2f U/h，App 填 %.2f U/h。App 会少补，血糖会往上爬", actual, f.pumpBasalSetting),
                                  severity: .warning,
                                  passed: false))
            } else {
                items.append(Item(id: "basal",
                                  title: "泵基础率与 App 填写一致",
                                  detail: String(format: "两边都是 %.2f U/h", actual),
                                  severity: .blocker,
                                  passed: true))
            }
        } else {
            items.append(Item(id: "basal",
                              title: "读不到泵当前基础率",
                              detail: "刷新一次泵状态。读不到就没法确认两边不叠加",
                              severity: .blocker,
                              passed: false))
        }

        // 安全下限：0 意味着断链后一点基础胰岛素都没有
        items.append(Item(id: "floor",
                          title: "泵留有安全基础率",
                          detail: f.pumpBasalSetting >= 0.05
                              ? String(format: "泵自跑 %.2f U/h，断链后仍有基础量", f.pumpBasalSetting)
                              : "App 填 0：全部基础胰岛素靠手机补。蓝牙断、App 被杀就完全断药，几小时内可能进酮症",
                          severity: .warning,
                          passed: f.pumpBasalSetting >= 0.05))

        // 药筒与电量：不是"该不该打"的问题，是"还能打多久"的问题
        if let battery = f.pumpBatteryPercent {
            items.append(Item(id: "battery",
                              title: "泵电量",
                              detail: "\(battery)%",
                              severity: battery < 25 ? .warning : .info,
                              passed: battery >= 25))
        }
        if let reservoir = f.reservoirUnits {
            let enough = reservoir >= 20
            items.append(Item(id: "reservoir",
                              title: "药筒余量",
                              detail: String(format: "%.0f U", reservoir),
                              severity: reservoir < 5 ? .blocker : (enough ? .info : .warning),
                              passed: reservoir >= 5))
        }

        // 单次上限：泵的上限必须比闭环单针更宽，否则每一针都会被泵改小
        if let maxBolus = f.pumpMaxBolusUnits {
            items.append(Item(id: "maxbolus",
                              title: "泵单次上限 ≥ 闭环单针上限",
                              detail: String(format: "泵 %.2f U / 闭环 %.2f U", maxBolus, f.loopMaxSingleMicroBolus),
                              severity: .blocker,
                              passed: maxBolus >= f.loopMaxSingleMicroBolus))
        } else {
            items.append(Item(id: "maxbolus",
                              title: "读不到泵单次上限",
                              detail: "自检会自己读一次；仍读不到，去「基础率计划」页手动读，或检查链路",
                              severity: .blocker,
                              passed: false))
        }

        items.append(Item(id: "bolus",
                          title: "大剂量通道已启用并确认风险",
                          detail: f.bolusEnabled && f.bolusRiskAccepted
                              ? "闭环发针走的就是这条链路"
                              : "先在「大剂量」页打开输注开关并完成风险确认",
                          severity: .blocker,
                          passed: f.bolusEnabled && f.bolusRiskAccepted))

        items.append(Item(id: "settings",
                          title: "闭环参数合法",
                          detail: f.loopSettingsInvalidReason ?? "参数通过校验",
                          severity: .blocker,
                          passed: f.loopSettingsInvalidReason == nil))

        // 血糖新鲜度
        if let age = f.cgmAgeMinutes {
            items.append(Item(id: "cgm",
                              title: "血糖读数够新",
                              detail: String(format: "%.0f 分钟前", age),
                              severity: age > 12 ? .blocker : (age > 8 ? .warning : .info),
                              passed: age <= 12))
        } else {
            items.append(Item(id: "cgm",
                              title: "有血糖读数",
                              detail: "当前没有任何血糖数据",
                              severity: .blocker,
                              passed: false))
        }

        // NS 单路：现在只有 App 里这一路血糖，泵侧本来就没有 CGM。
        // 它是事实说明，不是需要逐条确认的警告——降到 info，不挡自检。
        if f.usingNightscout && !f.pumpHasCgm {
            items.append(Item(id: "singlecgm",
                              title: "血糖只来自 Nightscout",
                              detail: "泵侧没有 CGM，这台手机是唯一报警源；保持 App 后台运行",
                              severity: .info,
                              passed: true))
        }

        items.append(Item(id: "audio",
                          title: "后台保活已开启",
                          detail: f.backgroundAudioEnabled
                              ? "锁屏后闭环仍按 5 分钟一拍运行"
                              : "关着时 App 进后台就被挂起，闭环静默停摆而泵还在走",
                          severity: .warning,
                          passed: f.backgroundAudioEnabled))

        items.append(Item(id: "clock",
                          title: "泵时钟已设置",
                          detail: f.pumpClockLooksValid
                              ? "泵时间与真实时间对齐"
                              : "泵时钟未设置（例如 2008 年），泵历史里的时间戳会全部错位",
                          severity: .warning,
                          passed: f.pumpClockLooksValid))

        return Report(items: items)
    }
}
