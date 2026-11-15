import Foundation

/// GATT 特征值。UUID 与 pumpX2 `CharacteristicUUID` 一致（Tandem 私有 128 位 UUID）。
public enum Characteristic: String, CaseIterable, Sendable {
    case currentStatus = "7B83FFF6-9F77-4E5C-8064-AAE2C24838B9"
    case qualifyingEvent = "7B83FFF7-9F77-4E5C-8064-AAE2C24838B9"
    case historyLog = "7B83FFF8-9F77-4E5C-8064-AAE2C24838B9"
    case authorization = "7B83FFF9-9F77-4E5C-8064-AAE2C24838B9"
    case control = "7B83FFFC-9F77-4E5C-8064-AAE2C24838B9"
    case controlStream = "7B83FFFD-9F77-4E5C-8064-AAE2C24838B9"

    public var uuidString: String { rawValue }

    /// 需要写入的特征值（其余只用于通知）
    public var isWritable: Bool { self == .authorization || self == .control || self == .currentStatus }
}

public enum ServiceUUID {
    /// Tandem 的 GATT 主服务。这是标准 16 位 UUID `0xFDFB` 的 128 位展开形式，
    /// 不是按特征值序号推出来的 `7B83FFF5-…`——后者在真实泵上不存在。
    /// 写错它的后果很隐蔽：连接能建立、`discoverServices` 正常回调，
    /// 只是返回空列表，然后所有写入都卡在"等待就绪"直到超时。
    public static let pump = "0000FDFB-0000-1000-8000-00805F9B34FB"
    /// 泵若以 16 位短格式广播，CBUUID.uuidString 会缩成这个
    public static let pumpShort = "FDFB"
    public static let cccd = "00002902-0000-1000-8000-00805F9B34FB"
    public static let deviceName = "00002A00-0000-1000-8000-00805F9B34FB"
    public static let modelNumber = "00002A24-0000-1000-8000-00805F9B34FB"
    public static let serialNumber = "00002A25-0000-1000-8000-00805F9B34FB"
    public static let softwareRevision = "00002A28-0000-1000-8000-00805F9B34FB"
    public static let manufacturerName = "00002A29-0000-1000-8000-00805F9B34FB"
}
