import Foundation

/// 胰岛素单位换算。协议里所有剂量都是「毫单位」（0.001 U 的整数）。
public enum InsulinUnit {
    public static let milliPerUnit = 1000.0
    /// 泵允许的最小 bolus 步进，0.05 U
    public static let minimumStep = 0.05

    public static func toMilli(_ units: Double) -> Int {
        Int((units * milliPerUnit).rounded())
    }

    public static func fromMilli(_ milli: Int) -> Double {
        Double(milli) / milliPerUnit
    }

    /// 向下取整到 0.05 U。宁可少给一档，也不因为四舍五入多打进 0.02 U。
    public static func roundDownToStep(_ units: Double) -> Double {
        guard units > 0 else { return 0 }
        let steps = (units / minimumStep + 1e-9).rounded(.down)
        return max(0, steps * minimumStep)
    }
}

/// 大剂量（bolus）报文层。
///
/// 报文定义全部来自 pumpX2 的 Java 实现，并用其抓包十六进制向量逐字节核对过：
///
/// | 报文 | opCode | cargo |
/// |---|---|---|
/// | `BolusPermissionRequest` | 0xA2 | 0 |
/// | `BolusPermissionResponse` | 0xA3 | 6 |
/// | `InitiateBolusRequest` | 0x9E | 37（签名后 61） |
/// | `InitiateBolusResponse` | 0x9F | 6 |
/// | `CancelBolusRequest` | 0xA0 | 4 |
/// | `CancelBolusResponse` | 0xA1 | 5 |
/// | `BolusPermissionReleaseRequest` | 0xF0 | 4 |
/// | `CurrentBolusStatusRequest` | 0x2C | 0 |
/// | `CurrentBolusStatusResponse` | 0x2D | 15 |
///
/// 顺序是固定的：**先要授权拿 bolusId，再用 bolusId 发起**。跳过授权直接发 0x9E，
/// 泵会以「无效输注状态」拒绝。授权没被用掉就要释放，否则泵认为另一台设备
/// 正持有这次输注的许可。
public enum BolusMessages {

    /// `BolusDeliveryHistoryLog.BolusType` 的位掩码
    public enum TypeMask {
        public static let now: UInt8 = 1
        public static let later: UInt8 = 2
        public static let override: UInt8 = 4
        public static let correction: UInt8 = 8
        public static let carb: UInt8 = 16
    }

    public enum BolusError: Error, Equatable, LocalizedError {
        case doseBelowMinimum
        case invalidBolusId
        case permissionDenied(reason: String)

        public var errorDescription: String? {
            switch self {
            case .doseBelowMinimum:
                return "剂量小于泵的最小步进（0.05 U）"
            case .invalidBolusId:
                return "泵没有给出有效的 bolusId，不能发起输注"
            case let .permissionDenied(reason):
                return "泵拒绝了这次输注授权：\(reason)"
            }
        }
    }

    // MARK: 授权 0xA2 / 0xA3

    public static func permissionRequest() -> PumpMessage {
        PumpMessage.request(characteristic: .control, opCode: 0xA2, cargo: [], signed: true)
    }

    public struct Permission: Equatable, Sendable {
        /// 泵回的原始状态字。真机抓包里见过非 0（0x1e=30）但 nackReason 为 0 且给了 bolusId，
        /// 所以判定「是否给号」看 bolusId 与 nackReason，status 只作记录。
        public let status: Int
        public let bolusId: Int
        public let nackReason: Int

        public var granted: Bool { nackReason == 0 && bolusId > 0 }

        public var nackDescription: String {
            switch nackReason {
            case 0: return "已授权"
            case 1: return "泵当前状态不允许输注（可能正在换筒、排气或已暂停）"
            case 3: return "已有另一处持有输注许可（另一台手机或手表）"
            default: return "未知原因（nackReason=\(nackReason)）"
            }
        }
    }

    public static func parsePermission(_ cargo: [UInt8]) -> Permission? {
        guard cargo.count >= 6 else { return nil }
        return Permission(status: Int(cargo[0]),
                          bolusId: leU16(cargo, 1),
                          nackReason: Int(cargo[5]))
    }

    // MARK: 发起 0x9E / 0x9F

    /// cargo 布局（37 字节，全部小端）：
    /// ```
    /// 0  u32 totalVolume        （毫单位）
    /// 4  u16 bolusId
    /// 6  u16 保留 0
    /// 8  u8  bolusTypeBitmask
    /// 9  u32 foodVolume          （毫单位，仅元数据）
    /// 13 u32 correctionVolume    （毫单位，仅元数据）
    /// 17 u16 carbs               （g，仅元数据）
    /// 19 u16 bg                  （mg/dL，仅元数据）
    /// 21 u32 iob                 （毫单位，仅元数据）
    /// 25 u32 extendedVolume       （0 = 普通大剂量）
    /// 29 u32 extendedSeconds
    /// 33 u32 extended3
    /// ```
    /// 「仅元数据」的意思是这些字段进历史记录与泵上的 bolus 计算展示，不改变实际输注量；
    /// 真正决定打进多少的只有 totalVolume。
    public static func initiateBolus(units: Double,
                                     bolusId: Int,
                                     typeBitmask: UInt8 = TypeMask.now,
                                     foodVolumeUnits: Double = 0,
                                     correctionVolumeUnits: Double = 0,
                                     carbsGrams: Int = 0,
                                     bgMgdl: Int = 0,
                                     iobUnits: Double = 0) throws -> PumpMessage {
        let totalMilli = InsulinUnit.toMilli(units)
        guard totalMilli >= InsulinUnit.toMilli(InsulinUnit.minimumStep) else {
            throw BolusError.doseBelowMinimum
        }
        guard bolusId > 0, bolusId <= 0xFFFF else { throw BolusError.invalidBolusId }

        var cargo: [UInt8] = []
        cargo += leU32Bytes(totalMilli)
        cargo += leU16Bytes(bolusId)
        cargo += [0, 0]
        cargo += [typeBitmask]
        cargo += leU32Bytes(max(0, InsulinUnit.toMilli(foodVolumeUnits)))
        cargo += leU32Bytes(max(0, InsulinUnit.toMilli(correctionVolumeUnits)))
        cargo += leU16Bytes(max(0, carbsGrams))
        cargo += leU16Bytes(max(0, bgMgdl))
        cargo += leU32Bytes(max(0, InsulinUnit.toMilli(iobUnits)))
        cargo += leU32Bytes(0)   // extendedVolume
        cargo += leU32Bytes(0)   // extendedSeconds
        cargo += leU32Bytes(0)   // extended3

        precondition(cargo.count == 37, "InitiateBolusRequest cargo 必须是 37 字节")
        return PumpMessage.request(characteristic: .control, opCode: 0x9E, cargo: cargo, signed: true)
    }

    public struct InitiateResult: Equatable, Sendable {
        public let status: Int
        public let bolusId: Int
        /// 0 = 已接受待执行；2 = 被更高优先级请求撤销
        public let statusType: Int

        public var accepted: Bool { status == 0 && statusType == 0 }
    }

    public static func parseInitiate(_ cargo: [UInt8]) -> InitiateResult? {
        guard cargo.count >= 6 else { return nil }
        return InitiateResult(status: Int(cargo[0]),
                              bolusId: leU16(cargo, 1),
                              statusType: Int(cargo[5]))
    }

    // MARK: 取消 0xA0 / 0xA1

    public static func cancelBolus(bolusId: Int) throws -> PumpMessage {
        guard bolusId > 0, bolusId <= 0xFFFF else { throw BolusError.invalidBolusId }
        return PumpMessage.request(characteristic: .control, opCode: 0xA0,
                                   cargo: leU16Bytes(bolusId) + [0, 0], signed: true)
    }

    public struct CancelResult: Equatable, Sendable {
        public let status: Int
        public let bolusId: Int
        public let reason: Int

        /// status 0 + reason 0 才是真的取消成功
        public var cancelled: Bool { status == 0 && reason == 0 }
    }

    public static func parseCancel(_ cargo: [UInt8]) -> CancelResult? {
        guard cargo.count >= 4 else { return nil }
        return CancelResult(status: Int(cargo[0]), bolusId: leU16(cargo, 1), reason: Int(cargo[3]))
    }

    // MARK: 释放授权 0xF0 / 0xF1

    public static func releasePermission(bolusId: Int) throws -> PumpMessage {
        guard bolusId > 0, bolusId <= 0xFFFF else { throw BolusError.invalidBolusId }
        return PumpMessage.request(characteristic: .control, opCode: 0xF0,
                                   cargo: leU16Bytes(bolusId) + [0, 0], signed: true)
    }

    /// 返回 0 表示释放成功
    public static func parseRelease(_ cargo: [UInt8]) -> Int? {
        guard let first = cargo.first else { return nil }
        return Int(first)
    }

    // MARK: 当前输注状态 0x2C / 0x2D

    public static func currentBolusStatusRequest() -> PumpMessage {
        PumpMessage.request(characteristic: .currentStatus, opCode: 0x2C)
    }

    public struct BolusState: Equatable, Sendable {
        /// 0 = 已完成或无效，1 = 正在输注，2 = 请求已受理等待开始
        public let statusId: Int
        public let bolusId: Int
        /// 泵自己的计时，不是 Unix 时间
        public let timestamp: Int
        public let requestedMilli: Int
        public let sourceId: Int
        public let typeBitmask: Int

        public var requestedUnits: Double { InsulinUnit.fromMilli(requestedMilli) }
        public var isDelivering: Bool { statusId == 1 || statusId == 2 }
        public var statusName: String {
            switch statusId {
            case 0: return bolusId == 0 ? "无进行中的大剂量" : "已完成/已失效"
            case 1: return "正在输注"
            case 2: return "等待开始"
            default: return "未知状态(\(statusId))"
            }
        }
    }

    public static func parseCurrentBolus(_ cargo: [UInt8]) -> BolusState? {
        guard cargo.count >= 15 else { return nil }
        return BolusState(statusId: Int(cargo[0]),
                          bolusId: leU16(cargo, 1),
                          timestamp: Int(leU32(cargo, 5)),
                          requestedMilli: Int(leU32(cargo, 9)),
                          sourceId: Int(cargo[13]),
                          typeBitmask: Int(cargo[14]))
    }

    // MARK: 字节序

    static func leU16(_ b: [UInt8], _ o: Int) -> Int {
        Int(b[o]) | Int(b[o + 1]) << 8
    }

    static func leU32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    static func leU16Bytes(_ v: Int) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
    }

    static func leU32Bytes(_ v: Int) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
}
