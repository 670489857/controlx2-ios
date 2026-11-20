import Foundation
import Security

/// 极小的 Keychain 封装。
///
/// 只放 Nightscout 的 API Secret 和访问令牌——它们是"拿着就能读你血糖数据"的东西，
/// 不该和一堆界面状态一起躺在 UserDefaults 的明文 plist 里（iTunes 备份、越狱文件浏览器都能直接看到）。
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` 是刻意选的：
/// 开机第一次解锁之后才可读（后台保活需要），且不随 iCloud 钥匙串同步到别的设备。
enum Keychain {

    private static let service = "com.controlx2.nightscout"

    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // 先删再写：SecItemAdd 遇到同键会返回 errSecDuplicateItem，
        // 而 update 又要分两种情况处理，不如统一走"清掉旧的再放新的"。
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return true }

        var attributes = base
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
