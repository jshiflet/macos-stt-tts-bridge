import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - ACME settings tab

/// Drives the ACME issuance and renewal workflow. Mirrors the structural
/// patterns from `TLSSettingsTab` in `SettingsView.swift` — Form + grouped
/// Sections, UserDefaults-write + ServerManager.reload binding, eye-toggled
/// SecureField for sensitive input — so the user gets a consistent feel
/// across the Settings window.
struct ACMESettingsTab: View {
    @EnvironmentObject var serverMgr: ServerManager

    // Local text-field state. We don't write each keystroke to UserDefaults;
    // a Save button or onSubmit commits the change.
    @State private var domainsText: String = ""
    @State private var accountEmailText: String = ""
    @State private var customDirectoryURLText: String = ""
    @State private var customResolverHostText: String = ""
    @State private var customDoHURLText: String = ""
    @State private var renewDaysText: String = ""
    @State private var dnsTimeoutText: String = ""
    @State private var dnsPollText: String = ""

    // Cloudflare token UI state — held locally so the SecureField doesn't
    // round-trip through Keychain on every keystroke.
    @State private var cloudflareTokenText: String = ""
    @State private var revealCloudflareToken = false
    @State private var cloudflareTokenSaved: Bool = (KeychainCloudflareToken.load()?.isEmpty == false)

    // Account-import disclosure state.
    @State private var showImportPanel = false
    @State private var importKeyPEM: String = ""
    @State private var importAccountURL: String = ""
    @State private var importError: String?

    // Async work flags.
    @State private var requesting = false
    @State private var registering = false

    // Local CA picker selection so the custom-URL field can drive a
    // re-binding without losing the typed value.
    @State private var caSelection: CASelection = .letsEncryptProd

    enum CASelection: String, CaseIterable, Identifiable {
        case letsEncryptProd, letsEncryptStaging, custom
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .letsEncryptProd:    return "Let's Encrypt (Production)"
            case .letsEncryptStaging: return "Let's Encrypt (Staging)"
            case .custom:             return "Custom directory URL"
            }
        }
    }

    var body: some View {
        Form {
            caSection
            accountSection
            profileSection
            keySection
            domainsAndChallengeSection
            dnsValidationSection
            autoRenewSection
            actionsSection
        }
        .formStyle(.grouped)
        .onAppear {
            refreshLocalCopies()
            // Populate the CA's available profiles on first appearance — the
            // directory call is cheap and lets the picker show real options
            // without the user having to hit Refresh manually.
            if serverMgr.acmeAvailableProfiles.isEmpty {
                Task { await refreshProfiles() }
            }
        }
        .onChange(of: serverMgr.acmeCA) { _, _ in
            refreshLocalCopies()
            // CA changed — its profile list almost certainly differs, so
            // re-fetch instead of showing stale entries.
            Task { await refreshProfiles() }
        }
        .onChange(of: serverMgr.acmeAccountEmail) { _, new in accountEmailText = new }
        .onChange(of: serverMgr.acmeDomains) { _, new in domainsText = new }
        .onChange(of: serverMgr.acmeRenewWhenDaysRemain) { _, new in renewDaysText = String(new) }
        .onChange(of: serverMgr.acmeDNSTimeoutSeconds) { _, new in dnsTimeoutText = String(new) }
        .onChange(of: serverMgr.acmeDNSPollSeconds) { _, new in dnsPollText = String(new) }
    }

    // MARK: - Sections

    @ViewBuilder
    private var caSection: some View {
        Section {
            Picker("Certificate Authority:", selection: $caSelection) {
                ForEach(CASelection.allCases) { c in
                    Text(c.displayName).tag(c)
                }
            }
            .onChange(of: caSelection) { _, new in applyCASelection(new) }

            if caSelection == .custom {
                TextField("Directory URL", text: $customDirectoryURLText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { applyCustomDirectoryURL() }
                Button("Save URL") { applyCustomDirectoryURL() }
                    .disabled(customDirectoryURLText == (UserDefaults.standard.string(forKey: ACMEConfig.customDirectoryURLKey) ?? ""))
            }
        } header: {
            Text("Certificate Authority").font(.headline)
        } footer: {
            Text("Use Staging while you're getting the integration working — its rate limits are higher than Production and you won't waste an issuance attempt against the real CA.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if let warning = accountWarning {
                SettingsWarningBanner(title: warning.title, detail: warning.detail)
            }

            TextField("Account email", text: $accountEmailText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { applyAccountEmail() }

            HStack {
                if serverMgr.acmeAccountRegistered {
                    Button(role: .destructive) {
                        forgetAccount()
                    } label: { Text("Forget account") }
                }
                Spacer()
                Button("Save email") { applyAccountEmail() }
                    .disabled(accountEmailText == serverMgr.acmeAccountEmail)
                Button(registering ? "Registering…" : "Register account") {
                    Task { await registerAccount() }
                }
                .disabled(registering || accountEmailText.trimmingCharacters(in: .whitespaces).isEmpty || serverMgr.acmeAccountRegistered)
            }

            if serverMgr.acmeAccountRegistered {
                accountRegisteredView
            } else {
                Text("Not yet registered with this CA.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            DisclosureGroup("Import existing account…", isExpanded: $showImportPanel) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Paste the PEM private key:")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $importKeyPEM)
                        .frame(minHeight: 80, maxHeight: 140)
                        .border(Color.secondary.opacity(0.3))
                        .font(.system(.caption, design: .monospaced))

                    TextField("Account URL (e.g. https://acme-v02.api.letsencrypt.org/acme/acct/123…)",
                              text: $importAccountURL)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button("Choose key file…") { chooseKeyFile() }
                        Button("Import") { importAccount() }
                            .disabled(importKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || importAccountURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let importError {
                        Text(importError).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(.top, 4)
            }
        } header: {
            Text("Account").font(.headline)
        } footer: {
            Text("The account private key is stored in the macOS Keychain. The CA stamps a unique URL on each account; importing an existing account requires both.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var accountRegisteredView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Registered with \(serverMgr.acmeCA.displayName)", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.callout)
            if !serverMgr.acmeAccountURL.isEmpty {
                HStack {
                    Text(serverMgr.acmeAccountURL)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(serverMgr.acmeAccountURL, forType: .string)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.green.opacity(0.08)))
    }

    @ViewBuilder
    private var profileSection: some View {
        Section {
            HStack {
                Picker("Profile:", selection: profileBinding) {
                    Text("Automatic (CA default)").tag(String?.none)
                    ForEach(serverMgr.acmeAvailableProfiles, id: \.self) { name in
                        Text(name).tag(Optional(name))
                    }
                }
                Button("Refresh") {
                    Task { await refreshProfiles() }
                }
                .help("Re-fetch the CA's advertised profile list")
            }
            if serverMgr.acmeAvailableProfiles.isEmpty {
                Text("This CA hasn't advertised any profiles, or none have been fetched yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Certificate Profile").font(.headline)
        } footer: {
            Text("Profiles let you pick alternate validity periods or signing algorithms a CA offers (e.g. classic, tlsserver, shortlived for Let's Encrypt). Automatic lets the CA pick its default.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var keySection: some View {
        Section {
            Picker("Algorithm:", selection: keyTypeBinding) {
                ForEach(ACMEKeyType.allCases) { kt in
                    Text(kt.displayName).tag(kt)
                }
            }
            .pickerStyle(.segmented)

            switch serverMgr.acmeKeyType {
            case .ecdsa:
                Picker("Curve:", selection: eccSizeBinding) {
                    ForEach(ACMEECCSize.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
            case .rsa:
                Picker("Key size:", selection: rsaSizeBinding) {
                    ForEach(ACMERSASize.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
            }
        } header: {
            Text("Certificate Key").font(.headline)
        } footer: {
            Text("ECDSA keys are smaller and faster; P-384 is the default Let's Encrypt accepts everywhere. RSA 2048 is the safe pick if a legacy client doesn't speak ECDSA. The choice applies to the next certificate issuance — already-installed certificates aren't affected.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var domainsAndChallengeSection: some View {
        Section {
            TextField("Domains (comma-separated, e.g. example.com, www.example.com)",
                      text: $domainsText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { applyDomains() }
            HStack {
                Spacer()
                Button("Save domains") { applyDomains() }
                    .disabled(domainsText == serverMgr.acmeDomains)
            }

            Picker("Challenge type:", selection: challengeTypeBinding) {
                ForEach(ACMEChallengeType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            if serverMgr.acmeChallengeType.isDraft {
                Text("Treated as standard DNS-01 until the draft is ratified; selection is preserved.")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Group {
                    if revealCloudflareToken {
                        TextField("Cloudflare API token", text: $cloudflareTokenText)
                    } else {
                        SecureField("Cloudflare API token", text: $cloudflareTokenText)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .onSubmit { applyCloudflareToken() }

                Button {
                    revealCloudflareToken.toggle()
                } label: {
                    Image(systemName: revealCloudflareToken ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
            }
            HStack {
                if cloudflareTokenSaved {
                    Button(role: .destructive) {
                        KeychainCloudflareToken.delete()
                        cloudflareTokenText = ""
                        cloudflareTokenSaved = false
                    } label: { Text("Clear token") }
                }
                Spacer()
                Button("Save token") { applyCloudflareToken() }
                    .disabled(cloudflareTokenText.isEmpty)
            }
            if cloudflareTokenSaved {
                Label("Token stored in Keychain", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
        } header: {
            Text("Domains & Challenge").font(.headline)
        } footer: {
            Text("The Cloudflare token needs Zone:Read and Zone.DNS:Edit for every zone you're requesting a certificate for. Tokens never leave the Keychain.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var dnsValidationSection: some View {
        Section {
            Picker("Mode:", selection: dnsModeBinding) {
                ForEach(ACMEDNSMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            Picker("Resolver:", selection: dnsResolverPresetBinding) {
                ForEach(ACMEDNSResolverPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .disabled(serverMgr.acmeDNSMode == .system)

            if serverMgr.acmeDNSResolverPreset == .custom && serverMgr.acmeDNSMode != .system {
                TextField("Resolver host or IP", text: $customResolverHostText)
                    .textFieldStyle(.roundedBorder)
                Button("Save host") { applyCustomResolverHost() }
                    .disabled(customResolverHostText == serverMgr.acmeCustomResolverHost)
            }

            if serverMgr.acmeDNSMode == .dnsOverHTTPS && serverMgr.acmeDNSResolverPreset == .custom {
                TextField("DoH URL (https://...)", text: $customDoHURLText)
                    .textFieldStyle(.roundedBorder)
                Button("Save URL") { applyCustomDoHURL() }
                    .disabled(customDoHURLText == serverMgr.acmeCustomDoHURL)
            }

            LabeledContent("DNS validation timeout:") {
                HStack(spacing: 6) {
                    TextField("", text: $dnsTimeoutText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { commitDNSTimeout() }
                    Stepper("", value: dnsTimeoutBinding, in: 1...3600, step: 10)
                        .labelsHidden()
                    Text("s").font(.callout)
                }
            }

            DisclosureGroup("Advanced") {
                LabeledContent("Propagation poll interval:") {
                    HStack(spacing: 6) {
                        TextField("", text: $dnsPollText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                            .onSubmit { commitDNSPoll() }
                        Stepper("", value: dnsPollBinding, in: 1...600, step: 1)
                            .labelsHidden()
                        Text("s").font(.callout)
                    }
                }
            }
        } header: {
            Text("DNS Validation").font(.headline)
        } footer: {
            Text("DoT and DoH bypass captive-portal and local-cache issues by talking directly to the chosen resolver over TLS. UDP is fastest. System honours your macOS DNS settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var autoRenewSection: some View {
        Section {
            Toggle("Automatically renew before expiry", isOn: autoRenewBinding)
            if serverMgr.acmeAutoRenewEnabled {
                LabeledContent("Renew when remaining:") {
                    HStack(spacing: 6) {
                        TextField("", text: $renewDaysText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                            .onSubmit { commitRenewDays() }
                        Stepper("", value: renewDaysBinding, in: 1...365, step: 1)
                            .labelsHidden()
                        Text("days").font(.callout)
                    }
                }
            }
        } header: {
            Text("Auto-renewal").font(.headline)
        } footer: {
            Text("A background timer checks the installed certificate once per day and re-issues when it falls below the threshold. Manual renewal is always available via the button below.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            HStack {
                if let last = serverMgr.acmeLastIssuedAt {
                    Text("Last issued: \(last, format: .dateTime.day().month().year().hour().minute())")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(requesting ? "Working…" : "Request certificate now") {
                    Task { await requestCertificate() }
                }
                .disabled(requesting || !canRequest)
            }
            if let profile = serverMgr.acmeLastProfileUsed {
                Text("Last profile used: \(profile)")
                    .font(.caption).foregroundStyle(.secondary)
            }

            statusView
        } header: {
            Text("Status").font(.headline)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch serverMgr.acmeStatus {
        case .idle:
            if let err = serverMgr.acmeLastError {
                Label(err, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red).font(.caption)
            } else {
                Text("Idle.").font(.caption).foregroundStyle(.secondary)
            }
        case .running(let stage):
            HStack {
                ProgressView().controlSize(.small)
                Text(stage).font(.caption)
            }
        case .success(let date):
            Label("Issued at \(date, format: .dateTime.hour().minute().second())", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green).font(.caption)
        case .failure(let msg):
            Label(msg, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red).font(.caption)
        }
    }

    // MARK: - Computed gating + warnings

    private var canRequest: Bool {
        !serverMgr.acmeDomains.isEmpty &&
        !serverMgr.acmeAccountEmail.isEmpty &&
        cloudflareTokenSaved
    }

    private var accountWarning: (title: String, detail: String)? {
        if !serverMgr.acmeAutoRenewEnabled { return nil }
        if serverMgr.acmeAccountEmail.isEmpty {
            return ("Auto-renewal needs an account email",
                    "Set an account email and register with the CA before enabling auto-renewal.")
        }
        if !serverMgr.acmeAccountRegistered {
            return ("Auto-renewal needs a registered account",
                    "Click Register account so renewals don't fail when the daily timer fires.")
        }
        if serverMgr.acmeDomains.isEmpty {
            return ("Auto-renewal needs at least one domain", "Add the domains to issue for.")
        }
        if !cloudflareTokenSaved {
            return ("Auto-renewal needs a Cloudflare token",
                    "DNS-01 challenges can't be published without an API token in the Keychain.")
        }
        return nil
    }

    // MARK: - Bindings

    private var profileBinding: Binding<String?> {
        Binding(
            get: { serverMgr.acmeProfileName },
            set: { new in
                if let new {
                    UserDefaults.standard.set(new, forKey: ACMEConfig.profileNameKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: ACMEConfig.profileNameKey)
                }
                serverMgr.reloadACMEMirrors()
            }
        )
    }

    private var challengeTypeBinding: Binding<ACMEChallengeType> {
        Binding(
            get: { serverMgr.acmeChallengeType },
            set: { new in
                UserDefaults.standard.set(new.rawValue, forKey: ACMEConfig.challengeTypeKey)
                serverMgr.reloadACMEMirrors()
            }
        )
    }

    private var dnsModeBinding: Binding<ACMEDNSMode> {
        Binding(
            get: { serverMgr.acmeDNSMode },
            set: { new in
                UserDefaults.standard.set(new.rawValue, forKey: ACMEConfig.dnsModeKey)
                serverMgr.reloadACMEMirrors()
            }
        )
    }

    private var dnsResolverPresetBinding: Binding<ACMEDNSResolverPreset> {
        Binding(
            get: { serverMgr.acmeDNSResolverPreset },
            set: { new in
                UserDefaults.standard.set(new.rawValue, forKey: ACMEConfig.dnsResolverPresetKey)
                serverMgr.reloadACMEMirrors()
            }
        )
    }

    private var dnsTimeoutBinding: Binding<Int> {
        Binding(
            get: { serverMgr.acmeDNSTimeoutSeconds },
            set: { new in
                UserDefaults.standard.set(new, forKey: ACMEConfig.dnsValidationTimeoutKey)
                serverMgr.reloadACMEMirrors()
            }
        )
    }

    private var dnsPollBinding: Binding<Int> {
        Binding(
            get: { serverMgr.acmeDNSPollSeconds },
            set: { new in
                UserDefaults.standard.set(new, forKey: ACMEConfig.dnsPropagationPollKey)
                serverMgr.reloadACMEMirrors()
            }
        )
    }

    private var autoRenewBinding: Binding<Bool> {
        Binding(
            get: { serverMgr.acmeAutoRenewEnabled },
            set: { new in
                UserDefaults.standard.set(new, forKey: ACMEConfig.autoRenewEnabledKey)
                serverMgr.reloadACMEMirrors()
            }
        )
    }

    private var keyTypeBinding: Binding<ACMEKeyType> {
        Binding(
            get: { serverMgr.acmeKeyType },
            set: { new in
                UserDefaults.standard.set(new.rawValue, forKey: ACMEConfig.keyTypeKey)
                serverMgr.reloadACMEMirrors()
            }
        )
    }

    private var eccSizeBinding: Binding<ACMEECCSize> {
        Binding(
            get: { serverMgr.acmeECCSize },
            set: { new in
                UserDefaults.standard.set(new.rawValue, forKey: ACMEConfig.eccSizeKey)
                serverMgr.reloadACMEMirrors()
            }
        )
    }

    private var rsaSizeBinding: Binding<ACMERSASize> {
        Binding(
            get: { serverMgr.acmeRSASize },
            set: { new in
                UserDefaults.standard.set(new.rawValue, forKey: ACMEConfig.rsaSizeKey)
                serverMgr.reloadACMEMirrors()
            }
        )
    }

    private var renewDaysBinding: Binding<Int> {
        Binding(
            get: { serverMgr.acmeRenewWhenDaysRemain },
            set: { new in
                UserDefaults.standard.set(new, forKey: ACMEConfig.renewWhenDaysRemainKey)
                serverMgr.reloadACMEMirrors()
            }
        )
    }

    // MARK: - Field commit handlers

    private func refreshLocalCopies() {
        accountEmailText = serverMgr.acmeAccountEmail
        domainsText = serverMgr.acmeDomains
        customDirectoryURLText = serverMgr.acmeCustomDirectoryURL
        customResolverHostText = serverMgr.acmeCustomResolverHost
        customDoHURLText = serverMgr.acmeCustomDoHURL
        renewDaysText = String(serverMgr.acmeRenewWhenDaysRemain)
        dnsTimeoutText = String(serverMgr.acmeDNSTimeoutSeconds)
        dnsPollText = String(serverMgr.acmeDNSPollSeconds)
        cloudflareTokenSaved = (KeychainCloudflareToken.load()?.isEmpty == false)
        switch serverMgr.acmeCA {
        case .letsEncryptProd: caSelection = .letsEncryptProd
        case .letsEncryptStaging: caSelection = .letsEncryptStaging
        case .custom: caSelection = .custom
        }
    }

    private func applyCASelection(_ new: CASelection) {
        switch new {
        case .letsEncryptProd:
            UserDefaults.standard.set("letsEncryptProd", forKey: ACMEConfig.caKindKey)
        case .letsEncryptStaging:
            UserDefaults.standard.set("letsEncryptStaging", forKey: ACMEConfig.caKindKey)
        case .custom:
            UserDefaults.standard.set("custom", forKey: ACMEConfig.caKindKey)
        }
        serverMgr.reloadACMEMirrors()
    }

    private func applyCustomDirectoryURL() {
        UserDefaults.standard.set(customDirectoryURLText, forKey: ACMEConfig.customDirectoryURLKey)
        serverMgr.reloadACMEMirrors()
    }

    private func applyAccountEmail() {
        let trimmed = accountEmailText.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed, forKey: ACMEConfig.accountEmailKey)
        serverMgr.reloadACMEMirrors()
    }

    private func applyDomains() {
        UserDefaults.standard.set(domainsText, forKey: ACMEConfig.domainsKey)
        serverMgr.reloadACMEMirrors()
    }

    private func applyCustomResolverHost() {
        UserDefaults.standard.set(customResolverHostText, forKey: ACMEConfig.customResolverHostKey)
        serverMgr.reloadACMEMirrors()
    }

    private func applyCustomDoHURL() {
        UserDefaults.standard.set(customDoHURLText, forKey: ACMEConfig.customDoHURLKey)
        serverMgr.reloadACMEMirrors()
    }

    private func commitRenewDays() {
        // Accept any positive integer the user types; reject empty / non-numeric
        // input by snapping back to the previously stored value.
        guard let value = Int(renewDaysText.trimmingCharacters(in: .whitespaces)),
              value > 0 else {
            renewDaysText = String(serverMgr.acmeRenewWhenDaysRemain)
            return
        }
        UserDefaults.standard.set(value, forKey: ACMEConfig.renewWhenDaysRemainKey)
        serverMgr.reloadACMEMirrors()
    }

    private func commitDNSTimeout() {
        guard let value = Int(dnsTimeoutText.trimmingCharacters(in: .whitespaces)),
              value > 0 else {
            dnsTimeoutText = String(serverMgr.acmeDNSTimeoutSeconds)
            return
        }
        UserDefaults.standard.set(value, forKey: ACMEConfig.dnsValidationTimeoutKey)
        serverMgr.reloadACMEMirrors()
    }

    private func commitDNSPoll() {
        guard let value = Int(dnsPollText.trimmingCharacters(in: .whitespaces)),
              value > 0 else {
            dnsPollText = String(serverMgr.acmeDNSPollSeconds)
            return
        }
        UserDefaults.standard.set(value, forKey: ACMEConfig.dnsPropagationPollKey)
        serverMgr.reloadACMEMirrors()
    }

    private func applyCloudflareToken() {
        let trimmed = cloudflareTokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            KeychainCloudflareToken.save(trimmed)
            cloudflareTokenSaved = true
        }
    }

    // MARK: - Async actions

    private func registerAccount() async {
        registering = true
        defer { registering = false }
        do {
            _ = try await serverMgr.acmeCoordinator.registerAccount()
            serverMgr.reloadACMEMirrors()
        } catch {
            serverMgr.acmeLastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func forgetAccount() {
        ACMEAccountImporter.forgetAccount(for: serverMgr.acmeCA)
        UserDefaults.standard.set(false, forKey: ACMEConfig.accountRegisteredKey)
        UserDefaults.standard.removeObject(forKey: "acmeAccountURL")
        serverMgr.reloadACMEMirrors()
    }

    private func requestCertificate() async {
        requesting = true
        defer { requesting = false }
        do {
            _ = try await serverMgr.acmeCoordinator.requestCertificate()
            serverMgr.reloadACMEMirrors()
        } catch {
            // Error already flowed through the status stream.
        }
    }

    private func refreshProfiles() async {
        do {
            let profiles = try await serverMgr.acmeCoordinator.fetchAvailableProfiles()
            serverMgr.acmeAvailableProfiles = profiles
        } catch {
            serverMgr.acmeLastError = "Profile fetch failed: \(error.localizedDescription)"
        }
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.title = "Select ACME account private key (PEM)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let allowed = ["pem", "key"].compactMap { UTType(filenameExtension: $0) }
        if !allowed.isEmpty { panel.allowedContentTypes = allowed }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ACMEAccountImporter.importFromFile(keyURL: url, accountURL: importAccountURL, for: serverMgr.acmeCA)
            UserDefaults.standard.set(true, forKey: ACMEConfig.accountRegisteredKey)
            UserDefaults.standard.set(importAccountURL, forKey: "acmeAccountURL")
            serverMgr.reloadACMEMirrors()
            showImportPanel = false
            importKeyPEM = ""
            importAccountURL = ""
            importError = nil
        } catch {
            importError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func importAccount() {
        do {
            try ACMEAccountImporter.importAccount(keyPEM: importKeyPEM, accountURL: importAccountURL, for: serverMgr.acmeCA)
            UserDefaults.standard.set(true, forKey: ACMEConfig.accountRegisteredKey)
            UserDefaults.standard.set(importAccountURL, forKey: "acmeAccountURL")
            serverMgr.reloadACMEMirrors()
            showImportPanel = false
            importKeyPEM = ""
            importAccountURL = ""
            importError = nil
        } catch {
            importError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// Re-declare a tiny banner so this file doesn't have to reach into the
// `private` banner inside SettingsView.swift. Same visual style.
private struct SettingsWarningBanner: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout).bold()
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.yellow.opacity(0.15)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.yellow.opacity(0.6), lineWidth: 1))
    }
}
