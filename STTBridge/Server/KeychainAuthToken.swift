import Foundation
import Security

/// Low-level Keychain helper for a single string secret, scoped per-(service, account).
/// Used by `KeychainAuthToken` for the HTTP auth token and `KeychainTLSPassword`
/// for the PKCS#12 passphrase.
enum KeychainSecret {
    /// Returns the stored value, or nil if none exists / Keychain is unavailable.
    static func load(service: String, account: String = "default") -> String? {
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
            print("KeychainSecret.load(\(service)) failed: OSStatus \(status)")
            return nil
        }
    }

    /// Stores or replaces the value. Returns true on success.
    @discardableResult
    static func save(service: String, account: String = "default", value: String) -> Bool {
        let data = Data(value.utf8)
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
            print("KeychainSecret.save(\(service)) add failed: OSStatus \(addStatus)")
            return false
        }

        print("KeychainSecret.save(\(service)) update failed: OSStatus \(updateStatus)")
        return false
    }

    /// Removes the stored value. No-op if none exists.
    static func delete(service: String, account: String = "default") {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            print("KeychainSecret.delete(\(service)) failed: OSStatus \(status)")
        }
    }
}

/// Persists the HTTP auth token in the macOS Keychain instead of UserDefaults
/// so it is encrypted at rest and invisible to `defaults read`.
enum KeychainAuthToken {
    private static let service = "STTBridge.authToken"

    static func load() -> String? { KeychainSecret.load(service: service) }

    @discardableResult
    static func save(_ token: String) -> Bool { KeychainSecret.save(service: service, value: token) }

    static func delete() { KeychainSecret.delete(service: service) }
}

/// Persists the PKCS#12 passphrase used to unlock the TLS certificate bundle.
enum KeychainTLSPassword {
    private static let service = "STTBridge.tlsP12Password"

    static func load() -> String? { KeychainSecret.load(service: service) }

    @discardableResult
    static func save(_ password: String) -> Bool { KeychainSecret.save(service: service, value: password) }

    static func delete() { KeychainSecret.delete(service: service) }
}
