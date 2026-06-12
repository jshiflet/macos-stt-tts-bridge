import Foundation

/// Brings an externally-created ACME account into the Keychain so the user can
/// reuse an account they already registered elsewhere (e.g. via certbot or
/// lego) instead of going through `ACMECoordinator.registerAccount()`.
///
/// We don't cryptographically verify the key here — AcmeSwift will reject it
/// on first use if it's malformed. The structural check below catches the
/// common copy/paste mistakes (no BEGIN line, wrong type, truncated body).
enum ACMEAccountImporter {

    /// Validates the inputs and writes them to the per-CA Keychain entries.
    /// Throws `ACMEError.invalidAccountKey` or `.invalidAccountURL` so the UI
    /// can highlight the offending field.
    static func importAccount(keyPEM: String, accountURL: String, for ca: ACMECA) throws {
        let trimmedKey = keyPEM.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidPrivateKeyPEM(trimmedKey) else {
            throw ACMEError.invalidAccountKey
        }
        let trimmedURL = accountURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL), url.scheme?.hasPrefix("http") == true else {
            throw ACMEError.invalidAccountURL
        }

        let host = ca.directoryHost
        guard KeychainACMEAccountKey.save(trimmedKey, directoryHost: host),
              KeychainACMEAccountURL.save(url.absoluteString, directoryHost: host) else {
            throw ACMEError.underlying("Could not write account to Keychain.")
        }
    }

    /// Wraps `importAccount` for NSOpenPanel-supplied file URLs. Uses the
    /// same security-scoped resource dance as `CertificateStore.importFile`
    /// in TLSSupport.swift so a sandboxed open panel works.
    static func importFromFile(keyURL: URL, accountURL: String, for ca: ACMECA) throws {
        let accessing = keyURL.startAccessingSecurityScopedResource()
        defer { if accessing { keyURL.stopAccessingSecurityScopedResource() } }

        let raw: Data
        do {
            raw = try Data(contentsOf: keyURL)
        } catch {
            throw ACMEError.underlying("Could not read key file: \(error.localizedDescription)")
        }
        guard let pem = String(data: raw, encoding: .utf8) else {
            throw ACMEError.invalidAccountKey
        }
        try importAccount(keyPEM: pem, accountURL: accountURL, for: ca)
    }

    /// Removes both the key and the account URL for the supplied CA.
    static func forgetAccount(for ca: ACMECA) {
        let host = ca.directoryHost
        KeychainACMEAccountKey.delete(directoryHost: host)
        KeychainACMEAccountURL.delete(directoryHost: host)
    }

    // MARK: - Structural PEM check

    /// Loose validation: must contain a `BEGIN ... PRIVATE KEY` line and a
    /// matching `END` line, and the base64 body must be non-empty. ECDSA, RSA,
    /// Ed25519, and PKCS#8-wrapped variants all use one of the well-known
    /// label strings below.
    private static func isValidPrivateKeyPEM(_ pem: String) -> Bool {
        let acceptedBeginLabels = [
            "PRIVATE KEY",
            "EC PRIVATE KEY",
            "RSA PRIVATE KEY"
        ]
        let lines = pem.split(separator: "\n").map(String.init)
        guard let beginIdx = lines.firstIndex(where: { line in
            acceptedBeginLabels.contains { line.contains("BEGIN \($0)") }
        }) else { return false }
        guard let endIdx = lines.firstIndex(where: { line in
            acceptedBeginLabels.contains { line.contains("END \($0)") }
        }), endIdx > beginIdx else { return false }
        let body = lines[(beginIdx + 1)..<endIdx].joined()
        return !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
