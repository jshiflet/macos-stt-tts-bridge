import Foundation
import Security

/// Persists the HTTP auth token in the macOS Keychain instead of UserDefaults
/// so it is encrypted at rest and invisible to `defaults read`. Sandboxed apps
/// can read/write their own generic password items without any extra entitlement.
enum KeychainAuthToken {
    /// Item identifier. Scoped per-app by the system using the app's signing identity,
    /// so multiple apps can't collide on this name.
    private static let service = "STTBridge.authToken"
    private static let account = "default"

    /// Returns the stored token, or nil if none exists / Keychain is unavailable.
    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            print("KeychainAuthToken.load failed: OSStatus \(status)")
            return nil
        }
    }

    /// Stores or replaces the token. Returns true on success.
    @discardableResult
    static func save(_ token: String) -> Bool {
        let data = Data(token.utf8)
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updates: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        let updateStatus = SecItemUpdate(lookup as CFDictionary, updates as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        if updateStatus == errSecItemNotFound {
            var add = lookup
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus == errSecSuccess { return true }
            print("KeychainAuthToken.save (add) failed: OSStatus \(addStatus)")
            return false
        }

        print("KeychainAuthToken.save (update) failed: OSStatus \(updateStatus)")
        return false
    }

    /// Removes the stored token. No-op if none exists.
    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            print("KeychainAuthToken.delete failed: OSStatus \(status)")
        }
    }
}
