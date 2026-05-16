import SwiftUI
import Speech
import Combine

@main
struct STTBridgeApp: App {
    @StateObject private var serverMgr: ServerManager

    init() {
        // One-shot CLI cert imports run before anything else and exit the
        // process when done, so scripted certificate rotation never spins up
        // the HTTP server or any UI.
        if CLICertImporter.shouldHandle() {
            CLICertImporter.executeAndExit()
        }
        _serverMgr = StateObject(wrappedValue: ServerManager())
    }

    // Check if running headless (backend-only)
    private var isHeadless: Bool {
        CommandLine.arguments.contains("--headless") ||
        CommandLine.arguments.contains("--no-ui")
    }

    var body: some Scene {
        WindowGroup {
            if isHeadless {
                // Minimal view for headless mode
                Text("STT/TTS Bridge Server")
                    .frame(width: 0, height: 0)
                    .hidden()
            } else {
                ContentView(status: serverMgr.status)
                    .environmentObject(serverMgr)
                    .navigationTitle("STTBridge")
            }
        }
        .defaultSize(width: isHeadless ? 0 : 620, height: isHeadless ? 0 : 720)
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified)
        .commands {
            // Replace the stock "About STTBridge" menu item with our custom
            // panel — the standard NSAboutPanel can't host an interactive
            // Acknowledgements button, so we own the whole panel.
            CommandGroup(replacing: .appInfo) {
                AboutMenuButton()
            }
        }

        // Standalone scenes the menu and the Acknowledgements button open.
        Window("About STTBridge", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        Window("Acknowledgements", id: "acknowledgements") {
            LicenseView()
        }

        Settings {
            ServerSettingsView()
                .environmentObject(serverMgr)
        }
    }
}

/// View that lives inside the .appInfo command group. Needs to be its own
/// View struct so it can pull the `openWindow` action out of the environment.
private struct AboutMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About STTBridge") {
            openWindow(id: "about")
        }
    }
}

@MainActor
final class ServerManager: ObservableObject {
    @Published var status: String = "Starting..."
    @Published var bindHosts: [String]
    @Published var port: Int
    @Published var authToken: String
    @Published var defaultLang: String
    @Published var offlineOnly: Bool
    @Published var tlsEnabled: Bool
    @Published var tlsCertFormat: TLSCertificateFormat
    @Published var tlsMinVersion: TLSVersionPref
    @Published var tlsMaxVersion: TLSVersionPref
    @Published var tlsCustomCiphers: [String]?
    @Published var tlsCurves: [String]?
    @Published var httpRedirectPort: Int

    private var server: HTTPServer?
    private let serverQueue = DispatchQueue(label: "sttbridge.server", qos: .userInitiated)

    init() {
        // In headless mode print() is block-buffered (stdout is a pipe/file),
        // so server errors wouldn't surface until the buffer fills. Force
        // unbuffered stdout so diagnostic output is visible immediately.
        if CommandLine.arguments.contains("--headless") || CommandLine.arguments.contains("--no-ui") {
            setbuf(stdout, nil)
        }
        let cfg = Config()
        self.bindHosts = cfg.bindHosts
        self.port = cfg.port
        self.authToken = cfg.authToken ?? ""
        self.defaultLang = cfg.defaultLang
        self.offlineOnly = cfg.offlineOnly
        self.tlsEnabled = cfg.tlsEnabled
        self.tlsCertFormat = cfg.tlsCertFormat
        self.tlsMinVersion = cfg.tlsMinVersion
        self.tlsMaxVersion = cfg.tlsMaxVersion
        self.tlsCustomCiphers = cfg.tlsCustomCiphers
        self.tlsCurves = cfg.tlsCurves
        self.httpRedirectPort = cfg.httpRedirectPort

        SFSpeechRecognizer.requestAuthorization { st in
            print("Speech auth: \(st)")
        }
        startServer(config: cfg)
    }

    /// Re-reads Config from UserDefaults/env and restarts the server. The serial
    /// `serverQueue` guarantees the new server starts only after the previous one
    /// has unblocked from `start()`.
    func reload() {
        let cfg = Config()
        status = "Restarting on \(Self.urlList(hosts: cfg.bindHosts, port: cfg.port, tls: cfg.tlsEnabled))…"
        server?.stop()
        startServer(config: cfg)
    }

    private func startServer(config: Config) {
        let isHeadless = CommandLine.arguments.contains("--headless") ||
                         CommandLine.arguments.contains("--no-ui")
        serverQueue.async { [weak self] in
            guard let self else { return }
            let srv = HTTPServer(config: config)
            Task { @MainActor in
                self.server = srv
                self.bindHosts = config.bindHosts
                self.port = config.port
                self.authToken = config.authToken ?? ""
                self.defaultLang = config.defaultLang
                self.offlineOnly = config.offlineOnly
                self.tlsEnabled = config.tlsEnabled
                self.tlsCertFormat = config.tlsCertFormat
                self.tlsMinVersion = config.tlsMinVersion
                self.tlsMaxVersion = config.tlsMaxVersion
                self.tlsCustomCiphers = config.tlsCustomCiphers
                self.tlsCurves = config.tlsCurves
                self.httpRedirectPort = config.httpRedirectPort
                self.status = "Server running at \(Self.urlList(hosts: config.bindHosts, port: config.port, tls: config.tlsEnabled))"
            }
            do {
                if isHeadless {
                    print("✓ Server running at \(Self.urlList(hosts: config.bindHosts, port: config.port, tls: config.tlsEnabled))")
                    print("✓ Press Ctrl+C to quit")
                }
                try srv.start()
            } catch {
                let errMsg = "Server error: \(error)"
                Task { @MainActor in self.status = errMsg }
                print("✗ \(errMsg)")
            }
        }
    }

    nonisolated private static func urlList(hosts: [String], port: Int, tls: Bool) -> String {
        let scheme = tls ? "https" : "http"
        return hosts.map { "\(scheme)://\($0):\(port)" }.joined(separator: ", ")
    }
}
