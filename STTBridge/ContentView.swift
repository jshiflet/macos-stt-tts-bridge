import SwiftUI
import AVFoundation
import Speech
import Combine
import UniformTypeIdentifiers

struct SayAudioDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.mpeg4Audio] }
    static var writableContentTypes: [UTType] { [.mpeg4Audio] }

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
    @Published var ttsText: String = "Hello Stuttgart! This is a local TTS demo."
    @Published var voices: [VoiceInfo] = []
    @Published var selectedVoiceIdentifier: String? = nil
    @Published var sayText: String = "Hello Stuttgart! This is a macOS say demo."
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
        sayStatus = sayOutputToFile ? "Generating m4a file..." : "Speaking through system audio..."

        Task {
            do {
                if sayOutputToFile {
                    let data = try await ttsEngine.synthesizeWithSayToM4A(text)
                    sayExportDocument = SayAudioDocument(data: data)
                    sayDefaultFilename = defaultSayFilename(for: text)
                    sayStatus = "Choose where to save the m4a file."
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
            sttSession = try STTStreamSession(lang: "de-DE", requiresOnDevice: true)
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
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading) {
                Text("STTBridge Server").font(.title).bold()
                Text(status).font(.body).textSelection(.enabled)
            }

            Divider()

            Text("Speech-to-Text (STT)").font(.title2)
            Text(viewModel.sttText)
                .frame(minHeight: 70, alignment: .topLeading)
                .padding(5)
                .border(Color.gray.opacity(0.5), width: 1)
            Button(viewModel.isRecording ? "Stop Recording" : "Start Recording", action: viewModel.toggleRecording)
                .tint(viewModel.isRecording ? .red : .accentColor)

            Divider()

            Text("Text-to-Speech (TTS)").font(.title2)
            TextEditor(text: $viewModel.ttsText)
                .frame(height: 80)
                .border(Color.gray.opacity(0.5), width: 1)
            
            HStack {
                Picker("Voice:", selection: $viewModel.selectedVoiceIdentifier) {
                    ForEach(viewModel.voices, id: \.identifier) { voice in
                        Text("\(voice.name) (\(voice.language))").tag(voice.identifier as String?)
                    }
                }
                .pickerStyle(.menu)
                
                Button("Speak", action: viewModel.speak)
            }

            Divider()

            Text("macOS say Test").font(.title2)
            TextEditor(text: $viewModel.sayText)
                .frame(height: 80)
                .border(Color.gray.opacity(0.5), width: 1)

            Toggle("Output to m4a file", isOn: $viewModel.sayOutputToFile)

            HStack {
                Button(viewModel.sayOutputToFile ? "Save m4a…" : "Run say", action: viewModel.runSay)
                    .disabled(viewModel.isRunningSay)
                if !viewModel.sayStatus.isEmpty {
                    Text(viewModel.sayStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        }
        .padding(20)
        .frame(minWidth: 620, alignment: .leading)
        .fileExporter(
            isPresented: $viewModel.isShowingSayExporter,
            document: viewModel.sayExportDocument,
            contentTypes: [.mpeg4Audio],
            defaultFilename: viewModel.sayDefaultFilename,
            onCompletion: viewModel.handleSayExport,
            onCancellation: viewModel.cancelSayExport
        )
    }
}
