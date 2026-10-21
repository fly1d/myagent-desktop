import Foundation
import Security
import LocalAuthentication

@MainActor
protocol CredentialStore {
    func read(_ account: String, allowInteraction: Bool) throws -> String?
    func save(_ secret: String, account: String) throws
    func remove(_ account: String) throws
}

/// A separate service can be supplied for isolated Keychain integration tests.
struct KeychainCredentialStore: CredentialStore {
    let service: String
    let allowsUserInteraction: Bool

    init(service: String = "dev.myagent.desktop.providers", allowsUserInteraction: Bool = true) {
        self.service = service
        self.allowsUserInteraction = allowsUserInteraction
    }

    private func context(_ allowed: Bool) -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = !(allowed && allowsUserInteraction)
        return context
    }

    func read(_ account: String, allowInteraction: Bool = false) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
                                    kSecUseAuthenticationContext as String: context(allowInteraction)]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data, let text = String(data: data, encoding: .utf8) else {
            let explanation = status == errSecInteractionNotAllowed ? "钥匙串尚未解锁或需要你确认访问。请在模型配置中重新测试连接。" : "无法读取此应用的钥匙串凭据（\(status)）。"
            throw AppFailure.message(explanation)
        }
        return text
    }

    func save(_ secret: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account,
                                   kSecUseAuthenticationContext as String: context(true)]
        let update: [String: Any] = [kSecValueData as String: Data(secret.utf8)]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(secret.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AppFailure.message("保存钥匙串凭据失败（\(status)）。") }
    }

    func remove(_ account: String) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account,
                                   kSecUseAuthenticationContext as String: context(true)] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AppFailure.message("移除钥匙串凭据失败（\(status)）。") }
    }
}
