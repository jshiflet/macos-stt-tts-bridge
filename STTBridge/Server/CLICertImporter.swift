import Foundation

/// Handles `--import-pkcs12`, `--import-pem-cert`, `--import-pem-key`, and the
/// companion `--tls-cert-format` / `--tls-password` flags as a one-shot CLI
/// action. When any of the `--import-*` flags is present, this runs the imports
/// and the matching persistence updates and then calls `exit()` so the server
/// never starts. Designed for headless scripted certificate rotation:
///
///     STTBridge \
///       --import-pem-cert /path/to/new-cert.pem \
///       --import-pem-key  /path/to/new-key.pem \
///       --tls-cert-format PEM \
///       --tls-password    'secret'
///
/// Exit code: 0 on success, 1 on any failure.
enum CLICertImporter {
    /// Set of flag names that trigger one-shot import mode.
    private static let importFlags: Set<String> = [
        "import-pkcs12",
        "import-pem-cert",
        "import-pem-key"
    ]

    /// Returns true when the current process was invoked with at least one
    /// import flag. Lets callers short-circuit before constructing UI state.
    static func shouldHandle(args: [String] = CommandLine.arguments) -> Bool {
        let parsed = Self.parse(args)
        return parsed.keys.contains(where: importFlags.contains)
    }

    /// Runs the import + side-effect updates and exits the process.
    /// Never returns. Only call when `shouldHandle()` is true.
    ///
    /// Paths: a plain path is read directly, but the App Sandbox usually blocks
    /// anything outside the container — use `-` to read from stdin instead, e.g.
    /// `cat new-cert.pem | STTBridge --import-pem-cert -`.
    static func executeAndExit(
        args: [String] = CommandLine.arguments,
        defaults: UserDefaults = .standard
    ) -> Never {
        let cli = Self.parse(args)

        func ok(_ msg: String) {
            FileHandle.standardOutput.write(Data("✓ \(msg)\n".utf8))
        }
        func fail(_ msg: String) -> Never {
            FileHandle.standardError.write(Data("✗ \(msg)\n".utf8))
            exit(1)
        }

        func loadBytes(_ pathOrDash: String, label: String) -> Data {
            if pathOrDash == "-" {
                return FileHandle.standardInput.readDataToEndOfFile()
            }
            do {
                return try Data(contentsOf: URL(fileURLWithPath: pathOrDash))
            } catch {
                FileHandle.standardError.write(Data(
                    """
                    ✗ Failed to read \(label) from \(pathOrDash): \(error.localizedDescription)
                       The App Sandbox blocks paths outside the container. Pipe the file in
                       on stdin instead:  cat <file> | STTBridge --import-... -
                    
                    """.utf8))
                exit(1)
            }
        }

        if let path = cli["import-pkcs12"] {
            let data = loadBytes(path, label: "PKCS#12 bundle")
            do {
                let dest = try CertificateStore.importPKCS12(data: data)
                ok("Imported PKCS#12 (\(data.count) bytes) → \(dest.path)")
            } catch {
                fail("Failed to write PKCS#12: \(error.localizedDescription)")
            }
        }

        if let path = cli["import-pem-cert"] {
            let data = loadBytes(path, label: "PEM certificate")
            do {
                let dest = try CertificateStore.importPEMCertificate(data: data)
                ok("Imported PEM certificate (\(data.count) bytes) → \(dest.path)")
            } catch {
                fail("Failed to write PEM certificate: \(error.localizedDescription)")
            }
        }

        if let path = cli["import-pem-key"] {
            let data = loadBytes(path, label: "PEM private key")
            do {
                let dest = try CertificateStore.importPEMKey(data: data)
                ok("Imported PEM private key (\(data.count) bytes) → \(dest.path)")
            } catch {
                fail("Failed to write PEM private key: \(error.localizedDescription)")
            }
        }

        // Companion side effects: persist format choice and password if supplied
        // in the same invocation. These let a single CLI call atomically swap
        // every piece of TLS material a server needs.
        if let fmtRaw = cli["tls-cert-format"], let fmt = TLSCertificateFormat(rawValue: fmtRaw) {
            defaults.set(fmt.rawValue, forKey: Config.tlsCertFormatKey)
            ok("Set tlsCertFormat = \(fmt.rawValue)")
        }

        if let pw = cli["tls-password"] {
            if pw.isEmpty {
                KeychainTLSPassword.delete()
                ok("Cleared TLS password from Keychain")
            } else if KeychainTLSPassword.save(pw) {
                ok("Saved TLS password to Keychain")
            } else {
                fail("Failed to save TLS password to Keychain")
            }
        }

        exit(0)
    }

    // MARK: -

    /// Lightweight argv parser mirroring `Config.parseCLI` so this file has no
    /// dependency on Config's internal state. Recognises `--key value`,
    /// `--key=value`, and bare `--flag`.
    private static func parse(_ args: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var i = 1
        while i < args.count {
            let arg = args[i]
            guard arg.hasPrefix("--") else { i += 1; continue }
            let body = String(arg.dropFirst(2))
            if let eq = body.firstIndex(of: "=") {
                result[String(body[..<eq])] = String(body[body.index(after: eq)...])
                i += 1
            } else if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                result[body] = args[i + 1]
                i += 2
            } else {
                result[body] = "true"
                i += 1
            }
        }
        return result
    }
}
