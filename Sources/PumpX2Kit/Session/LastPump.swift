import Foundation

/// 上次连上的泵。
///
/// 记它的唯一理由是启动落地：iOS 允许用 `retrievePeripherals(withIdentifiers:)`
/// 直接连回见过的设备，不需要重新扫描。只要还记着这个 UUID，
/// 打开 App 就能自己连回去，而不是先摆一份设备列表等用户点。
public struct LastPump: Equatable, Sendable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

public protocol LastPumpStore: AnyObject {
    func load() -> LastPump?
    func save(_ pump: LastPump)
    func clear()
}

/// 存在 UserDefaults 里。它只是「上次是哪一台」，不是凭据——
/// 凭据在 Keychain，删掉这里最多多点一下列表，不涉及安全性。
public final class UserDefaultsLastPumpStore: LastPumpStore {
    private let defaults: UserDefaults
    private static let idKey = "controlx2.lastPumpID"
    private static let nameKey = "controlx2.lastPumpName"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> LastPump? {
        guard let raw = defaults.string(forKey: Self.idKey),
              let id = UUID(uuidString: raw) else { return nil }
        // 名字只是给人看的，缺了不影响连接
        let name = defaults.string(forKey: Self.nameKey) ?? "泵"
        return LastPump(id: id, name: name)
    }

    public func save(_ pump: LastPump) {
        defaults.set(pump.id.uuidString, forKey: Self.idKey)
        defaults.set(pump.name, forKey: Self.nameKey)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.idKey)
        defaults.removeObject(forKey: Self.nameKey)
    }
}

/// 启动后落在哪一页。
public enum LaunchDestination: Equatable, Sendable {
    /// 直接进状态页，连接在后台补
    case dashboard(pump: LastPump)
    /// 只能从扫描页开始
    case discovery
}

public enum LaunchRouter {
    /// 只有「记得上次是哪台」且「它的凭据还在」时才敢直接进状态页。
    ///
    /// 两个条件缺一不可：只有 UUID 没有凭据，进去也只能停在配对页，
    /// 不如老老实实扫描；反过来有凭据却不知道连哪台，同样无从下手。
    public static func destination(lastPump: LastPump?, hasCredentials: Bool) -> LaunchDestination {
        guard let pump = lastPump, hasCredentials else { return .discovery }
        return .dashboard(pump: pump)
    }
}
