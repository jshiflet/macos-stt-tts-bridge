import Foundation

// All three wrappers reuse `KeychainSecret` from `KeychainAuthToken.swift`.
// Per-directory `account` keying keeps Let's Encrypt prod and staging accounts
// (and any other CA the user might point at) from clobbering each other in the
// macOS Keychain.

/// Persists the Cloudflare API token used to publish DNS-01 TXT records. A
/// single token covers every domain the user issues for in this app, so we
/// store it under one default account.
enum KeychainCloudflareToken {
    private static let service = "STTBridge.cloudflareAPIToken"

    static func load() -> String? { KeychainSecret.load(service: service) }

    @discardableResult
    static func save(_ token: String) -> Bool { KeychainSecret.save(service: service, value: token) }

    static func delete() { KeychainSecret.delete(service: service) }
}

/// Persists the per-CA ACME account private key as PEM. Indexed by the
/// directory host so prod and staging keys don't overwrite each other.
enum KeychainACMEAccountKey {
    private static let service = "STTBridge.acmeAccountKey"

    static func load(directoryHost: String) -> String? {
        KeychainSecret.load(service: service, account: directoryHost)
    }

    @discardableResult
    static func save(_ keyPEM: String, directoryHost: String) -> Bool {
        KeychainSecret.save(service: service, account: directoryHost, value: keyPEM)
    }

    static func delete(directoryHost: String) {
        KeychainSecret.delete(service: service, account: directoryHost)
    }
}

/// Persists the account URL returned by the CA's newAccount endpoint, so we
/// don't re-register on every launch. Same per-directory keying as the key
/// itself; the URL is sensitive only inasmuch as it identifies the account.
enum KeychainACMEAccountURL {
    private static let service = "STTBridge.acmeAccountURL"

    static func load(directoryHost: String) -> String? {
        KeychainSecret.load(service: service, account: directoryHost)
    }

    @discardableResult
    static func save(_ url: String, directoryHost: String) -> Bool {
        KeychainSecret.save(service: service, account: directoryHost, value: url)
    }

    static func delete(directoryHost: String) {
        KeychainSecret.delete(service: service, account: directoryHost)
    }
}
