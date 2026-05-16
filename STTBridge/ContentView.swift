import SwiftUI
import AVFoundation
import Speech
import Combine
import UniformTypeIdentifiers

struct SayAudioDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.wav] }
    static var writableContentTypes: [UTType] { [.wav] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - ViewModel
@MainActor
class AppViewModel: ObservableObject {
    // TTS Properties
    @Published var ttsText: String = "Hello World! This is a local TTS demo."
    @Published var voices: [VoiceInfo] = []
    @Published var selectedVoiceIdentifier: String? = nil
    @Published var sayText: String = "Hello World! This is a macOS say demo."
    @Published var sayOutputToFile: Bool = false
    @Published var sayStatus: String = ""
    @Published var isRunningSay: Bool = false
    @Published var isShowingSayExporter: Bool = false
    @Published var sayExportDocument: SayAudioDocument?
    @Published var sayDefaultFilename: String = "speech-output"

    // STT Properties
    @Published var sttText: String = ""
    @Published var isRecording: Bool = false

    private let ttsEngine = TTSEngine()
    private var sttSession: STTStreamSession?
    private var audioEngine: AVAudioEngine?

    init() {
        loadVoices()
    }

    // MARK: - TTS Methods
    func loadVoices() {
        self.voices = ttsEngine.listVoices().sorted(by: { $0.name < $1.name })
        
        var annaVoice: VoiceInfo? = nil
        for voice in self.voices {
            if voice.name == "Anna" && voice.quality > 1 {
                annaVoice = voice
                break
            }
        }

        if let anna = annaVoice {
            self.selectedVoiceIdentifier = anna.identifier
            return
        }

        var germanVoice: VoiceInfo? = nil
        for voice in self.voices {
            if voice.language == "de-DE" {
                germanVoice = voice
                break
            }
        }

        if let defaultGerman = germanVoice {
            self.selectedVoiceIdentifier = defaultGerman.identifier
        }
    }

    func speak() {
        ttsEngine.speakLocal(ttsText, voiceId: selectedVoiceIdentifier, rate: nil, pitch: nil)
    }

    func runSay() {
        let text = sayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            sayStatus = "Enter text to speak."
            return
        }

        isRunningSay = true
        sayStatus = sayOutputToFile ? "Generating WAV file..." : "Speaking through system audio..."

        Task {
            do {
                if sayOutputToFile {
                    let data = try await ttsEngine.synthesizeWithSayToWAV(text)
                    sayExportDocument = SayAudioDocument(data: data)
                    sayDefaultFilename = defaultSayFilename(for: text)
                    sayStatus = "Choose where to save the WAV file."
                    isShowingSayExporter = true
                } else {
                    try await ttsEngine.speakWithSay(text)
                    sayStatus = "Playback finished."
                    isRunningSay = false
                }
            } catch {
                sayStatus = "say failed: \(error.localizedDescription)"
                isRunningSay = false
            }
        }
    }

    func handleSayExport(result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            sayStatus = "Saved \(url.lastPathComponent)."
        case .failure(let error):
            sayStatus = "Save failed: \(error.localizedDescription)"
        }
        sayExportDocument = nil
        isRunningSay = false
    }

    func cancelSayExport() {
        sayStatus = "Save cancelled."
        sayExportDocument = nil
        isRunningSay = false
    }

    private func defaultSayFilename(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = String(trimmed.prefix(24))
        let sanitized = prefix
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return sanitized.isEmpty ? "speech-output" : sanitized.lowercased()
    }

    // MARK: - STT Methods
    func toggleRecording() {
        if isRecording {
            stopSTT()
        } else {
            startSTT()
        }
    }

    private func startSTT() {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                guard authStatus == .authorized else {
                    self.sttText = "Error: Speech recognition permission is missing."
                    return
                }
                // Mic permission is handled by the system automatically on first access on macOS
                self.isRecording = true
                self.sttText = "Listening..."
                self.setupAndStartSTT()
            }
        }
    }

    private func setupAndStartSTT() {
        do {
            sttSession = try STTStreamSession(lang: "en-US", requiresOnDevice: true)
            sttSession?.onPartial = { [weak self] text in self?.sttText = text }
            sttSession?.onFinal = { [weak self] text, _ in self?.sttText = text }
            sttSession?.onError = { [weak self] error in
                self?.sttText = "STT error: \(error.localizedDescription)"
                self?.stopSTT()
            }

            audioEngine = AVAudioEngine()
            let inputNode = audioEngine!.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
            let converter = AVAudioConverter(from: recordingFormat, to: targetFormat)!

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] (buffer, _) in
                let pcmBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096)!
                var error: NSError? = nil
                let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                converter.convert(to: pcmBuffer, error: &error, withInputFrom: inputBlock)

                if error != nil { return }
                
                let channelData = pcmBuffer.int16ChannelData![0]
                let channelDataSize = Int(pcmBuffer.frameLength) * Int(pcmBuffer.format.streamDescription.pointee.mBytesPerFrame)
                let data = Data(bytes: channelData, count: channelDataSize)
                try? self?.sttSession?.append(data)
            }

            audioEngine?.prepare()
            try audioEngine?.start()

        } catch {
            sttText = "Error starting STT: \(error.localizedDescription)"
            isRecording = false
        }
    }

    private func stopSTT() {
        isRecording = false
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        sttSession?.stop()
        sttSession = nil
    }
}

// MARK: - ContentView
struct ContentView: View {
    let status: String // From ServerManager
    @StateObject private var viewModel = AppViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                statusHeader
                sttSection
                ttsSection
                saySection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 620, idealWidth: 620, maxWidth: 620, minHeight: 400, idealHeight: 650, maxHeight: 650)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Open Settings")
            }
        }
        .fileExporter(
            isPresented: $viewModel.isShowingSayExporter,
            document: viewModel.sayExportDocument,
            contentTypes: [.wav],
            defaultFilename: viewModel.sayDefaultFilename,
            onCompletion: viewModel.handleSayExport,
            onCancellation: viewModel.cancelSayExport
        )
    }

    // MARK: Status header

    @ViewBuilder
    private var statusHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .font(.title)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 2) {
                Text("STTBridge")
                    .font(.title2).bold()
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            Spacer()
            Image(systemName: "waveform.and.person.filled")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
                .padding(.trailing, 8)
        }
        .padding(.top,-8)
    }

    private var statusIcon: String {
        let s = status.lowercased()
        if s.contains("error") || s.contains("failed") { return "exclamationmark.triangle.fill" }
        if s.contains("running") { return "checkmark.circle.fill" }
        return "circle.dotted"
    }

    private var statusColor: Color {
        let s = status.lowercased()
        if s.contains("error") || s.contains("failed") { return .red }
        if s.contains("running") { return .green }
        return .orange
    }

    // MARK: Speech-to-Text

    @ViewBuilder
    private var sttSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(viewModel.sttText.isEmpty ? "Press Start Recording to begin." : viewModel.sttText)
                    .foregroundStyle(viewModel.sttText.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
                    .padding(8)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                    .textSelection(.enabled)

                HStack {
                    Button(viewModel.isRecording ? "Stop Recording" : "Start Recording") {
                        viewModel.toggleRecording()
                    }
                    .controlSize(.large)
                    .tint(viewModel.isRecording ? .red : nil)
                    Spacer()
                }
            }
            .padding(.top, 4)
        } label: {
            Label("Speech-to-Text", systemImage: "waveform.and.mic")
                .font(.headline)
        }
    }

    // MARK: Text-to-Speech (AVSpeechSynthesizer)

    @ViewBuilder
    private var ttsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $viewModel.ttsText)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 80)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))

                Picker("Voice:", selection: $viewModel.selectedVoiceIdentifier) {
                    ForEach(viewModel.voices, id: \.identifier) { voice in
                        Text("\(voice.name) (\(voice.language))").tag(voice.identifier as String?)
                    }
                }
                .pickerStyle(.menu)

                HStack {
                    Button("Speak", action: viewModel.speak)
                        .controlSize(.large)
                    Spacer()
                }
            }
            .padding(.top, 4)
        } label: {
            Label("Text-to-Speech", systemImage: "text.bubble.fill")
                .font(.headline)
        }
    }

    // MARK: macOS say

    @ViewBuilder
    private var saySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $viewModel.sayText)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 80)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))

                Toggle("Output to WAV file", isOn: $viewModel.sayOutputToFile)

                HStack {
                    Button(viewModel.sayOutputToFile ? "Save WAV File" : "Run say") {
                        viewModel.runSay()
                    }
                    .controlSize(.large)
                    .disabled(viewModel.isRunningSay)

                    if !viewModel.sayStatus.isEmpty {
                        Text(viewModel.sayStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .padding(.top, 4)
        } label: {
            Label("macOS say", systemImage: "siri")
                .font(.headline)
        }
    }
}
