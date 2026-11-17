import Foundation

/// Control-IQ（泵自带的闭环算法）**只读**状态报文。
///
/// 为什么只读：Control-IQ 跑在泵里，参数（体重、每日总量、目标、睡眠表）在泵上设。
/// 我们能做的是把它现在**在干什么**读出来——尤其是它有没有开、有没有被切成睡眠/运动模式。
/// 这层不做任何写入：闭环算法的决定权在泵，App 只当仪表盘和看门狗。
///
/// | 报文 | opCode | 特征 | cargo |
/// |---|---|---|---|
/// | `ControlIQInfoV1Request` | 0x68 | currentStatus，不签名 | 0 |
/// | `ControlIQInfoV1Response` | 0x69 | | 10 |
/// | `ControlIQInfoV2Request` | 0xB2 | | 0 |
/// | `ControlIQInfoV2Response` | 0xB3 | 比 V1 多运动模式剩余时间 | 19 |
/// | `ControlIQSleepScheduleRequest` | 0x6A | | 0 |
/// | `ControlIQSleepScheduleResponse` | 0x6B | 4 条睡眠时段 | 24 |
///
/// V1 与 V2 前 10 字节完全同构（`ControlIQInfoAbstractResponse` 里 V2 只是往后追加了
/// 运动模式的 9 字节），所以两版共用一个 `Info` 结构，`version` 只用于界面说明。
public enum ControlIQMessages {

    public enum ControlIQError: Error, Equatable, LocalizedError {
        case badInfoCargo
        case badSleepCargo

        public var errorDescription: String? {
            switch self {
            case .badInfoCargo: return "Control-IQ 状态报文长度不符"
            case .badSleepCargo: return "睡眠时段报文长度不符"
            }
        }
    }

    /// 泵当前被切到的用户模式。固件只支持前三种；`eatingSoon=3` 只在 Tandem Source
    /// 的事件结构里出现过，泵不接受。
    public enum UserMode: Int, Sendable, CaseIterable {
        case standard = 0
        case sleep = 1
        case exercise = 2
        case eatingSoon = 3

        public var text: String {
            switch self {
            case .standard: return "标准"
            case .sleep: return "睡眠"
            case .exercise: return "运动"
            case .eatingSoon: return "即将进食（泵不支持）"
            }
        }
    }

    public enum WeightUnit: Int, Sendable {
        case kilograms = 0
        case pounds = 1

        public var text: String { self == .kilograms ? "kg" : "lb" }
    }

    /// 0x69 / 0xB3
    public struct Info: Equatable, Sendable {
        /// 1 = 0x69，2 = 0xB3
        public var version: Int
        /// 闭环算法是否开启。关着时泵只按基础率跑，血糖掉了也没人管——这是最该被看见的一位
        public var closedLoopEnabled: Bool
        /// 泵里填的体重（整数）。Control-IQ 用它算总剂量
        public var weight: Int
        public var weightUnit: WeightUnit?
        /// 泵里填的每日胰岛素总量（U）
        public var totalDailyInsulinUnits: Int
        public var userMode: UserMode?
        public var userModeRaw: Int
        /// 算法控制状态码。**含义未在公开资料里确证**，这里只原样展示，不翻译，
        /// 免得把一个不知道含义的数字编成「正在减量」这种能被当真的结论。
        public var controlStateRaw: Int
        /// 未确证用途的三个字节，原样留着做对照
        public var reservedBytes: [Int]
        /// V2 才有：运动模式的时长与剩余（秒）
        public var exerciseDurationSeconds: Int?
        public var exerciseRemainingSeconds: Int?

        public var userModeText: String { userMode?.text ?? "未知(\(userModeRaw))" }

        /// 一句话概括，给状态页的卡片用
        public var headline: String {
            if !closedLoopEnabled { return "Control-IQ 已关闭" }
            if let m = userMode, m != .standard { return "Control-IQ 运行中 · \(m.text)模式" }
            return "Control-IQ 运行中 · 标准模式"
        }
    }

    /// 0x6B 里的一条睡眠时段
    public struct SleepWindow: Equatable, Sendable {
        public var enabled: Bool
        /// 星期位掩码：bit0(1)=周一 … bit6(64)=周日，由 pumpX2 的 `MultiDay` 证实
        public var activeDaysBitmask: Int
        /// 起始/结束的**分钟数**（自 0 点起）
        public var startMinutes: Int
        public var endMinutes: Int

        public var startText: String { SleepWindow.hhmm(startMinutes) }
        public var endText: String { SleepWindow.hhmm(endMinutes) }

        /// `周一、周三` 这种文本；空掩码返回「无」
        public var daysText: String {
            if activeDaysBitmask & 0x7F == 0x7F { return "每天" }
            if activeDaysBitmask & 0x1F == 0x1F && activeDaysBitmask & 0x60 == 0 { return "工作日" }
            let names = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
            var picked: [String] = []
            for (i, n) in names.enumerated() where activeDaysBitmask & (1 << i) != 0 {
                picked.append(n)
            }
            return picked.isEmpty ? "无" : picked.joined(separator: "、")
        }

        static func hhmm(_ minutes: Int) -> String {
            let m = max(0, minutes)
            return String(format: "%02d:%02d", m / 60, m % 60)
        }
    }

    public struct SleepSchedule: Equatable, Sendable {
        public var windows: [SleepWindow]

        /// 当前时刻落在哪条已启用的时段里（自定义，仅用于提示）
        public func activeWindow(atMinutes now: Int) -> SleepWindow? {
            windows.first { w in
                guard w.enabled, w.activeDaysBitmask != 0 else { return false }
                // 星期位掩码这里不判，只判时刻区间，跨零点的时段单独处理
                return contains(w, now)
            }
        }

        private func contains(_ w: SleepWindow, _ now: Int) -> Bool {
            if w.startMinutes <= w.endMinutes {
                return now >= w.startMinutes && now < w.endMinutes
            }
            // 跨零点，比如 23:00–07:00
            return now >= w.startMinutes || now < w.endMinutes
        }
    }

    // MARK: 请求

    public static func infoV1Request() -> PumpMessage {
        PumpMessage.request(characteristic: .currentStatus, opCode: 0x68)
    }

    public static func infoV2Request() -> PumpMessage {
        PumpMessage.request(characteristic: .currentStatus, opCode: 0xB2)
    }

    public static func sleepScheduleRequest() -> PumpMessage {
        PumpMessage.request(characteristic: .currentStatus, opCode: 0x6A)
    }

    // MARK: 解析

    /// 0x69：10 字节
    public static func parseInfoV1(_ cargo: [UInt8]) -> Info? {
        guard cargo.count >= 10 else { return nil }
        return Info(version: 1,
                    closedLoopEnabled: cargo[0] != 0,
                    weight: BolusMessages.leU16(cargo, 1),
                    weightUnit: WeightUnit(rawValue: Int(cargo[3])),
                    totalDailyInsulinUnits: Int(cargo[4]),
                    userMode: UserMode(rawValue: Int(cargo[5])),
                    userModeRaw: Int(cargo[5]),
                    controlStateRaw: Int(cargo[9]),
                    reservedBytes: [Int(cargo[6]), Int(cargo[7]), Int(cargo[8])],
                    exerciseDurationSeconds: nil,
                    exerciseRemainingSeconds: nil)
    }

    /// 0xB3：19 字节。前 10 字节与 V1 同构，后面是运动模式：
    /// [10] exerciseChoice、[11..14] 时长、[15..18] 剩余（都是小端 u32，秒）
    public static func parseInfoV2(_ cargo: [UInt8]) -> Info? {
        guard cargo.count >= 19 else { return nil }
        var info = parseInfoV1(Array(cargo[0..<10]))!
        info.version = 2
        info.exerciseDurationSeconds = Int(BolusMessages.leU32(cargo, 11))
        info.exerciseRemainingSeconds = Int(BolusMessages.leU32(cargo, 15))
        return info
    }

    /// 0x6B：24 字节 = 4 条 × 6 字节（enabled、activeDays、start u16、end u16）
    public static func parseSleepSchedule(_ cargo: [UInt8]) -> SleepSchedule? {
        guard cargo.count >= 24 else { return nil }
        var windows: [SleepWindow] = []
        for i in 0..<4 {
            let o = i * 6
            windows.append(SleepWindow(enabled: cargo[o] != 0,
                                       activeDaysBitmask: Int(cargo[o + 1]),
                                       startMinutes: BolusMessages.leU16(cargo, o + 2),
                                       endMinutes: BolusMessages.leU16(cargo, o + 4)))
        }
        return SleepSchedule(windows: windows)
    }
}
