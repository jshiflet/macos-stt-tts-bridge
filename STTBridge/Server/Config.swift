import Foundation

struct Config {
    static let defaultBindHost = "127.0.0.1"
    static let defaultPort = 8787
    static let defaultLanguage = "en-US"

    static let bindHostKey = "bindHost"
    static let portKey = "port"
    static let authTokenKey = "authToken"
    static let defaultLangKey = "defaultLang"
    static let offlineOnlyKey = "offlineOnly"

    let port: Int
    let bindHost: String
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

        if let cliHost = cli["bind-host"], !cliHost.isEmpty {
            bindHost = cliHost
        } else if let stored = defaults.string(forKey: Self.bindHostKey), !stored.isEmpty {
            bindHost = stored
        } else {
            bindHost = env["BIND_HOST"] ?? Self.defaultBindHost
        }

        if let cliToken = cli["auth-token"] {
            authToken = cliToken.isEmpty ? nil : cliToken
        } else if let stored = defaults.string(forKey: Self.authTokenKey), !stored.isEmpty {
            authToken = stored
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
