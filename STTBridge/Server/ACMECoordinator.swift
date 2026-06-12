import Foundation
import AcmeSwift
import X509
import SwiftASN1

/// Orchestrates the end-to-end ACME flow: account registration, ordering,
/// DNS-01 challenge publication via Cloudflare, DNS propagation polling,
/// finalisation, and install of the resulting cert chain into
/// `CertificateStore` so the existing NIO TLS pipeline picks it up after
/// `ServerManager.reload()`.
///
/// Runs on the main actor — the work is network-bound and AcmeSwift's async
/// methods hop off the main thread anyway, so there's no performance benefit
/// to being a free-standing actor and significant ergonomic benefit to
/// matching the rest of the app's @MainActor-by-default isolation.
@MainActor
final class ACMECoordinator {

    /// Lightweight pub-sub for live status updates. The UI subscribes via the
    /// `events` stream; the coordinator writes via the `continuation`.
    private var continuation: AsyncStream<ACMEStatus>.Continuation?
    nonisolated let events: AsyncStream<ACMEStatus>

    private let cloudflare: CloudflareDNSProvider
    private let resolver: DNSResolver

    init(cloudflare: CloudflareDNSProvider? = nil, resolver: DNSResolver? = nil) {
        self.cloudflare = cloudflare ?? CloudflareDNSProvider()
        self.resolver = resolver ?? DNSResolver()
        var savedContinuation: AsyncStream<ACMEStatus>.Continuation?
        self.events = AsyncStream { cont in savedContinuation = cont }
        self.continuation = savedContinuation
    }

    private func emit(_ status: ACMEStatus) {
        continuation?.yield(status)
    }

    // MARK: - Public surface

    /// Idempotently registers an ACME account with the CA. Short-circuits if a
    /// key + URL pair is already on file for this CA's directory host. Returns
    /// the account URL the CA assigned.
    @discardableResult
    func registerAccount() async throws -> URL {
        let config = ACMEConfig()
        guard !config.accountEmail.isEmpty else { throw ACMEError.missingEmail }
        let host = config.ca.directoryHost

        // Already registered? Skip the network call.
        if let urlString = KeychainACMEAccountURL.load(directoryHost: host),
           let url = URL(string: urlString),
           KeychainACMEAccountKey.load(directoryHost: host) != nil {
            persistRegistered(true, urlString: urlString)
            return url
        }

        emit(.running(stage: "Registering with \(config.ca.displayName)…"))
        let acme = try await AcmeSwift(acmeEndpoint: endpointFor(ca: config.ca))
        defer { try? acme.syncShutdown() }

        let info = try await acme.account.create(
            contacts: ["mailto:\(config.accountEmail)"],
            acceptTOS: true
        )
        guard let keyPEM = info.privateKeyPem, let accountURL = info.url else {
            throw ACMEError.underlying("CA did not return account key or URL.")
        }
        _ = KeychainACMEAccountKey.save(keyPEM, directoryHost: host)
        _ = KeychainACMEAccountURL.save(accountURL.absoluteString, directoryHost: host)
        persistRegistered(true, urlString: accountURL.absoluteString)
        emit(.idle)
        return accountURL
    }

    /// Reads the CA's directory and returns the names listed under
    /// `meta.profiles` (RFC 9773). Empty array means the CA doesn't advertise
    /// any profiles.
    nonisolated func fetchAvailableProfiles() async throws -> [String] {
        let directoryURL = await MainActor.run { ACMEConfig().ca.directoryURL }
        var request = URLRequest(url: directoryURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        if let meta = json["meta"] as? [String: Any] {
            if let dict = meta["profiles"] as? [String: Any] {
                return Array(dict.keys).sorted()
            }
            if let arr = meta["profiles"] as? [String] {
                return arr.sorted()
            }
        }
        return []
    }

    /// Full issuance: order → publish DNS-01 → validate → finalize → install.
    /// On success returns the issued cert's metadata so the UI can show it
    /// without re-reading the file.
    @discardableResult
    func requestCertificate() async throws -> CertificateInfo {
        let config = ACMEConfig()
        guard !config.domains.isEmpty else { throw ACMEError.missingDomains }
        guard KeychainCloudflareToken.load()?.isEmpty == false else { throw ACMEError.missingCloudflareToken }

        if KeychainACMEAccountKey.load(directoryHost: config.ca.directoryHost) == nil {
            _ = try await registerAccount()
        }

        let host = config.ca.directoryHost
        guard let keyPEM = KeychainACMEAccountKey.load(directoryHost: host) else {
            throw ACMEError.underlying("Missing ACME account key after registration.")
        }

        emit(.running(stage: "Connecting to \(config.ca.displayName)…"))
        let acme = try await AcmeSwift(acmeEndpoint: endpointFor(ca: config.ca))
        defer { try? acme.syncShutdown() }
        let credentials = try AccountCredentials(
            contacts: ["mailto:\(config.accountEmail)"],
            pemKey: keyPEM
        )
        try acme.account.use(credentials)

        emit(.running(stage: "Placing order for \(config.domains.joined(separator: ", "))…"))
        if case .named(let n) = config.profile {
            emit(.running(stage: "Profile '\(n)' selected (held until AcmeSwift exposes the order profile field)."))
        }
        var order = try await acme.orders.create(domains: config.domains)

        emit(.running(stage: "Fetching DNS-01 challenges…"))
        let descriptions = try await acme.orders.describePendingChallenges(
            from: order,
            preferring: .dns
        )

        // Track published TXT records so we can clean up unconditionally.
        var published: [(zoneID: String, recordID: String)] = []
        do {
            for desc in descriptions where desc.type == .dns {
                emit(.running(stage: "Publishing TXT \(desc.endpoint)"))
                let zoneID = try await cloudflare.findZoneID(coveringDomain: desc.endpoint)
                let recordID = try await cloudflare.createTXTRecord(
                    zoneID: zoneID,
                    name: desc.endpoint,
                    value: desc.value
                )
                published.append((zoneID, recordID))

                emit(.running(stage: "Waiting for DNS propagation of \(desc.endpoint)…"))
                try await resolver.waitForTXT(
                    name: desc.endpoint,
                    expectedValue: desc.value,
                    mode: config.dnsMode,
                    host: config.effectiveResolverHost,
                    dohURL: config.effectiveDoHURL,
                    timeout: TimeInterval(config.dnsValidationTimeoutSeconds),
                    poll: TimeInterval(config.dnsPropagationPollSeconds)
                )
            }

            emit(.running(stage: "Validating challenges with \(config.ca.displayName)…"))
            var remaining = try await acme.orders.validateChallenges(
                from: order,
                preferring: .dns
            )
            for nap in [5, 10, 10, 15, 30] {
                guard !remaining.isEmpty else { break }
                try await Task.sleep(nanoseconds: UInt64(nap) * 1_000_000_000)
                remaining = try await acme.orders.validateChallenges(
                    from: order,
                    preferring: .dns
                )
            }
            guard remaining.isEmpty else {
                throw ACMEError.underlying("ACME server did not validate all challenges in time.")
            }

            emit(.running(stage: "Finalising order…"))
            let privateKey = try await acme.orders.finalize(
                order: &order,
                subject: nil,
                type: acmeKeyType(from: config)
            )
            let certs = try await acme.certificates.download(for: order)

            emit(.running(stage: "Installing certificate…"))
            let chainPEM = certs.joined(separator: "\n")
            let keyPEMOut = try privateKey.serializeAsPEM().pemString
            try install(keyPEM: keyPEMOut, chainPEM: chainPEM)

            // Record successful issuance metadata for the UI.
            let now = Date()
            UserDefaults.standard.set(now, forKey: ACMEConfig.lastIssuedAtKey)
            UserDefaults.standard.set(config.ca.directoryURL.absoluteString, forKey: ACMEConfig.lastDirectoryURLKey)
            if case .named(let n) = config.profile {
                UserDefaults.standard.set(n, forKey: ACMEConfig.lastProfileUsedKey)
            } else {
                UserDefaults.standard.removeObject(forKey: ACMEConfig.lastProfileUsedKey)
            }
            UserDefaults.standard.removeObject(forKey: ACMEConfig.lastRenewErrorKey)

            await cleanup(published: published)
            emit(.success(now))
            return try CertificateStore.inspect(format: .pem, password: "")
        } catch {
            await cleanup(published: published)
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            UserDefaults.standard.set(message, forKey: ACMEConfig.lastRenewErrorKey)
            emit(.failure(message))
            throw error
        }
    }

    /// Daily-timer entry point. Re-issues only when the installed certificate
    /// is closer than `renewWhenDaysRemain` to its NotAfter, or when nothing
    /// is installed at all but ACME settings are otherwise complete.
    func renewIfNeeded() async {
        let config = ACMEConfig()
        guard config.autoRenewEnabled else { return }
        guard !config.domains.isEmpty else { return }
        guard KeychainCloudflareToken.load()?.isEmpty == false else { return }

        if let info = try? CertificateStore.inspect(format: .pem, password: "") {
            if info.daysUntilExpiry > config.renewWhenDaysRemain { return }
        }
        do {
            _ = try await requestCertificate()
        } catch {
            // Failure already recorded via emit(.failure).
        }
    }

    // MARK: - Helpers

    /// Maps the user's key-type + size selection to AcmeSwift's `KeyType` so
    /// `finalize()` knows what private key to generate before submitting the
    /// CSR. ECDSA defaults to P-384, RSA to 2048 — both match AcmeSwift's
    /// own defaults so an unconfigured install behaves the same as before.
    private func acmeKeyType(from config: ACMEConfig) -> AcmeSwift.KeyType {
        switch config.keyType {
        case .ecdsa:
            let bits: AcmeSwift.KeyType.ECCBits
            switch config.eccSize {
            case .p256: bits = .p256
            case .p384: bits = .p384
            case .p521: bits = .p521
            }
            return .ecdsa(bits)
        case .rsa:
            let bits: AcmeSwift.KeyType.RSABits
            switch config.rsaSize {
            case .rsa2048: bits = .`2048`
            case .rsa3072: bits = .`3072`
            case .rsa4096: bits = .`4096`
            }
            return .rsa(bits)
        }
    }

    /// Maps our `ACMECA` value to AcmeSwift's `AcmeEndpoint`. The two enums
    /// have nearly identical shape; we just shuttle the URL across for the
    /// `.custom` case.
    private func endpointFor(ca: ACMECA) -> AcmeEndpoint {
        switch ca {
        case .letsEncryptProd:    return .letsEncrypt
        case .letsEncryptStaging: return .letsEncryptStaging
        case .custom(let url):    return .custom(url)
        }
    }

    private func install(keyPEM: String, chainPEM: String) throws {
        guard let keyData = keyPEM.data(using: .utf8),
              let chainData = chainPEM.data(using: .utf8) else {
            throw ACMEError.underlying("Could not encode PEM data.")
        }
        try CertificateStore.importPEMKey(data: keyData)
        try CertificateStore.importPEMCertificate(data: chainData)

        // Issued key is unencrypted PEM — clear any stale TLS passphrase so
        // the server doesn't try to decrypt with the wrong secret on startup.
        KeychainTLSPassword.delete()

        // Switch the running config to PEM so HTTPServer reads the new files.
        UserDefaults.standard.set(TLSCertificateFormat.pem.rawValue, forKey: Config.tlsCertFormatKey)
    }

    private func cleanup(published: [(zoneID: String, recordID: String)]) async {
        for entry in published {
            do {
                try await cloudflare.deleteTXTRecord(zoneID: entry.zoneID, recordID: entry.recordID)
            } catch {
                print("ACMECoordinator: TXT cleanup failed for \(entry.recordID): \(error.localizedDescription)")
            }
        }
    }

    private func persistRegistered(_ registered: Bool, urlString: String?) {
        UserDefaults.standard.set(registered, forKey: ACMEConfig.accountRegisteredKey)
        if registered, let urlString {
            UserDefaults.standard.set(urlString, forKey: "acmeAccountURL")
        }
    }
}
