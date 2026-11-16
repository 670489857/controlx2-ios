import Foundation

/// 基础率计划（IDP = Insulin Delivery Profile）的**只读**报文层。
///
/// 为什么只有读：pumpX2 里 `SetTempRateRequest` / `SuspendPumpingRequest` /
/// `ResumePumpingRequest` / `CreateIDPRequest` / `SetIDPSegmentRequest` 全部标着
/// `supportedDevices=MOBI_ONLY`，也就是只有 t:slim Mobi 认这些报文。X2 固件收到
/// 这些 opCode 不会执行，回的是 Nack。**这不是我们没写，是泵不收**——所以这里
/// 不提供任何会改变基础率的接口，只在 UI 上把这条边界写清楚。
///
/// 能读的三条报文（都来自 pumpX2，并用其抓包向量核对过）：
///
/// | 报文 | opCode | cargo |
/// |---|---|---|
/// | `ProfileStatusRequest` | 0x3E | 0 |
/// | `ProfileStatusResponse` | 0x3F | 8 |
/// | `IDPSettingsRequest` | 0x40 | 1（idpId） |
/// | `IDPSettingsResponse` | 0x41 | 23 |
/// | `IDPSegmentRequest` | 0x42 | 2（idpId, segmentIndex） |
/// | `IDPSegmentResponse` | 0x43 | 15 |
///
/// **段索引是 0 基**。upstream 的 `IDPManager` 里是 `for (int i=0; i<segmentCount; i++)`，
/// 而 `InsulinDeliveryProfileRequestBuilder` 写成了 `1...numberOfProfileSegments`（差一位）。
/// 按那个差一位的循环去读，最后一条会越界；越界时泵回 ErrorResponse 并**直接断开蓝牙**，
/// 现场表现就是「读个基础率，连接突然没了」。这里只读 `0..<segmentCount`。
public enum ProfileMessages {

    public enum ProfileError: Error, Equatable, LocalizedError {
        case noActiveProfile
        case badSettingsCargo
        case badSegmentCargo

        public var errorDescription: String? {
            switch self {
            case .noActiveProfile: return "泵没有报告当前基础率计划"
            case .badSettingsCargo: return "基础率计划设置报文长度不符"
            case .badSegmentCargo: return "基础率时段报文长度不符"
            }
        }
    }

    /// 0x3F：当前激活的是哪个计划、一共有几个计划
    public struct Status: Equatable, Sendable {
        public var numberOfProfiles: Int
        /// 槽位里的计划 ID，`-1` 表示该槽为空。槽位 0 就是正在生效的那个。
        public var slotIds: [Int]
        public var activeSegmentIndex: Int

        /// 当前生效的计划 ID
        public var activeIdpId: Int? {
            guard let first = slotIds.first, first >= 0 else { return nil }
            return first
        }
    }

    /// 0x41：计划名称、段数、胰岛素作用时长、泵上设的单次大剂量上限
    public struct Settings: Equatable, Sendable {
        public var idpId: Int
        public var name: String
        public var segmentCount: Int
        public var insulinDurationMinutes: Int
        /// 泵里设的单次大剂量上限（U）。这个值来自抓包核对过的字段，
        /// 比读 0x8C 可靠——0x8C 的单位一直没在抓包里确证。
        public var maxBolusUnits: Double
        public var carbEntry: Bool
    }

    /// 0x43：一个时间段的四个参数
    public struct Segment: Equatable, Sendable {
        public var idpId: Int
        public var index: Int
        public var startMinutes: Int
        public var basalRateUnitsPerHour: Double
        /// 碳水比，克/单位。泵里存的是 1000 倍（6 g/U 存成 6000）。
        public var carbRatioGramsPerUnit: Double
        public var targetBgMgdl: Int
        /// 胰岛素敏感系数（mg/dL 每单位）
        public var isfMgdlPerUnit: Int
        /// 哪些字段是用户填过的位掩码
        public var statusBitmask: Int

        /// `06:00` 这样的显示文本
        public var startText: String {
            let h = startMinutes / 60
            let m = startMinutes % 60
            return String(format: "%02d:%02d", h, m)
        }
    }

    // MARK: 请求

    public static func profileStatusRequest() -> PumpMessage {
        PumpMessage.request(characteristic: .currentStatus, opCode: 0x3E)
    }

    public static func settingsRequest(idpId: Int) -> PumpMessage {
        PumpMessage.request(characteristic: .currentStatus, opCode: 0x40,
                            cargo: [UInt8(idpId & 0xFF)])
    }

    public static func segmentRequest(idpId: Int, index: Int) -> PumpMessage {
        PumpMessage.request(characteristic: .currentStatus, opCode: 0x42,
                            cargo: [UInt8(idpId & 0xFF), UInt8(index & 0xFF)])
    }

    // MARK: 解析

    public static func parseStatus(_ cargo: [UInt8]) -> Status? {
        guard cargo.count >= 8 else { return nil }
        let slots = (1...6).map { i -> Int in
            let raw = cargo[i]
            return raw == 0xFF ? -1 : Int(raw)
        }
        return Status(numberOfProfiles: Int(cargo[0]),
                      slotIds: slots,
                      activeSegmentIndex: Int(cargo[7]))
    }

    public static func parseSettings(_ cargo: [UInt8]) -> Settings? {
        guard cargo.count >= 23 else { return nil }
        let nameBytes = Array(cargo[1..<17])
        let name = String(decoding: nameBytes.prefix { $0 != 0 }, as: UTF8.self)
        return Settings(idpId: Int(cargo[0]),
                        name: name.isEmpty ? "未命名" : name,
                        segmentCount: Int(cargo[17]),
                        insulinDurationMinutes: Int(BolusMessages.leU16(cargo, 18)),
                        maxBolusUnits: InsulinUnit.fromMilli(Int(BolusMessages.leU16(cargo, 20))),
                        carbEntry: cargo[22] != 0)
    }

    public static func parseSegment(_ cargo: [UInt8]) -> Segment? {
        guard cargo.count >= 15 else { return nil }
        return Segment(idpId: Int(cargo[0]),
                       index: Int(cargo[1]),
                       startMinutes: Int(BolusMessages.leU16(cargo, 2)),
                       basalRateUnitsPerHour: InsulinUnit.fromMilli(Int(BolusMessages.leU16(cargo, 4))),
                       carbRatioGramsPerUnit: Double(BolusMessages.leU32(cargo, 6)) / 1000.0,
                       targetBgMgdl: Int(BolusMessages.leU16(cargo, 10)),
                       isfMgdlPerUnit: Int(BolusMessages.leU16(cargo, 12)),
                       statusBitmask: Int(cargo[14]))
    }
}
