import Foundation

/// Snapshot of all ACME-related user preferences, read from UserDefaults the
/// same way `Config` reads its server settings. Coordinator code takes one of
/// these and never touches UserDefaults directly so writes from the UI and
/// reads from background tasks can't race.
struct ACMEConfig {
    // UserDefaults keys
    static let caKindKey                    = "acmeCAKind"
    static let customDirectoryURLKey        = "acmeCustomDirectoryURL"
    static let accountEmailKey              = "acmeAccountEmail"
    static let accountRegisteredKey         = "acmeAccountRegistered"
    static let profileNameKey               = "acmeProfileName"
    static let domainsKey                   = "acmeDomains"
    static let challengeTypeKey             = "acmeChallengeType"
    static let dnsModeKey                   = "acmeDNSMode"
    static let dnsResolverPresetKey         = "acmeDNSResolverPreset"
    static let customResolverHostKey        = "acmeCustomResolverHost"
    static let customDoHURLKey              = "acmeCustomDoHURL"
    static let dnsValidationTimeoutKey      = "acmeDNSValidationTimeoutSeconds"
    static let dnsPropagationPollKey        = "acmeDNSPropagationPollIntervalSeconds"
    static let autoRenewEnabledKey          = "acmeAutoRenewEnabled"
    static let renewWhenDaysRemainKey       = "acmeRenewWhenDaysRemain"
    static let keyTypeKey                   = "acmeKeyType"
    static let eccSizeKey                   = "acmeECCSize"
    static let rsaSizeKey                   = "acmeRSASize"
    static let lastIssuedAtKey              = "acmeLastIssuedAt"
    static let lastRenewErrorKey            = "acmeLastRenewError"
    static let lastDirectoryURLKey          = "acmeLastDirectoryURL"
    static let lastProfileUsedKey           = "acmeLastProfileUsed"

    // Defaults
    static let defaultDNSValidationTimeoutSeconds = 120
    static let defaultDNSPropagationPollSeconds   = 5
    static let defaultRenewWhenDaysRemain         = 15

    let ca: ACMECA
    let accountEmail: String
    let accountRegistered: Bool
    let profile: ACMEProfile
    let domains: [String]
    let challengeType: ACMEChallengeType
    let dnsMode: ACMEDNSMode
    let dnsResolverPreset: ACMEDNSResolverPreset
    let customResolverHost: String
    let customDoHURL: String
    let dnsValidationTimeoutSeconds: Int
    let dnsPropagationPollSeconds: Int
    let autoRenewEnabled: Bool
    let renewWhenDaysRemain: Int
    let keyType: ACMEKeyType
    let eccSize: ACMEECCSize
    let rsaSize: ACMERSASize

    init(defaults: UserDefaults = .standard) {
        // CA
        let kind = defaults.string(forKey: Self.caKindKey) ?? "letsEncryptProd"
        let customURL = defaults.string(forKey: Self.customDirectoryURLKey) ?? ""
        switch kind {
        case "letsEncryptStaging":
            ca = .letsEncryptStaging
        case "custom":
            if let url = URL(string: customURL), url.scheme?.hasPrefix("http") == true {
                ca = .custom(url)
            } else {
                ca = .letsEncryptProd
            }
        default:
            ca = .letsEncryptProd
        }

        accountEmail = defaults.string(forKey: Self.accountEmailKey) ?? ""
        accountRegistered = defaults.bool(forKey: Self.accountRegisteredKey)

        profile = ACMEProfile(stored: defaults.string(forKey: Self.profileNameKey))

        domains = Self.parseDomains(defaults.string(forKey: Self.domainsKey) ?? "")

        if let raw = defaults.string(forKey: Self.challengeTypeKey),
           let parsed = ACMEChallengeType(rawValue: raw) {
            challengeType = parsed
        } else {
            challengeType = .dns01
        }

        if let raw = defaults.string(forKey: Self.dnsModeKey),
           let parsed = ACMEDNSMode(rawValue: raw) {
            dnsMode = parsed
        } else {
            dnsMode = .udp
        }

        if let raw = defaults.string(forKey: Self.dnsResolverPresetKey),
           let parsed = ACMEDNSResolverPreset(rawValue: raw) {
            dnsResolverPreset = parsed
        } else {
            dnsResolverPreset = .system
        }

        customResolverHost = defaults.string(forKey: Self.customResolverHostKey) ?? ""
        customDoHURL = defaults.string(forKey: Self.customDoHURLKey) ?? ""

        let storedTimeout = defaults.integer(forKey: Self.dnsValidationTimeoutKey)
        dnsValidationTimeoutSeconds = storedTimeout > 0 ? storedTimeout : Self.defaultDNSValidationTimeoutSeconds

        let storedPoll = defaults.integer(forKey: Self.dnsPropagationPollKey)
        dnsPropagationPollSeconds = storedPoll > 0 ? storedPoll : Self.defaultDNSPropagationPollSeconds

        autoRenewEnabled = defaults.bool(forKey: Self.autoRenewEnabledKey)

        let storedRenew = defaults.integer(forKey: Self.renewWhenDaysRemainKey)
        renewWhenDaysRemain = storedRenew > 0 ? storedRenew : Self.defaultRenewWhenDaysRemain

        if let raw = defaults.string(forKey: Self.keyTypeKey),
           let parsed = ACMEKeyType(rawValue: raw) {
            keyType = parsed
        } else {
            keyType = .ecdsa
        }
        if let raw = defaults.string(forKey: Self.eccSizeKey),
           let parsed = ACMEECCSize(rawValue: raw) {
            eccSize = parsed
        } else {
            eccSize = .p384
        }
        if let raw = defaults.string(forKey: Self.rsaSizeKey),
           let parsed = ACMERSASize(rawValue: raw) {
            rsaSize = parsed
        } else {
            rsaSize = .rsa3072
        }
    }

    /// Splits a comma-separated domain list, trims whitespace, drops empties,
    /// and lowercases everything (Let's Encrypt normalises identifiers anyway,
    /// but this keeps UI presentation consistent).
    static func parseDomains(_ s: String) -> [String] {
        s.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Effective resolver host for the chosen mode + preset. Returns nil for
    /// `.system` (the OS resolver doesn't need an address) and when the user
    /// chose Custom but hasn't typed anything yet.
    var effectiveResolverHost: String? {
        switch dnsMode {
        case .system:
            return nil
        case .udp:
            switch dnsResolverPreset {
            case .custom:
                return customResolverHost.isEmpty ? nil : customResolverHost
            case .system:
                return SystemNameservers.primaryIPv4()
            default:
                return dnsResolverPreset.ipv4
            }
        case .dnsOverTLS:
            switch dnsResolverPreset {
            case .custom:
                return customResolverHost.isEmpty ? nil : customResolverHost
            case .system:
                // Most local resolvers don't speak DoT; fall back to nil so
                // the resolver throws a clean "no DoT host configured" error.
                return nil
            default:
                return dnsResolverPreset.dotHost
            }
        case .dnsOverHTTPS:
            // DoH uses dohURL, not a host. effectiveDoHURL covers it.
            return nil
        }
    }

    /// Effective DoH URL for the chosen preset. Returns nil for non-DoH modes.
    var effectiveDoHURL: URL? {
        guard dnsMode == .dnsOverHTTPS else { return nil }
        switch dnsResolverPreset {
        case .custom:
            return URL(string: customDoHURL)
        default:
            return dnsResolverPreset.dohURL
        }
    }
}
