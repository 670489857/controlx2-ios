import Foundation

/// 一次成功配对后需要长期保存的凭据。
/// 泵端按 `appInstanceId` 记住这台设备，`derivedSecret` 用于后续的快速确认（第 3、4 步）。
public struct PumpCredentials: Codable, Equatable, Sendable {
    public var appInstanceId: UInt16
    public var derivedSecret: [UInt8]
    /// 记录时间，便于将来做失效淘汰
    public var pairedAt: Date

    public init(appInstanceId: UInt16, derivedSecret: [UInt8], pairedAt: Date = Date()) {
        self.appInstanceId = appInstanceId
        self.derivedSecret = derivedSecret
        self.pairedAt = pairedAt
    }
}

public protocol CredentialStore: AnyObject {
    func load(for key: String) -> PumpCredentials?
    func save(_ credentials: PumpCredentials, for key: String)
    func delete(for key: String)
}

/// 测试与 Linux 环境使用
public final class InMemoryCredentialStore: CredentialStore {
    private var items: [String: PumpCredentials] = [:]
    private let lock = NSLock()

    public init() {}

    public func load(for key: String) -> PumpCredentials? {
        lock.lock(); defer { lock.unlock() }
        return items[key]
    }

    public func save(_ credentials: PumpCredentials, for key: String) {
        lock.lock(); defer { lock.unlock() }
        items[key] = credentials
    }

    public func delete(for key: String) {
        lock.lock(); defer { lock.unlock() }
        items.removeValue(forKey: key)
    }
}

#if canImport(Security)
import Security

/// Keychain 存储。条目为 `kSecClassGenericPassword`，按 service + account（设备 UUID）索引。
/// 使用 `AfterFirstUnlockThisDeviceOnly`：后台唤醒时可读，且不随 iCloud 备份迁移到别的设备。
public final class KeychainCredentialStore: CredentialStore {
    private let service: String

    public init(service: String = "org.controlx2.pump-credentials") {
        self.service = service
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    public func load(for key: String) -> PumpCredentials? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(PumpCredentials.self, from: data)
    }

    public func save(_ credentials: PumpCredentials, for key: String) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        SecItemDelete(baseQuery(key) as CFDictionary)
        var query = baseQuery(key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    public func delete(for key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }
}
#endif
