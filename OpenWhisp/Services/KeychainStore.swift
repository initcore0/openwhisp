import Foundation
import Security

/// macOS Keychain-backed `SecretStore`. The Apple-only `Security` (`SecItem*`)
/// calls are isolated here; AppState depends on the `SecretStore` protocol, not
/// this type, so a port supplies its own backend.
final class KeychainStore: SecretStore {
    private static let service = "com.openwhisp.app"

    func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ value: String, key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key
        ]

        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                print("[KeychainStore] delete failed for \(key): OSStatus \(status)")
            }
            return
        }

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            if addStatus != errSecSuccess {
                print("[KeychainStore] add failed for \(key): OSStatus \(addStatus)")
            }
        } else if status != errSecSuccess {
            // e.g. errSecAuthFailed / errSecUserCanceled (denied ACL prompt on a
            // re-signed build) or errSecInteractionNotAllowed (locked keychain).
            // The value is NOT persisted — at least leave a trace in the log.
            print("[KeychainStore] update failed for \(key): OSStatus \(status)")
        }
    }
}
