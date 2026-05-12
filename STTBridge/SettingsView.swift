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
                Picker("Bind address:", selection: hostBinding) {
                    Text("All interfaces (0.0.0.0)").tag(Self.allInterfaces)
                    Text("Localhost only (127.0.0.1)").tag(Self.localhost)
                    if !interfaces.isEmpty {
                        Divider()
                        ForEach(interfaces) { iface in
                            Text("\(iface.address) — \(iface.name)").tag(iface.address)
                        }
                    }
                    if !selectedHostIsKnown {
                        Divider()
                        Text("\(serverMgr.bindHost) (current)").tag(serverMgr.bindHost)
                    }
                }
                .pickerStyle(.menu)

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
                Text("Choose 0.0.0.0 to accept connections from any network interface, 127.0.0.1 to limit the server to this Mac, or pick a specific address to bind to a single interface.")
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

    private var hostBinding: Binding<String> {
        Binding(
            get: { serverMgr.bindHost },
            set: { new in
                guard new != serverMgr.bindHost else { return }
                UserDefaults.standard.set(new, forKey: Config.bindHostKey)
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

    private var selectedHostIsKnown: Bool {
        if serverMgr.bindHost == Self.allInterfaces || serverMgr.bindHost == Self.localhost { return true }
        return interfaces.contains { $0.address == serverMgr.bindHost }
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
                if serverMgr.authToken.isEmpty {
                    Text("No auth token is set — all requests are accepted.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Clients must supply this token to call /stt, /tts, /say, or open the STT WebSocket.")
                        .foregroundStyle(.secondary)
                }

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
                    Text("An empty token disables authentication.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { tokenText = serverMgr.authToken }
        .onChange(of: serverMgr.authToken) { _, new in tokenText = new }
    }

    private func applyToken() {
        let trimmed = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != serverMgr.authToken else { return }
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: Config.authTokenKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: Config.authTokenKey)
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
