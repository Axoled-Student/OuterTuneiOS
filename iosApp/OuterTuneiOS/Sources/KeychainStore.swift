import Foundation
import Security

/// Small keychain wrapper for the long-lived credentials the app holds:
/// Spotify OAuth tokens and the AI gateway key.
///
/// These are bearer credentials for third-party accounts, so they do not belong
/// in UserDefaults (which is plain plist inside the app container and is copied
/// into unencrypted backups).
enum KeychainStore {
    /// `kSecAttrAccessibleAfterFirstUnlock` so background playback can still
    /// refresh a Spotify token while the device is locked.
    private static let accessibility = kSecAttrAccessibleAfterFirstUnlock

    static func set(_ value: String?, service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else {
            return
        }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = accessibility
        SecItemAdd(insert as CFDictionary, nil)
    }

    static func get(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
