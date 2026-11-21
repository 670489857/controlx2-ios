import Foundation

/// 只读状态的字段解码。
///
/// 单独拆出来的理由：这些偏移量是全套预测与建议的地基，错一个字节，
/// 界面上仍然会显示一个「看起来合理」的数字。所以每一处都必须能拿
/// 上游 pumpX2 的抓包向量（十六进制）直接对照，而不是靠肉眼盯 Swift 代码。
///
/// 字段定义来源（jwoglom/pumpX2，与 t:connect 抓包逐字节核对过）：
/// - `InsulinStatusResponse` opCode 37 / 0x25，size 4
/// - `CurrentBasalStatusResponse` opCode 41 / 0x29，size 9
/// - `ControlIQIOBResponse` opCode 109 / 0x6D，size 17
/// - `CurrentBatteryV1Response` opCode 53 / 0x35，size 2
/// - `CurrentEGVGuiDataResponse` opCode 35 / 0x23，size 8
public enum StatusDecoder {

    // MARK: 药筒余量 0x25

    public struct InsulinStatus: Equatable, Sendable {
        /// 泵显示的剩余量（U）。原始值是 0.001 U 的整数，与 `InsulinUnit.from1000To1` 一致
        public let units: Double
        /// 泵自己也说这是估算值（换筒、回抽中途）
        public let isEstimate: Bool
        /// 泵上设的低余量提醒阈值（U）
        public let lowAmount: Double
    }

    /// cargo = [amount i16 LE][isEstimate u8][lowAmount u8]
    ///
    /// **刻度是 1 LSB = 1 U，不是 0.001 U。** 真机标定：泵屏幕显示「+60 u」，
    /// 同一条 0x25 的原始值是 60。按 0.001 解释会把 60 U 读成 0.06 U，
    /// 大剂量闸门于是认为药筒空了，把一针 0.5 U 直接拦掉——界面上一句
    /// 「药筒余量不够这一针」，但泵上明明还有 60 U。
    ///
    /// 两个旁证：同一报文里的 `lowAmount` 是低余量阈值（默认 35 U），也是整单位，
    /// 一条报文里不可能有两套刻度；另外 i16 上限 32767，一整筒 300 U 按 0.001
    /// 存根本装不下。所以这里不做任何除法。
    public static func insulinStatus(_ cargo: [UInt8]) -> InsulinStatus? {
        guard cargo.count >= 4 else { return nil }
        let raw = Int16(bitPattern: UInt16(cargo[0]) | UInt16(cargo[1]) << 8)
        return InsulinStatus(units: Double(raw),
                             isEstimate: cargo[2] != 0,
                             lowAmount: Double(cargo[3]))
    }

    // MARK: 基础率 0x29

    public struct BasalStatus: Equatable, Sendable {
        /// 当前基础率（U/h）。Control-IQ 调整、临时基础率期间，这个值可能与配置文件不同
        public let current: Double
        /// 当前时段配置文件里的基础率（U/h）
        public let profile: Double
        /// 非 0 表示基础率被改过（临时率、Control-IQ、暂停）
        public let modified: UInt8

        /// 泵屏幕上的基础率就是 current；它和 profile 不等时说明正被调整。
        public var isModified: Bool { modified != 0 }
    }

    /// cargo = [profile u32 LE][current u32 LE][modified u8]
    public static func currentBasal(_ cargo: [UInt8]) -> BasalStatus? {
        guard cargo.count >= 9 else { return nil }
        return BasalStatus(current: Double(readU32(cargo, 4)) / 1000.0,
                           profile: Double(readU32(cargo, 0)) / 1000.0,
                           modified: cargo[8])
    }

    // MARK: 活性胰岛素 0x6D

    public struct IOB: Equatable, Sendable {
        /// 0 = Mudaliar 曲线，1 = Swan 6hr；未知值只在固件改版时出现
        public let type: Int
        public let mudaliar: Double
        public let swan6hr: Double

        /// 泵屏幕上显示的那个数。
        ///
        /// 这里必须按 type 取，不能一律读 mudaliar：两种曲线在胰岛素还在起效时
        /// 能差 0.03 U 以上，够让「建议补多少」偏一档。类型未知时取两者较大值——
        /// 宁可高估在体内的胰岛素（少建议），也不要低估。
        public var displayed: Double {
            switch type {
            case 0: return mudaliar
            case 1: return swan6hr
            default: return max(mudaliar, swan6hr)
            }
        }

        public var typeName: String {
            switch type {
            case 0: return "Mudaliar"
            case 1: return "Swan 6hr"
            default: return "未知(\(type))"
            }
        }
    }

    /// cargo = [mudaliar u32][timeRemaining u32][mudaliarTotal u32][swan6hr u32][type u8]
    public static func controlIQIOB(_ cargo: [UInt8]) -> IOB? {
        guard cargo.count >= 17 else { return nil }
        return IOB(type: Int(cargo[16]),
                   mudaliar: Double(readU32(cargo, 0)) / 1000.0,
                   swan6hr: Double(readU32(cargo, 12)) / 1000.0)
    }

    // MARK: 电量 0x35

    /// cargo = [abc u8][ibc u8]；泵屏幕上那个百分比是**第二个**字节。
    /// 第一个字节是另一个口径（Mobi 的 DailyBasalHistoryLog 用它），拿错会显示成看似合理的错数。
    public static func batteryPercent(_ cargo: [UInt8]) -> Int? {
        guard cargo.count >= 2 else { return nil }
        return Int(cargo[1])
    }

    // MARK: 血糖 0x23

    public struct EGV: Equatable, Sendable {
        /// 泵自己的计时起点（不是 Unix 时间）
        public let timestamp: UInt32
        public let mgdl: Int
        /// 0=无效 1=有效 2=低 3=高 4=不可用
        public let status: Int
        /// 0–9，与泵屏幕箭头对应
        public let trend: Int

        /// LOW / HIGH 时泵给的是一个夹紧的边界值（40 / 400），要标出来
        public var isClamped: Bool { status == 2 || status == 3 }
        public var statusName: String {
            switch status {
            case 0: return "无效"
            case 1: return "有效"
            case 2: return "低（夹到下限）"
            case 3: return "高（夹到上限）"
            case 4: return "不可用"
            default: return "未知(\(status))"
            }
        }
    }

    /// cargo = [timestamp u32][mgdl i16][status u8][trend i8]
    public static func egv(_ cargo: [UInt8]) -> EGV? {
        guard cargo.count >= 8 else { return nil }
        let raw = Int16(bitPattern: UInt16(cargo[4]) | UInt16(cargo[5]) << 8)
        return EGV(timestamp: readU32(cargo, 0),
                   mgdl: Int(raw),
                   status: Int(cargo[6]),
                   trend: Int(Int8(bitPattern: cargo[7])))
    }

    // MARK: 字节序

    /// 小端 u32。公开是因为 App 层要在核对页上显示泵计时这两个字段的原值。
    public static func readU32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    // MARK: 版本信息（0x85 PumpVersionB，60 字节）

    /// 字段偏移来自 pumpX2 的 `PumpVersionBResponse.parse`：
    /// softwareName 0..20、configA 20、configB 24、serial 28、model 32、
    /// pumpRevision 36..44、pcbPart 44、pcbSerial 48、pcbRevision 52..60。
    ///
    /// 长度不对时返回 nil 而不是硬解：这条报文在不同固件上可能是别的长度，
    /// 硬解会把序列号显示成一串错位数字，比显示"未读取"更误导。
    public struct PumpVersion: Equatable, Sendable {
        public let softwareName: String
        public let modelNumber: UInt32
        public let serialNumber: UInt32
        public let pumpRevision: String
    }

    public static func pumpVersionB(_ cargo: [UInt8]) -> PumpVersion? {
        guard cargo.count >= 44 else { return nil }
        let name = ascii(cargo, 0, 20)
        let model = readU32(cargo, 32)
        let serial = readU32(cargo, 28)
        let rev = ascii(cargo, 36, 8)
        return PumpVersion(softwareName: name, modelNumber: model, serialNumber: serial, pumpRevision: rev)
    }

    // MARK: 最近一次大剂量（0xA5 LastBolusStatusV2，24 字节）

    /// 泵自己记的"最后一针"：实际打进多少、请求多少。
    /// 字段偏移照 pumpX2 的 `LastBolusStatusV2Response.parse`：
    /// status 0、bolusId 1..2、timestamp 5、delivered 9、requested 20（单位都是千分之一 U）。
    ///
    /// 这条报文才是台账该信的东西。"泵受理了"不等于"打进身体了"——
    /// 药筒空、管路堵、中途取消，都会让受理成功而实际输注为 0。
    public struct LastBolusStatus: Equatable, Sendable {
        public let bolusId: Int
        public let deliveredUnits: Double
        public let requestedUnits: Double
        public let statusId: Int
    }

    public static func lastBolusStatusV2(_ cargo: [UInt8]) -> LastBolusStatus? {
        guard cargo.count >= 24 else { return nil }
        let bolusId = Int(UInt16(cargo[1]) | UInt16(cargo[2]) << 8)
        return LastBolusStatus(bolusId: bolusId,
                               deliveredUnits: Double(readU32(cargo, 9)) / 1000,
                               requestedUnits: Double(readU32(cargo, 20)) / 1000,
                               statusId: Int(cargo[13]))
    }

    /// 固定长度字符串：截到第一个不可打印字节（含 NUL），并去掉首尾空白。
    /// 泵把这些字段写成定长 NUL 填充，直接当字符串用会带一串看不见的尾字符。
    private static func ascii(_ b: [UInt8], _ offset: Int, _ length: Int) -> String {
        guard offset + length <= b.count else { return "" }
        var bytes: [UInt8] = []
        for index in offset..<(offset + length) {
            let v = b[index]
            if v < 0x20 || v > 0x7E { break }
            bytes.append(v)
        }
        return String(bytes: bytes, encoding: .utf8)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }
}
