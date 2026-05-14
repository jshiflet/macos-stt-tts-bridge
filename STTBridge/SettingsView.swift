import SwiftUI
import Speech
import Security
import AppKit

struct ServerSettingsView: View {
    var body: some View {
        TabView {
            ServerSettingsTab()
                .tabItem { Label("Server", systemImage: "network") }
            AuthSettingsTab()
                .tabItem { Label("Authentication", systemImage: "key.fill") }
        }
        .frame(width: 540, height: 400)
        .padding(.top, 8)
    }
}

// MARK: - Shared warning banner

/// Yellow informational banner used by both settings tabs to flag security-relevant
/// configuration (network-reachable binds, missing auth token, etc.).
private struct SettingsWarningBanner: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout).bold()
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.yellow.opacity(0.15)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.yellow.opacity(0.6), lineWidth: 1))
    }
}

// MARK: - Server tab

private struct ServerSettingsTab: View {
    @EnvironmentObject var serverMgr: ServerManager

    @State private var interfaces: [NetworkInterfaces.Interface] = []
    @State private var supportedLocales: [String] = []
    @State private var portText: String = ""

    private static let allInterfaces = "0.0.0.0"
    private static let localhost = "127.0.0.1"

    var body: some View {
        Form {
            Section {
                if let warning = bindWarning {
                    SettingsWarningBanner(title: warning.title, detail: warning.detail)
                }

                Toggle("All interfaces (0.0.0.0)", isOn: bindBinding(for: Self.allInterfaces))
                Toggle("Localhost only (127.0.0.1)", isOn: bindBinding(for: Self.localhost))
                    .disabled(serverMgr.bindHosts.contains(Self.allInterfaces))
                ForEach(interfaces) { iface in
                    Toggle("\(iface.address) — \(iface.name)", isOn: bindBinding(for: iface.address))
                        .disabled(serverMgr.bindHosts.contains(Self.allInterfaces))
                }
                ForEach(customHosts, id: \.self) { host in
                    Toggle("\(host) (custom)", isOn: bindBinding(for: host))
                        .disabled(serverMgr.bindHosts.contains(Self.allInterfaces))
                }

                HStack {
                    TextField("Port:", text: $portText)
                        .frame(width: 100)
                        .onSubmit { applyPort() }
                    Text("Press Return to apply")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh interfaces") {
                        interfaces = NetworkInterfaces.activeIPv4Addresses()
                    }
                }
            } header: {
                Text("Network").font(.headline)
            } footer: {
                Text("Select one or more addresses to bind to. 0.0.0.0 covers all interfaces and overrides every other selection; selecting any other address disables it. At least one address is always selected — unchecking the last one reverts to 127.0.0.1.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Default language:", selection: langBinding) {
                    ForEach(displayLocales, id: \.self) { code in
                        Text(displayLabel(for: code)).tag(code)
                    }
                }
                .pickerStyle(.menu)

                Toggle("Require on-device recognition (offline)", isOn: offlineBinding)
            } header: {
                Text("Recognition").font(.headline)
            } footer: {
                Text("The default language is used when a request does not specify one. Offline mode forces on-device recognition for every request.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text(serverMgr.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            interfaces = NetworkInterfaces.activeIPv4Addresses()
            supportedLocales = SFSpeechRecognizer.supportedLocales().map(\.identifier).sorted()
            portText = String(serverMgr.port)
        }
        .onChange(of: serverMgr.port) { _, new in portText = String(new) }
    }

    // MARK: Bindings

    /// Per-address toggle binding. Enforces:
    ///   • Selecting 0.0.0.0 clears every other address (subsumed).
    ///   • Selecting a specific address clears 0.0.0.0.
    ///   • Unchecking the last address falls back to 127.0.0.1 so the list is never empty.
    private func bindBinding(for address: String) -> Binding<Bool> {
        Binding(
            get: { serverMgr.bindHosts.contains(address) },
            set: { isOn in
                var hosts = serverMgr.bindHosts
                if isOn {
                    if address == Self.allInterfaces {
                        hosts = [Self.allInterfaces]
                    } else {
                        hosts.removeAll { $0 == Self.allInterfaces }
                        if !hosts.contains(address) { hosts.append(address) }
                    }
                } else {
                    hosts.removeAll { $0 == address }
                    if hosts.isEmpty { hosts = [Self.localhost] }
                }
                let normalized = Config.normalizeHosts(hosts)
                guard normalized != serverMgr.bindHosts else { return }
                UserDefaults.standard.set(normalized, forKey: Config.bindHostsKey)
                serverMgr.reload()
            }
        )
    }

    private var langBinding: Binding<String> {
        Binding(
            get: { serverMgr.defaultLang },
            set: { new in
                guard new != serverMgr.defaultLang else { return }
                UserDefaults.standard.set(new, forKey: Config.defaultLangKey)
                serverMgr.reload()
            }
        )
    }

    private var offlineBinding: Binding<Bool> {
        Binding(
            get: { serverMgr.offlineOnly },
            set: { new in
                guard new != serverMgr.offlineOnly else { return }
                UserDefaults.standard.set(new, forKey: Config.offlineOnlyKey)
                serverMgr.reload()
            }
        )
    }

    private func applyPort() {
        guard let p = Int(portText), p > 0, p < 65536, p != serverMgr.port else {
            portText = String(serverMgr.port)
            return
        }
        UserDefaults.standard.set(p, forKey: Config.portKey)
        serverMgr.reload()
    }

    // MARK: Helpers

    /// Any host the user has selected that isn't one of the well-known options
    /// (`0.0.0.0` / `127.0.0.1`) and isn't a detected NIC. These get rendered with
    /// a `(custom)` suffix so a CLI-supplied address still appears in the list.
    private var customHosts: [String] {
        let known: Set<String> = Set([Self.allInterfaces, Self.localhost] + interfaces.map(\.address))
        return serverMgr.bindHosts.filter { !known.contains($0) }
    }

    /// Returns banner copy whenever the bind set contains any non-loopback host.
    /// Copy depends on whether a token is already configured: if so, this is just
    /// an informational reminder; if not, it's an actionable prompt to go set one.
    private var bindWarning: (title: String, detail: String)? {
        let nonLoopback = HTTPServer.nonLoopbackHosts(serverMgr.bindHosts)
        guard !nonLoopback.isEmpty else { return nil }
        let hostList = nonLoopback.joined(separator: ", ")
        if serverMgr.authToken.isEmpty {
            return (
                title: "Authentication will be required",
                detail: "\(hostList) accepts connections from the network. Set an auth token on the Authentication tab — until you do, all requests to /stt, /tts, and /say are rejected with 401."
            )
        } else {
            return (
                title: "Network-reachable bind — authentication enforced",
                detail: "\(hostList) accepts connections from the network. The configured auth token is required for /stt, /tts, /say, and the STT WebSocket."
            )
        }
    }

    private var displayLocales: [String] {
        var list = supportedLocales
        if !list.contains(serverMgr.defaultLang), !serverMgr.defaultLang.isEmpty {
            list.insert(serverMgr.defaultLang, at: 0)
        }
        return list
    }

    private func displayLabel(for code: String) -> String {
        let locale = Locale(identifier: code)
        if let name = Locale.current.localizedString(forIdentifier: code), !name.isEmpty {
            return "\(name) (\(code))"
        }
        return locale.identifier
    }
}

// MARK: - Auth tab

private struct AuthSettingsTab: View {
    @EnvironmentObject var serverMgr: ServerManager

    @State private var tokenText: String = ""
    @State private var revealToken: Bool = false
    @State private var copyConfirmation: String = ""

    var body: some View {
        Form {
            Section {
                authStatusView

                HStack {
                    Group {
                        if revealToken {
                            TextField("Token", text: $tokenText)
                        } else {
                            SecureField("Token", text: $tokenText)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { applyToken() }

                    Button {
                        revealToken.toggle()
                    } label: {
                        Image(systemName: revealToken ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(revealToken ? "Hide token" : "Show token")
                }

                HStack {
                    Button("Generate") {
                        tokenText = Self.generateToken()
                        applyToken()
                    }
                    Button("Apply") { applyToken() }
                        .disabled(tokenText == serverMgr.authToken)
                    Button("Copy") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(tokenText, forType: .string)
                        copyConfirmation = "Copied to clipboard."
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            if copyConfirmation == "Copied to clipboard." { copyConfirmation = "" }
                        }
                    }
                    .disabled(tokenText.isEmpty)
                    Spacer()
                    Button(role: .destructive) {
                        tokenText = ""
                        applyToken()
                    } label: {
                        Text("Clear")
                    }
                    .disabled(serverMgr.authToken.isEmpty && tokenText.isEmpty)
                }

                if !copyConfirmation.isEmpty {
                    Text(copyConfirmation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Authentication").font(.headline)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Send the token in one of these ways:")
                    Text("• HTTP: Authorization: Bearer <token>")
                        .font(.system(.caption, design: .monospaced))
                    Text("• WebSocket: ?token=<token> in the URL")
                        .font(.system(.caption, design: .monospaced))
                    Text("An empty token disables authentication, but only when every bound address is loopback. Any non-loopback bind requires a token.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { tokenText = serverMgr.authToken }
        .onChange(of: serverMgr.authToken) { _, new in tokenText = new }
    }

    @ViewBuilder
    private var authStatusView: some View {
        if let warning = authWarning() {
            SettingsWarningBanner(title: warning.title, detail: warning.detail)
        } else {
            Text("Clients must supply this token to call /stt, /tts, /say, or open the STT WebSocket.")
                .foregroundStyle(.secondary)
        }
    }

    private func authWarning() -> (title: String, detail: String)? {
        guard serverMgr.authToken.isEmpty else { return nil }
        let nonLoopback = HTTPServer.nonLoopbackHosts(serverMgr.bindHosts)
        if nonLoopback.isEmpty {
            return (
                title: "No auth token is set",
                detail: "Any website you visit in your browser could issue requests to this local server. Click Generate below to set a token."
            )
        }
        return (
            title: "Authentication required for \(nonLoopback.joined(separator: ", "))",
            detail: "These bind addresses are reachable from the network. All requests to /stt, /tts, and /say are rejected with 401 until a token is set."
        )
    }



    private func applyToken() {
        let trimmed = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != serverMgr.authToken else { return }
        if trimmed.isEmpty {
            KeychainAuthToken.delete()
        } else {
            KeychainAuthToken.save(trimmed)
        }
        tokenText = trimmed
        serverMgr.reload()
    }

    /// 32 cryptographically random bytes encoded as 64 hex characters.
    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Extremely unlikely; fall back to UUIDs concatenated.
            return (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
