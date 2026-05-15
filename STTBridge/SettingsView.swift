import SwiftUI
import Speech
import Security
import AppKit
import UniformTypeIdentifiers

struct ServerSettingsView: View {
    var body: some View {
        TabView {
            ServerSettingsTab()
                .tabItem { Label("Server", systemImage: "network") }
            AuthSettingsTab()
                .tabItem { Label("Authentication", systemImage: "key.fill") }
            TLSSettingsTab()
                .tabItem { Label("TLS", systemImage: "lock.shield") }
        }
        .frame(width: 580, height: 520)
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

                LabeledContent("Port:") {
                    HStack(spacing: 6) {
                        TextField("", text: $portText)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                        Button("Set Port") { applyPort() }
                            .disabled(!portTextIsValidChange)
                    }
                }
                HStack {
                    Button("Refresh interfaces") {
                        interfaces = NetworkInterfaces.activeIPv4Addresses()
                    }
                    Spacer()
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

    /// True when the Port field holds a valid port number different from the
    /// current one — enables the "Set Port" button.
    private var portTextIsValidChange: Bool {
        guard let p = Int(portText), p > 0, p < 65536 else { return false }
        return p != serverMgr.port
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
// MARK: - TLS tab

private struct TLSSettingsTab: View {
    @EnvironmentObject var serverMgr: ServerManager

    @State private var passwordText: String = ""
    @State private var revealPassword: Bool = false
    @State private var testResult: TestResult?
    @State private var p12Present: Bool = CertificateStore.hasPKCS12()
    @State private var pemCertPresent: Bool = CertificateStore.hasPEMCertificate()
    @State private var pemKeyPresent: Bool = CertificateStore.hasPEMKey()
    @State private var redirectPortText: String = ""

    private var certComplete: Bool {
        CertificateStore.isComplete(format: serverMgr.tlsCertFormat)
    }

    private func refreshCertState() {
        p12Present = CertificateStore.hasPKCS12()
        pemCertPresent = CertificateStore.hasPEMCertificate()
        pemKeyPresent = CertificateStore.hasPEMKey()
    }

    private enum TestResult {
        case success(CertificateInfo)
        case failure(String)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable HTTPS", isOn: tlsEnabledBinding)
                if serverMgr.tlsEnabled && !certComplete {
                    SettingsWarningBanner(
                        title: "HTTPS enabled but certificate is incomplete",
                        detail: "The server will fail to start until the required certificate files are imported below."
                    )
                }
            } header: {
                Text("HTTPS").font(.headline)
            } footer: {
                Text("When enabled, every bound address listens with TLS. URLs become https:// and the WebSocket endpoint becomes wss://.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Format:", selection: certFormatBinding) {
                    ForEach(TLSCertificateFormat.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)

                switch serverMgr.tlsCertFormat {
                case .pkcs12:
                    pkcs12Section
                case .pem:
                    pemSection
                }

                HStack {
                    Group {
                        if revealPassword {
                            TextField(passwordPlaceholder, text: $passwordText)
                        } else {
                            SecureField(passwordPlaceholder, text: $passwordText)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { applyPassword() }

                    Button { revealPassword.toggle() } label: {
                        Image(systemName: revealPassword ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(revealPassword ? "Hide password" : "Show password")
                }

                HStack {
                    Button("Save password") { applyPassword() }
                        .disabled(passwordText == (serverMgr.tlsEnabled ? (Config().tlsP12Password ?? "") : ""))
                    Button("Test certificate") { runTest() }
                        .disabled(!certComplete)
                    Spacer()
                }

                if let result = testResult {
                    testResultView(result)
                }
            } header: {
                Text("Certificate").font(.headline)
            } footer: {
                Text(certificateFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Redirect HTTP to HTTPS", isOn: redirectEnabledBinding)
                if serverMgr.httpRedirectPort > 0 {
                    LabeledContent("Redirect port:") {
                        HStack(spacing: 6) {
                            TextField("", text: $redirectPortText)
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                            Button("Set Port") { applyRedirectPort() }
                                .disabled(!redirectPortTextIsValidChange)
                        }
                    }
                    if serverMgr.httpRedirectPort == serverMgr.port {
                        Text("Redirect port matches the HTTPS port — redirect is ignored.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("HTTP → HTTPS Upgrade").font(.headline)
            } footer: {
                Text("When enabled, a plain-HTTP listener on the chosen port answers every request with 308 Permanent Redirect to the matching https:// URL. Only active when HTTPS is on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Minimum:", selection: minVersionBinding) {
                    ForEach(TLSVersionPref.ordered) { v in Text(v.rawValue).tag(v) }
                }
                Picker("Maximum:", selection: maxVersionBinding) {
                    ForEach(TLSVersionPref.ordered) { v in Text(v.rawValue).tag(v) }
                }
                if serverMgr.tlsMinVersion.rank > serverMgr.tlsMaxVersion.rank {
                    Text("Minimum is higher than maximum — the server will swap them when starting.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("TLS Versions").font(.headline)
            } footer: {
                Text("TLS 1.0 / 1.1 are deprecated and only useful for legacy clients. TLS 1.3 is recommended.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Use NIO defaults", isOn: useDefaultsBinding)
                if !useDefaults {
                    ForEach(TLSCipherCatalog.recommended, id: \.self) { cipher in
                        Toggle(cipher, isOn: cipherBinding(for: cipher))
                            .font(.system(.callout, design: .monospaced))
                    }
                }
            } header: {
                Text("Cipher Suites (TLS ≤ 1.2)").font(.headline)
            } footer: {
                Text("TLS 1.3 cipher suites are fixed by RFC 8446 (AES-GCM and ChaCha20-Poly1305) and cannot be customized.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            passwordText = serverMgr.tlsEnabled ? (Config().tlsP12Password ?? "") : ""
            refreshCertState()
            redirectPortText = String(serverMgr.httpRedirectPort)
        }
        .onChange(of: serverMgr.httpRedirectPort) { _, new in
            redirectPortText = String(new)
        }
        .onChange(of: serverMgr.tlsCertFormat) { _, _ in
            refreshCertState()
            testResult = nil
        }
    }

    // MARK: Per-format subviews

    @ViewBuilder
    private var pkcs12Section: some View {
        HStack {
            Image(systemName: p12Present ? "checkmark.seal.fill" : "xmark.seal")
                .foregroundStyle(p12Present ? .green : .secondary)
            Text(p12Present
                 ? "Bundle imported: \(CertificateStore.p12Filename)"
                 : "No PKCS#12 bundle imported")
                .font(.callout)
            Spacer()
        }
        HStack {
            Button("Choose .p12 / .pfx…") { importPKCS12() }
            if p12Present {
                Button(role: .destructive) {
                    CertificateStore.deletePKCS12()
                    refreshCertState()
                    testResult = nil
                    serverMgr.reload()
                } label: { Text("Remove") }
            }
        }
    }

    @ViewBuilder
    private var pemSection: some View {
        HStack {
            Image(systemName: pemCertPresent ? "checkmark.seal.fill" : "xmark.seal")
                .foregroundStyle(pemCertPresent ? .green : .secondary)
            Text(pemCertPresent
                 ? "Certificate: \(CertificateStore.pemCertFilename)"
                 : "No certificate file imported")
                .font(.callout)
            Spacer()
            Button("Choose cert…") { importPEMCert() }
        }
        HStack {
            Image(systemName: pemKeyPresent ? "checkmark.seal.fill" : "xmark.seal")
                .foregroundStyle(pemKeyPresent ? .green : .secondary)
            Text(pemKeyPresent
                 ? "Private key: \(CertificateStore.pemKeyFilename)"
                 : "No private key file imported")
                .font(.callout)
            Spacer()
            Button("Choose key…") { importPEMKey() }
        }
        if pemCertPresent || pemKeyPresent {
            HStack {
                Spacer()
                Button(role: .destructive) {
                    CertificateStore.deletePEMFiles()
                    refreshCertState()
                    testResult = nil
                    serverMgr.reload()
                } label: { Text("Remove PEM files") }
            }
        }
    }

    // MARK: Computed strings

    private var passwordPlaceholder: String {
        switch serverMgr.tlsCertFormat {
        case .pkcs12: return "PKCS#12 password"
        case .pem:    return "Private key password (leave empty if unencrypted)"
        }
    }

    private var certificateFooter: String {
        switch serverMgr.tlsCertFormat {
        case .pkcs12:
            return "PKCS#12 bundles ship the cert chain and private key together. The bundle password is held in the Keychain."
        case .pem:
            return "PEM mode reads the certificate chain from server-cert.pem and the private key from server-key.pem. The password is only required if the key is AES- or 3DES-encrypted (typically a PEM file starting with ENCRYPTED PRIVATE KEY)."
        }
    }

    // MARK: Bindings

    private var tlsEnabledBinding: Binding<Bool> {
        Binding(
            get: { serverMgr.tlsEnabled },
            set: { newValue in
                guard newValue != serverMgr.tlsEnabled else { return }
                UserDefaults.standard.set(newValue, forKey: Config.tlsEnabledKey)
                applyHTTPSDefaultPortsIfReady(tlsEnabled: newValue)
                serverMgr.reload()
            }
        )
    }

    /// When HTTPS gets enabled with a usable certificate, snap the listening
    /// port to 8888 and the HTTP redirect port to 8787 so the conventional
    /// "HTTPS on a custom port + plain HTTP for upgrade" layout is one click away.
    /// No-op when TLS is off or the certificate material is incomplete.
    private func applyHTTPSDefaultPortsIfReady(tlsEnabled: Bool) {
        guard tlsEnabled,
              CertificateStore.isComplete(format: serverMgr.tlsCertFormat)
        else { return }
        UserDefaults.standard.set(8888, forKey: Config.portKey)
        UserDefaults.standard.set(8787, forKey: Config.httpRedirectPortKey)
    }

    private var certFormatBinding: Binding<TLSCertificateFormat> {
        Binding(
            get: { serverMgr.tlsCertFormat },
            set: { newValue in
                guard newValue != serverMgr.tlsCertFormat else { return }
                UserDefaults.standard.set(newValue.rawValue, forKey: Config.tlsCertFormatKey)
                serverMgr.reload()
            }
        )
    }

    private var minVersionBinding: Binding<TLSVersionPref> {
        Binding(
            get: { serverMgr.tlsMinVersion },
            set: { newValue in
                guard newValue != serverMgr.tlsMinVersion else { return }
                UserDefaults.standard.set(newValue.rawValue, forKey: Config.tlsMinVersionKey)
                serverMgr.reload()
            }
        )
    }

    private var maxVersionBinding: Binding<TLSVersionPref> {
        Binding(
            get: { serverMgr.tlsMaxVersion },
            set: { newValue in
                guard newValue != serverMgr.tlsMaxVersion else { return }
                UserDefaults.standard.set(newValue.rawValue, forKey: Config.tlsMaxVersionKey)
                serverMgr.reload()
            }
        )
    }

    private var useDefaults: Bool { serverMgr.tlsCustomCiphers == nil }

    private var useDefaultsBinding: Binding<Bool> {
        Binding(
            get: { useDefaults },
            set: { newValue in
                if newValue {
                    UserDefaults.standard.removeObject(forKey: Config.tlsCustomCiphersKey)
                } else {
                    // Switching to custom — seed with the full recommended list.
                    UserDefaults.standard.set(TLSCipherCatalog.recommended, forKey: Config.tlsCustomCiphersKey)
                }
                serverMgr.reload()
            }
        )
    }

    private var redirectEnabledBinding: Binding<Bool> {
        Binding(
            get: { serverMgr.httpRedirectPort > 0 },
            set: { isOn in
                if isOn {
                    // Pick a sensible default that doesn't collide with the HTTPS port.
                    let candidate = serverMgr.port == 8080 ? 8081 : 8080
                    UserDefaults.standard.set(candidate, forKey: Config.httpRedirectPortKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: Config.httpRedirectPortKey)
                }
                serverMgr.reload()
            }
        )
    }

    private func applyRedirectPort() {
        guard let p = Int(redirectPortText), p > 0, p < 65536, p != serverMgr.httpRedirectPort else {
            redirectPortText = String(serverMgr.httpRedirectPort)
            return
        }
        UserDefaults.standard.set(p, forKey: Config.httpRedirectPortKey)
        serverMgr.reload()
    }

    /// Enabled state for the TLS-tab "Set Port" button next to the redirect field.
    private var redirectPortTextIsValidChange: Bool {
        guard let p = Int(redirectPortText), p > 0, p < 65536 else { return false }
        return p != serverMgr.httpRedirectPort
    }

    private func cipherBinding(for name: String) -> Binding<Bool> {
        Binding(
            get: { (serverMgr.tlsCustomCiphers ?? []).contains(name) },
            set: { isOn in
                var list = serverMgr.tlsCustomCiphers ?? []
                if isOn {
                    if !list.contains(name) { list.append(name) }
                } else {
                    list.removeAll { $0 == name }
                }
                if list.isEmpty {
                    // Don't allow an empty whitelist (= no ciphers, broken). Revert to defaults.
                    UserDefaults.standard.removeObject(forKey: Config.tlsCustomCiphersKey)
                } else {
                    UserDefaults.standard.set(list, forKey: Config.tlsCustomCiphersKey)
                }
                serverMgr.reload()
            }
        )
    }

    // MARK: Actions

    private func runOpenPanel(title: String, extensions: [String]) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let allowed = extensions.compactMap { UTType(filenameExtension: $0) }
        if !allowed.isEmpty { panel.allowedContentTypes = allowed }
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func importPKCS12() {
        guard let url = runOpenPanel(title: "Select PKCS#12 bundle", extensions: ["p12", "pfx"]) else { return }
        do {
            _ = try CertificateStore.importPKCS12(from: url)
            refreshCertState()
            testResult = nil
            applyHTTPSDefaultPortsIfReady(tlsEnabled: serverMgr.tlsEnabled)
            serverMgr.reload()
        } catch {
            testResult = .failure("Import failed: \(error.localizedDescription)")
        }
    }

    private func importPEMCert() {
        guard let url = runOpenPanel(title: "Select PEM certificate (chain)", extensions: ["pem", "crt", "cer"]) else { return }
        do {
            _ = try CertificateStore.importPEMCertificate(from: url)
            refreshCertState()
            testResult = nil
            applyHTTPSDefaultPortsIfReady(tlsEnabled: serverMgr.tlsEnabled)
            serverMgr.reload()
        } catch {
            testResult = .failure("Import failed: \(error.localizedDescription)")
        }
    }

    private func importPEMKey() {
        guard let url = runOpenPanel(title: "Select PEM private key", extensions: ["pem", "key"]) else { return }
        do {
            _ = try CertificateStore.importPEMKey(from: url)
            refreshCertState()
            testResult = nil
            applyHTTPSDefaultPortsIfReady(tlsEnabled: serverMgr.tlsEnabled)
            serverMgr.reload()
        } catch {
            testResult = .failure("Import failed: \(error.localizedDescription)")
        }
    }

    private func applyPassword() {
        let trimmed = passwordText
        if trimmed.isEmpty {
            KeychainTLSPassword.delete()
        } else {
            KeychainTLSPassword.save(trimmed)
        }
        serverMgr.reload()
    }

    private func runTest() {
        do {
            let info = try CertificateStore.inspect(format: serverMgr.tlsCertFormat, password: passwordText)
            testResult = .success(info)
        } catch {
            testResult = .failure(error.localizedDescription)
        }
    }

    @ViewBuilder
    private func testResultView(_ result: TestResult) -> some View {
        switch result {
        case .success(let info):
            VStack(alignment: .leading, spacing: 4) {
                Label("Certificate loaded", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("Subject: \(info.subject)").font(.caption)
                if !info.issuer.isEmpty {
                    Text("Issuer: \(info.issuer)").font(.caption)
                }
                Text("Valid from \(info.validFrom, format: .dateTime.day().month().year()) to \(info.validUntil, format: .dateTime.day().month().year())").font(.caption)
                if info.isExpired {
                    Text("EXPIRED")
                        .font(.caption).bold()
                        .foregroundStyle(.red)
                } else if info.daysUntilExpiry < 30 {
                    Text("Expires in \(info.daysUntilExpiry) day(s)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.green.opacity(0.08)))
        case .failure(let msg):
            Label(msg, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

