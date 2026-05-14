import Foundation

struct Config {
    static let defaultBindHost = "127.0.0.1"
    static let defaultPort = 8787
    static let defaultLanguage = "en-US"

    static let bindHostsKey = "bindHosts"
    static let bindHostLegacyKey = "bindHost"   // migration source only
    static let portKey = "port"
    static let authTokenKey = "authToken"
    static let defaultLangKey = "defaultLang"
    static let offlineOnlyKey = "offlineOnly"

    let port: Int
    let bindHosts: [String]
    let authToken: String?
    let defaultLang: String
    let offlineOnly: Bool

    init(
        env: [String: String] = ProcessInfo.processInfo.environment,
        args: [String] = CommandLine.arguments,
        defaults: UserDefaults = .standard
    ) {
        let cli = Self.parseCLI(args)

        // Priority: CLI > UserDefaults > env > default
        if let cliPort = cli["port"], let n = Int(cliPort) {
            port = n
        } else if let stored = defaults.object(forKey: Self.portKey) as? Int, stored > 0 {
            port = stored
        } else {
            port = Int(env["PORT"] ?? "") ?? Self.defaultPort
        }

        bindHosts = Self.resolveBindHosts(cli: cli, env: env, defaults: defaults)

        if let cliToken = cli["auth-token"] {
            authToken = cliToken.isEmpty ? nil : cliToken
        } else if let kcToken = KeychainAuthToken.load(), !kcToken.isEmpty {
            authToken = kcToken
        } else if let legacy = defaults.string(forKey: Self.authTokenKey), !legacy.isEmpty {
            // One-shot migration from the old plaintext UserDefaults storage.
            // Save to Keychain first; only clear UserDefaults if the save succeeded,
            // so a Keychain failure can't lose the user's token.
            if KeychainAuthToken.save(legacy) {
                defaults.removeObject(forKey: Self.authTokenKey)
            }
            authToken = legacy
        } else {
            authToken = env["AUTH_TOKEN"]
        }

        if let cliLang = cli["default-lang"], !cliLang.isEmpty {
            defaultLang = cliLang
        } else if let stored = defaults.string(forKey: Self.defaultLangKey), !stored.isEmpty {
            defaultLang = stored
        } else {
            defaultLang = env["DEFAULT_LANG"] ?? Self.defaultLanguage
        }

        if let cliOffline = cli["offline-only"] {
            offlineOnly = cliOffline.lowercased() == "true"
        } else if defaults.object(forKey: Self.offlineOnlyKey) != nil {
            offlineOnly = defaults.bool(forKey: Self.offlineOnlyKey)
        } else {
            offlineOnly = (env["OFFLINE_ONLY"] ?? "false").lowercased() == "true"
        }
    }

    /// Resolves the list of bind hosts. Priority: CLI > UserDefaults array > legacy
    /// single-string UserDefaults key (migrated to the array key) > env > default.
    /// Always returns at least one host. Dedups; if "0.0.0.0" is in the set, it
    /// becomes the sole entry (binding all interfaces subsumes everything else).
    private static func resolveBindHosts(
        cli: [String: String],
        env: [String: String],
        defaults: UserDefaults
    ) -> [String] {
        let raw: [String]
        if let cliHost = cli["bind-host"], !cliHost.isEmpty {
            raw = splitHostList(cliHost)
        } else if let arr = defaults.stringArray(forKey: Self.bindHostsKey), !arr.isEmpty {
            raw = arr
        } else if let legacy = defaults.string(forKey: Self.bindHostLegacyKey), !legacy.isEmpty {
            // Migrate the old single-string `bindHost` key to the array key.
            let migrated = [legacy]
            defaults.set(migrated, forKey: Self.bindHostsKey)
            defaults.removeObject(forKey: Self.bindHostLegacyKey)
            raw = migrated
        } else if let envHost = env["BIND_HOST"], !envHost.isEmpty {
            raw = splitHostList(envHost)
        } else {
            raw = [Self.defaultBindHost]
        }
        return normalizeHosts(raw)
    }

    /// Splits a comma-separated host list, trims whitespace, drops empties.
    private static func splitHostList(_ s: String) -> [String] {
        s.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Dedups (preserves order), then collapses to `["0.0.0.0"]` if present, and
    /// guarantees at least one entry (falling back to the default bind host).
    static func normalizeHosts(_ hosts: [String]) -> [String] {
        var seen = Set<String>()
        var deduped = hosts.filter { seen.insert($0).inserted }
        if deduped.contains("0.0.0.0") {
            deduped = ["0.0.0.0"]
        }
        if deduped.isEmpty {
            deduped = [Self.defaultBindHost]
        }
        return deduped
    }

    /// Parses `--key value` and `--key=value`. Bare `--flag` becomes `"true"`.
    private static func parseCLI(_ args: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var i = 1
        while i < args.count {
            let arg = args[i]
            guard arg.hasPrefix("--") else { i += 1; continue }
            let body = String(arg.dropFirst(2))
            if let eq = body.firstIndex(of: "=") {
                let k = String(body[..<eq])
                let v = String(body[body.index(after: eq)...])
                result[k] = v
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
