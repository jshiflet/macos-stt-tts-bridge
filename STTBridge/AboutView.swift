import SwiftUI
import AppKit

// MARK: - About panel

/// Replaces the stock "About STTBridge" panel. Mirrors macOS conventions
/// (app icon, name, version, copyright) and adds an `Acknowledgements…`
/// button that opens a second window with the full MIT license text — the
/// license itself requires inclusion in distributions of the Software, so
/// it ships inside the app bundle and is available from the menu bar.
struct AboutView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            iconImage
                .frame(width: 128, height: 128)
                .shadow(radius: 8)

            VStack(alignment: .leading, spacing: 0) {
                Text("STTBridge")
                    .font(.system(size: 38))

                Text("Version \(appVersion) (\(buildNumber))")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                    .textSelection(.enabled)

                Spacer().frame(height: 22)

                if !copyright.isEmpty {
                    Text(copyright)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 16)

                HStack {
                    Spacer()
                    Button("Acknowledgements") {
                        openWindow(id: "acknowledgements")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(28)
        .frame(width: 580, height: 240)
    }

    // MARK: - Bundle info

    @ViewBuilder
    private var iconImage: some View {
        if let nsImage = NSApp.applicationIconImage {
            Image(nsImage: nsImage).resizable()
        } else {
            // Fallback if -applicationIconImage returns nil (e.g. headless mode).
            Image(systemName: "waveform")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
        }
    }

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }

    private var buildNumber: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1"
    }

    private var copyright: String {
        (Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String) ?? ""
    }
}

// MARK: - License window

/// Displays the bundled MIT license text in a scrollable, monospace view.
/// The text is selectable so a user can copy it.
struct LicenseView: View {
    var body: some View {
        ScrollView {
            Text(licenseText)
                //.font(.system(.body, design: .monospaced))
                .font(.system(.body))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(15)
        }
        .frame(minWidth: 620, idealWidth: 620, maxWidth: 620, minHeight: 385, idealHeight: 385, maxHeight: 385)
    }

    /// Loads `LICENSE.txt` from the app bundle. The file is added to the
    /// project's synchronized root group so it's automatically copied into
    /// Resources at build time.
    private var licenseText: String {
        if let url = Bundle.main.url(forResource: "LICENSE", withExtension: "txt"),
           let txt = try? String(contentsOf: url, encoding: .utf8) {
            return txt
        }
        return "LICENSE.txt was not found in the application bundle."
    }
}
