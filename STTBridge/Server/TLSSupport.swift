import Foundation
import Security
import NIOSSL

// MARK: - TLS version

/// User-facing TLS protocol version selection. Maps to NIOSSL.TLSVersion.
enum TLSVersionPref: String, CaseIterable, Identifiable, Codable {
    case tls10 = "TLSv1.0"
    case tls11 = "TLSv1.1"
    case tls12 = "TLSv1.2"
    case tls13 = "TLSv1.3"

    var id: String { rawValue }

    /// Strictly increasing rank used to validate min ≤ max.
    var rank: Int {
        switch self {
        case .tls10: return 0
        case .tls11: return 1
        case .tls12: return 2
        case .tls13: return 3
        }
    }

    var niossl: TLSVersion {
        switch self {
        case .tls10: return .tlsv1
        case .tls11: return .tlsv11
        case .tls12: return .tlsv12
        case .tls13: return .tlsv13
        }
    }

    static let ordered: [TLSVersionPref] = [.tls10, .tls11, .tls12, .tls13]

    init?(stored: String?) {
        guard let s = stored, let v = TLSVersionPref(rawValue: s) else { return nil }
        self = v
    }
}

// MARK: - Certificate format

/// Which on-disk format the user has chosen for their TLS material.
enum TLSCertificateFormat: String, CaseIterable, Identifiable, Codable {
    /// Single PKCS#12 (.p12 / .pfx) bundle containing cert chain + private key.
    case pkcs12 = "PKCS#12"
    /// Separate PEM-encoded certificate (chain) and private key files. The
    /// private key may be plaintext or AES/3DES-encrypted with a passphrase.
    case pem = "PEM"

    var id: String { rawValue }
}

// MARK: - Cipher catalog (TLS 1.2 only — TLS 1.3 suites are fixed by RFC 8446)

/// A curated list of cipher suites surfaced in the Settings UI. The strings are
/// OpenSSL-style names that go straight into `TLSConfiguration.cipherSuites`
/// (colon-separated). Order here = preference order shown to the user.
enum TLSCipherCatalog {
    static let recommended: [String] = [
        "ECDHE-ECDSA-AES256-GCM-SHA384",
        "ECDHE-ECDSA-AES128-GCM-SHA256",
        "ECDHE-ECDSA-CHACHA20-POLY1305",
        "ECDHE-RSA-AES256-GCM-SHA384",
        "ECDHE-RSA-AES128-GCM-SHA256",
        "ECDHE-RSA-CHACHA20-POLY1305"
    ]
}

// MARK: - Curve catalog

/// A single elliptic-curve option presented in the Settings UI.
struct TLSCurveOption: Identifiable, Hashable {
    /// Stable identifier persisted to UserDefaults and accepted by the CLI.
    let id: String
    let displayName: String
    let niossl: NIOTLSCurve
    /// True for post-quantum hybrid curves (currently only `x25519_MLKEM768`),
    /// which combine classical ECDH with a Kyber-based KEM to resist
    /// "harvest now, decrypt later" attacks by future quantum computers.
    let isQuantumSecure: Bool
}

enum TLSCurveCatalog {
    static let all: [TLSCurveOption] = [
        .init(id: "secp256r1", displayName: "secp256r1", niossl: .secp256r1, isQuantumSecure: false),
        .init(id: "secp384r1", displayName: "secp384r1", niossl: .secp384r1, isQuantumSecure: false),
        .init(id: "secp521r1", displayName: "secp521r1", niossl: .secp521r1, isQuantumSecure: false),
        .init(id: "x25519", displayName: "x25519", niossl: .x25519, isQuantumSecure: false),
        .init(id: "x25519_MLKEM768", displayName: "x25519_MLKEM768", niossl: .x25519_MLKEM768, isQuantumSecure: true),
        .init(id: "x448", displayName: "x448", niossl: .x448, isQuantumSecure: false)
    ]

    static let allIDs: [String] = all.map(\.id)

    /// Looks up the NIOSSL constant for a stored identifier; nil if unknown.
    static func niossl(for id: String) -> NIOTLSCurve? {
        all.first { $0.id == id }?.niossl
    }
}

// MARK: - Certificate file store

/// Manages TLS certificate material inside the sandboxed app container so the
/// headless LaunchAgent and the GUI app see the same paths without any
/// security-scoped bookmark dance.
///
/// Two on-disk layouts coexist; the active one is chosen by `Config.tlsCertFormat`:
///   - PKCS#12: a single `server.p12` containing cert chain + private key.
///   - PEM: separate `server-cert.pem` (chain) and `server-key.pem` (private key,
///     optionally encrypted with a passphrase).
enum CertificateStore {
    static let p12Filename = "server.p12"
    static let pemCertFilename = "server-cert.pem"
    static let pemKeyFilename = "server-key.pem"

    private static func tlsDirectory() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport
            .appendingPathComponent("STTBridge", isDirectory: true)
            .appendingPathComponent("tls", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func p12URL() throws -> URL {
        try tlsDirectory().appendingPathComponent(p12Filename)
    }

    static func pemCertURL() throws -> URL {
        try tlsDirectory().appendingPathComponent(pemCertFilename)
    }

    static func pemKeyURL() throws -> URL {
        try tlsDirectory().appendingPathComponent(pemKeyFilename)
    }

    static func hasPKCS12() -> Bool {
        guard let url = try? p12URL() else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func hasPEMCertificate() -> Bool {
        guard let url = try? pemCertURL() else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func hasPEMKey() -> Bool {
        guard let url = try? pemKeyURL() else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// True if every file required for the given format is present.
    static func isComplete(format: TLSCertificateFormat) -> Bool {
        switch format {
        case .pkcs12: return hasPKCS12()
        case .pem:    return hasPEMCertificate() && hasPEMKey()
        }
    }

    /// Copies the user-selected source file (which may be a security-scoped URL
    /// from NSOpenPanel) into the container under `destFilename`. Returns the
    /// destination URL on success.
    @discardableResult
    private static func importFile(from sourceURL: URL, destFilename: String) throws -> URL {
        let dest = try tlsDirectory().appendingPathComponent(destFilename)
        let fm = FileManager.default

        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: sourceURL)

        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try data.write(to: dest, options: [.atomic])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
        return dest
    }

    @discardableResult
    static func importPKCS12(from sourceURL: URL) throws -> URL {
        try importFile(from: sourceURL, destFilename: p12Filename)
    }

    @discardableResult
    static func importPEMCertificate(from sourceURL: URL) throws -> URL {
        try importFile(from: sourceURL, destFilename: pemCertFilename)
    }

    @discardableResult
    static func importPEMKey(from sourceURL: URL) throws -> URL {
        try importFile(from: sourceURL, destFilename: pemKeyFilename)
    }

    /// Writes raw bytes (from the CLI's stdin or a path the sandbox lets us
    /// read) to the well-known location inside the container.
    @discardableResult
    private static func writeBytes(_ data: Data, destFilename: String) throws -> URL {
        let dest = try tlsDirectory().appendingPathComponent(destFilename)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try data.write(to: dest, options: [.atomic])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
        return dest
    }

    @discardableResult
    static func importPKCS12(data: Data) throws -> URL {
        try writeBytes(data, destFilename: p12Filename)
    }

    @discardableResult
    static func importPEMCertificate(data: Data) throws -> URL {
        try writeBytes(data, destFilename: pemCertFilename)
    }

    @discardableResult
    static func importPEMKey(data: Data) throws -> URL {
        try writeBytes(data, destFilename: pemKeyFilename)
    }

    static func deletePKCS12() {
        guard let url = try? p12URL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func deletePEMFiles() {
        if let url = try? pemCertURL() { try? FileManager.default.removeItem(at: url) }
        if let url = try? pemKeyURL() { try? FileManager.default.removeItem(at: url) }
    }

    /// Loads the stored certificate material for the given format and returns
    /// metadata about the leaf certificate. For PEM, this also exercises the
    /// private key loader so a bad passphrase surfaces here rather than at first
    /// connection. For PKCS#12 the passphrase is required to even reach the cert.
    static func inspect(format: TLSCertificateFormat, password: String) throws -> CertificateInfo {
        let leaf: NIOSSLCertificate
        switch format {
        case .pkcs12:
            let url = try p12URL()
            guard FileManager.default.fileExists(atPath: url.path) else { throw TLSError.noCertificate }
            let bundle: NIOSSLPKCS12Bundle
            do {
                let pass: [UInt8]? = password.isEmpty ? nil : Array(password.utf8)
                bundle = try NIOSSLPKCS12Bundle(file: url.path, passphrase: pass)
            } catch {
                throw TLSError.loadFailed(error.localizedDescription)
            }
            guard let l = bundle.certificateChain.first else {
                throw TLSError.loadFailed("Bundle contains no certificates")
            }
            leaf = l

        case .pem:
            let certURL = try pemCertURL()
            let keyURL = try pemKeyURL()
            guard FileManager.default.fileExists(atPath: certURL.path) else { throw TLSError.noCertificate }
            guard FileManager.default.fileExists(atPath: keyURL.path) else {
                throw TLSError.loadFailed("Private key file is missing")
            }
            let certs: [NIOSSLCertificate]
            do {
                certs = try NIOSSLCertificate.fromPEMFile(certURL.path)
            } catch {
                throw TLSError.loadFailed("Certificate file: \(error.localizedDescription)")
            }
            guard let l = certs.first else {
                throw TLSError.loadFailed("PEM certificate file is empty")
            }
            leaf = l
            // Also verify the private key loads with the supplied password,
            // so wrong passphrases fail here instead of at the first connection.
            do {
                _ = try loadPEMPrivateKey(keyURL: keyURL, password: password)
            } catch {
                throw TLSError.loadFailed("Private key: \(error.localizedDescription)")
            }
        }

        guard let info = CertificateInfo(from: leaf) else {
            throw TLSError.loadFailed("Could not parse certificate metadata")
        }
        return info
    }

    /// Internal helper: loads a PEM private key with optional passphrase callback.
    /// Used by both `inspect` and the server's SSL context builder.
    static func loadPEMPrivateKey(keyURL: URL, password: String) throws -> NIOSSLPrivateKey {
        if password.isEmpty {
            return try NIOSSLPrivateKey(file: keyURL.path, format: .pem)
        }
        let passBytes: [UInt8] = Array(password.utf8)
        return try NIOSSLPrivateKey(file: keyURL.path, format: .pem) { (setter: ([UInt8]) -> Void) in
            setter(passBytes)
        }
    }
}

// MARK: - Cert info extraction (via Security framework)

struct CertificateInfo {
    let subject: String
    let issuer: String
    let validFrom: Date
    let validUntil: Date

    var isExpired: Bool { validUntil < Date() }
    var daysUntilExpiry: Int {
        Calendar.current.dateComponents([.day], from: Date(), to: validUntil).day ?? 0
    }
}

extension CertificateInfo {
    /// Bridges a NIOSSLCertificate → SecCertificate to extract human-readable metadata.
    init?(from nioCert: NIOSSLCertificate) {
        guard let der = try? nioCert.toDERBytes() else { return nil }
        let data = Data(der)
        guard let cert = SecCertificateCreateWithData(nil, data as CFData) else { return nil }

        let subjectSummary = (SecCertificateCopySubjectSummary(cert) as String?) ?? "Unknown"

        let oids: [CFString] = [
            kSecOIDX509V1IssuerName,
            kSecOIDX509V1ValidityNotBefore,
            kSecOIDX509V1ValidityNotAfter
        ]
        let values = SecCertificateCopyValues(cert, oids as CFArray, nil) as? [CFString: Any] ?? [:]

        func date(forOID oid: CFString) -> Date? {
            guard let dict = values[oid] as? [CFString: Any],
                  let raw = dict[kSecPropertyKeyValue as CFString] else { return nil }
            if let n = raw as? NSNumber {
                return Date(timeIntervalSinceReferenceDate: n.doubleValue)
            }
            if let d = raw as? Double {
                return Date(timeIntervalSinceReferenceDate: d)
            }
            return nil
        }

        func summary(forOID oid: CFString) -> String {
            guard let dict = values[oid] as? [CFString: Any],
                  let entries = dict[kSecPropertyKeyValue as CFString] as? [[CFString: Any]] else {
                return ""
            }
            // Each entry has label/value pairs. Concatenate "label=value" parts that have CN/O/OU.
            var parts: [String] = []
            for entry in entries {
                let label = entry[kSecPropertyKeyLabel as CFString] as? String ?? ""
                let value = entry[kSecPropertyKeyValue as CFString] as? String ?? ""
                if !label.isEmpty, !value.isEmpty {
                    parts.append("\(label)=\(value)")
                }
            }
            return parts.joined(separator: ", ")
        }

        self.subject = subjectSummary
        self.issuer = summary(forOID: kSecOIDX509V1IssuerName)
        self.validFrom = date(forOID: kSecOIDX509V1ValidityNotBefore) ?? Date.distantPast
        self.validUntil = date(forOID: kSecOIDX509V1ValidityNotAfter) ?? Date.distantFuture
    }
}

// MARK: - TLS errors

enum TLSError: LocalizedError {
    case notEnabled
    case noCertificate
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .notEnabled: return "TLS is not enabled."
        case .noCertificate: return "No certificate has been imported."
        case .loadFailed(let msg): return "Could not load certificate: \(msg)"
        }
    }
}
