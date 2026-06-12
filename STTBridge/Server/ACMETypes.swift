import Foundation

// MARK: - Certificate Authority

/// User-facing choice of ACME server. Maps to a directory URL the AcmeSwift
/// client points at. `custom` lets the user paste a full directory URL for any
/// RFC-8555 CA that doesn't require External Account Binding.
enum ACMECA: Codable, Equatable, Hashable {
    case letsEncryptProd
    case letsEncryptStaging
    case custom(URL)

    static let letsEncryptProdURL = URL(string: "https://acme-v02.api.letsencrypt.org/directory")!
    static let letsEncryptStagingURL = URL(string: "https://acme-staging-v02.api.letsencrypt.org/directory")!

    var directoryURL: URL {
        switch self {
        case .letsEncryptProd: return Self.letsEncryptProdURL
        case .letsEncryptStaging: return Self.letsEncryptStagingURL
        case .custom(let url): return url
        }
    }

    /// Host portion of the directory URL. Used as the Keychain `account`
    /// component so prod and staging accounts coexist on the same device.
    var directoryHost: String {
        directoryURL.host ?? directoryURL.absoluteString
    }

    var displayName: String {
        switch self {
        case .letsEncryptProd: return "Let's Encrypt (Production)"
        case .letsEncryptStaging: return "Let's Encrypt (Staging)"
        case .custom: return "Custom"
        }
    }

    /// Stable rawValue persisted to UserDefaults. `custom` carries no URL here —
    /// the URL is stored separately so the user's typed value survives even if
    /// they toggle away and back to the Custom option.
    var storageKind: String {
        switch self {
        case .letsEncryptProd: return "letsEncryptProd"
        case .letsEncryptStaging: return "letsEncryptStaging"
        case .custom: return "custom"
        }
    }
}

// MARK: - Challenge type

/// Which ACME challenge mechanism to attempt. Today only `dns01` is fully
/// implemented; `dnsPersist01` is reserved for the in-flight
/// `draft-ietf-acme-dns-persist-01` work and falls back to DNS-01 behaviour
/// with a log note until the draft ships.
enum ACMEChallengeType: String, Codable, CaseIterable, Identifiable {
    case dns01 = "dns-01"
    case dnsPersist01 = "dns-persist-01"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dns01: return "DNS-01"
        case .dnsPersist01: return "dns-persist-01 (Draft)"
        }
    }

    /// True for challenge types not yet ratified — the UI shows a caption
    /// explaining the choice is preserved but treated as DNS-01.
    var isDraft: Bool {
        switch self {
        case .dns01: return false
        case .dnsPersist01: return true
        }
    }
}

// MARK: - ACME profile (RFC 9773)

/// ACME order profile selection. `automatic` omits the profile field from the
/// newOrder request so the CA picks its default. `named` carries the profile
/// name advertised by the CA's `meta.profiles` directory field.
enum ACMEProfile: Codable, Equatable, Hashable {
    case automatic
    case named(String)

    var storedName: String? {
        switch self {
        case .automatic: return nil
        case .named(let n): return n
        }
    }

    init(stored: String?) {
        if let n = stored, !n.isEmpty {
            self = .named(n)
        } else {
            self = .automatic
        }
    }

    var displayName: String {
        switch self {
        case .automatic: return "Automatic (CA default)"
        case .named(let n): return n
        }
    }
}

// MARK: - Certificate key type / size

/// Algorithm family for the issued certificate's private key. Maps to
/// AcmeSwift's `KeyType` enum in the coordinator.
enum ACMEKeyType: String, Codable, CaseIterable, Identifiable {
    case ecdsa
    case rsa

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ecdsa: return "ECDSA"
        case .rsa:   return "RSA"
        }
    }
}

/// Elliptic curve choice when `keyType` is `.ecdsa`. Mirrors AcmeSwift's
/// `KeyType.ECCBits` (p256 / p384 / p521).
enum ACMEECCSize: String, Codable, CaseIterable, Identifiable {
    case p256
    case p384
    case p521

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .p256: return "P-256"
        case .p384: return "P-384 (recommended)"
        case .p521: return "P-521"
        }
    }
}

/// RSA bit length when `keyType` is `.rsa`. Mirrors AcmeSwift's
/// `KeyType.RSABits` (2048 / 3072 / 4096).
enum ACMERSASize: String, Codable, CaseIterable, Identifiable {
    case rsa2048 = "2048"
    case rsa3072 = "3072"
    case rsa4096 = "4096"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rsa2048: return "2048-bit"
        case .rsa3072: return "3072-bit (recommended)"
        case .rsa4096: return "4096-bit"
        }
    }
}

// MARK: - DNS validation transport

/// How the validator should talk to a DNS resolver. UDP/DoT/DoH share the same
/// RFC-1035 wire format; only the framing and trust model differ.
enum ACMEDNSMode: String, Codable, CaseIterable, Identifiable {
    case system          // OS resolver via Network.framework
    case udp             // Plain UDP/53
    case dnsOverTLS      // RFC 7858 over TCP/853 with TLS
    case dnsOverHTTPS    // RFC 8484 over HTTPS

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System default"
        case .udp: return "UDP"
        case .dnsOverTLS: return "DNS-over-TLS"
        case .dnsOverHTTPS: return "DNS-over-HTTPS"
        }
    }
}

// MARK: - DNS resolver preset

/// Well-known resolvers the user can pick from the menu. Each preset carries
/// the v4 IP for plain/UDP, the TLS hostname for DoT (needed for SNI and cert
/// verification), and the DoH endpoint URL. `system` is special — it doesn't
/// carry static values; the coordinator resolves the IP at query time from
/// the OS's configured nameservers.
enum ACMEDNSResolverPreset: String, Codable, CaseIterable, Identifiable {
    case system
    case cloudflare
    case google
    case quad9
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:     return "System (\(SystemNameservers.primaryIPv4() ?? "auto"))"
        case .cloudflare: return "Cloudflare (1.1.1.1)"
        case .google:     return "Google (8.8.8.8)"
        case .quad9:      return "Quad9 (9.9.9.9)"
        case .custom:     return "Custom…"
        }
    }

    /// Plain IPv4 address used for UDP/53 queries. `system` reads from
    /// `/etc/resolv.conf` (or its macOS-synthesised equivalent) so the user
    /// sees the same nameserver the OS would normally consult.
    var ipv4: String? {
        switch self {
        case .system:     return SystemNameservers.primaryIPv4()
        case .cloudflare: return "1.1.1.1"
        case .google:     return "8.8.8.8"
        case .quad9:      return "9.9.9.9"
        case .custom:     return nil
        }
    }

    /// Hostname used as the TLS server name and Subject Alternative Name
    /// during DoT validation. Quad9's certificate covers `dns.quad9.net`.
    /// `system` returns nil — most local nameservers don't speak DoT, so the
    /// user should pair `.system` with the UDP mode.
    var dotHost: String? {
        switch self {
        case .system:     return nil
        case .cloudflare: return "one.one.one.one"
        case .google:     return "dns.google"
        case .quad9:      return "dns.quad9.net"
        case .custom:     return nil
        }
    }

    /// RFC 8484 endpoint URL. `system` returns nil for the same reason as
    /// `dotHost` — local resolvers rarely expose DoH.
    var dohURL: URL? {
        switch self {
        case .system:     return nil
        case .cloudflare: return URL(string: "https://cloudflare-dns.com/dns-query")
        case .google:     return URL(string: "https://dns.google/dns-query")
        case .quad9:      return URL(string: "https://dns.quad9.net/dns-query")
        case .custom:     return nil
        }
    }
}

// MARK: - System nameserver lookup

/// Parses `/etc/resolv.conf` to find the OS's current primary nameserver.
/// macOS auto-synthesises this file from the active network service's DNS
/// config, so it's the same set the system resolver consults — just exposed
/// in a way we can query without the SystemConfiguration framework.
enum SystemNameservers {
    /// Returns the first `nameserver` line's IPv4 address, or nil if the file
    /// is missing, unreadable, or carries no IPv4 entries.
    static func primaryIPv4() -> String? {
        guard let text = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8) else {
            return nil
        }
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("nameserver") else { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let candidate = String(parts[1]).trimmingCharacters(in: .whitespaces)
            // Filter out IPv6 — keep this implementation focused on the v4
            // path since the resolver only currently uses UDP/53 over v4.
            if candidate.contains(":") { continue }
            return candidate
        }
        return nil
    }
}

// MARK: - Coordinator status

/// Live status surfaced to the ACME Settings tab. The coordinator emits a
/// stream of these values that the UI subscribes to so the log area can update
/// in real time.
enum ACMEStatus: Equatable, Sendable {
    case idle
    case running(stage: String)
    case success(Date)
    case failure(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

// MARK: - ACME errors

/// User-visible errors surfaced from the coordinator and importer. Each maps to
/// a concise message that lights up the relevant field in the Settings tab.
enum ACMEError: LocalizedError, Equatable {
    case missingEmail
    case missingDomains
    case missingCloudflareToken
    case invalidDirectoryURL
    case invalidAccountKey
    case invalidAccountURL
    case zoneNotFound(String)
    case dnsTimeout(String)
    case profileUnavailable(String)
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .missingEmail:           return "Set an account email before registering with the CA."
        case .missingDomains:         return "Add at least one domain to issue a certificate for."
        case .missingCloudflareToken: return "A Cloudflare API token is required for DNS-01 challenges."
        case .invalidDirectoryURL:    return "The custom ACME directory URL is invalid."
        case .invalidAccountKey:      return "The supplied private key could not be parsed as PEM."
        case .invalidAccountURL:      return "The supplied account URL is invalid."
        case .zoneNotFound(let d):    return "Could not find a Cloudflare zone covering \(d)."
        case .dnsTimeout(let n):      return "Timed out waiting for the TXT record at \(n) to propagate."
        case .profileUnavailable(let n): return "The CA does not advertise a profile named \(n)."
        case .underlying(let s):      return s
        }
    }
}
