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
    public static let pump = "7B83FFF5-9F77-4E5C-8064-AAE2C24838B9"
    public static let cccd = "00002902-0000-1000-8000-00805F9B34FB"
    public static let deviceName = "00002A00-0000-1000-8000-00805F9B34FB"
    public static let modelNumber = "00002A24-0000-1000-8000-00805F9B34FB"
    public static let serialNumber = "00002A25-0000-1000-8000-00805F9B34FB"
    public static let softwareRevision = "00002A28-0000-1000-8000-00805F9B34FB"
    public static let manufacturerName = "00002A29-0000-1000-8000-00805F9B34FB"
}
