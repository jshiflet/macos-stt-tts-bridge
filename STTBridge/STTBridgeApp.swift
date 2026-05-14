import SwiftUI
import Speech
import Combine

@main
struct STTBridgeApp: App {
    @StateObject private var serverMgr = ServerManager()

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
            }
        }
        .defaultSize(width: isHeadless ? 0 : 800, height: isHeadless ? 0 : 600)

        Settings {
            ServerSettingsView()
                .environmentObject(serverMgr)
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

    private var server: HTTPServer?
    private let serverQueue = DispatchQueue(label: "sttbridge.server", qos: .userInitiated)

    init() {
        let cfg = Config()
        self.bindHosts = cfg.bindHosts
        self.port = cfg.port
        self.authToken = cfg.authToken ?? ""
        self.defaultLang = cfg.defaultLang
        self.offlineOnly = cfg.offlineOnly

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
        status = "Restarting on \(Self.urlList(hosts: cfg.bindHosts, port: cfg.port))…"
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
                self.status = "Server running at \(Self.urlList(hosts: config.bindHosts, port: config.port))"
            }
            do {
                if isHeadless {
                    print("✓ Server running at \(Self.urlList(hosts: config.bindHosts, port: config.port))")
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

    nonisolated private static func urlList(hosts: [String], port: Int) -> String {
        hosts.map { "http://\($0):\(port)" }.joined(separator: ", ")
    }
}
