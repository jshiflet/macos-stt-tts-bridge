import Foundation
import Speech
import AVFoundation

final class STTEngine {
    private let cfg: Config
    private let resampler = AudioResampler()
    private var cachedRecognizers: [String: SFSpeechRecognizer] = [:]
    private let recognizerQueue = DispatchQueue(label: "com.sttbridge.recognizerCache")

    init(config: Config) {
        self.cfg = config
        // Prewarm recognizers for default languages
        Task.detached { [weak self] in
            guard let self = self else { return }
            await self.prewarmRecognizers()
        }
    }
    
    private func prewarmRecognizers() async {
        // Prewarm common languages to avoid first-request delay
        let langs = [cfg.defaultLang, "de-DE", "en-US"]
        for lang in langs {
            _ = getRecognizer(for: lang)
        }
    }
    
    private func getRecognizer(for lang: String) -> SFSpeechRecognizer? {
        return recognizerQueue.sync {
            if let cached = cachedRecognizers[lang] {
                return cached
            }
            if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: lang)) {
                cachedRecognizers[lang] = recognizer
                return recognizer
            }
            return nil
        }
    }

    func onDeviceSupported(lang: String) -> Bool {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: lang)) else { return false }
        return r.supportsOnDeviceRecognition
    }

    func languages() -> [String] {
        SFSpeechRecognizer.supportedLocales().map { $0.identifier }.sorted()
    }

    func transcribeFile(url: URL, lang: String, offline: Bool?) async throws -> STTResponse {
        guard let rec = getRecognizer(for: lang) else { throw APIError.badRequest("Unsupported language \(lang)") }
        let req = SFSpeechURLRecognitionRequest(url: url)
        if cfg.offlineOnly || (offline ?? false) {
            if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
            else { throw APIError.preconditionFailed("offline=true requested, on-device recognition for \(lang) is not available.") }
        }
        return try await recognize(recognizer: rec, request: req)
    }

    func transcribeRaw(data: Data, sampleRate: Double?, channels: Int?, lang: String, offline: Bool?) async throws -> STTResponse {
        // Fast path: If we have metadata headers, process in-memory without file I/O
        if let sr = sampleRate, let ch = channels {
            let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sr, channels: AVAudioChannelCount(ch), interleaved: true)!
            let frames = AVAudioFrameCount(data.count / ch / 2)
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { throw APIError.internalError("alloc") }
            buf.frameLength = frames
            data.withUnsafeBytes { ptr in if let base = ptr.baseAddress { memcpy(buf.int16ChannelData![0], base, data.count) } }
            
            // Convert to 16kHz mono if needed
            let targetFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
            let processedBuf = (sr == 16000 && ch == 1) ? buf : try resampler.convert(buf, to: targetFmt)
            
            // Recognize directly from buffer without file I/O
            return try await recognizeBuffer(buffer: processedBuf, lang: lang, offline: offline)
        } else {
            // Fallback: Write to temp file for WAV parsing
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stt-\(UUID().uuidString).wav")
            try data.write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            return try await transcribeFile(url: tmp, lang: lang, offline: offline)
        }
    }
    
    private func recognizeBuffer(buffer: AVAudioPCMBuffer, lang: String, offline: Bool?) async throws -> STTResponse {
        guard let rec = getRecognizer(for: lang) else { throw APIError.badRequest("Unsupported language \(lang)") }
        let req = SFSpeechAudioBufferRecognitionRequest()
        if cfg.offlineOnly || (offline ?? false) {
            if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
            else { throw APIError.preconditionFailed("offline=true requested, on-device recognition for \(lang) is not available.") }
        }
        req.append(buffer)
        req.endAudio()
        return try await recognize(recognizer: rec, request: req)
    }

    private func recognize(recognizer: SFSpeechRecognizer, request: SFSpeechRecognitionRequest) async throws -> STTResponse {
        try await withCheckedThrowingContinuation { cont in
            recognizer.recognitionTask(with: request) { result, error in
                if let e = error { cont.resume(throwing: APIError.internalError("STT error: \(e.localizedDescription)")); return }
                guard let r = result else { return }
                if r.isFinal {
                    let best = r.bestTranscription
                    let words = best.segments.map { STTWord(token: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration) }
                    let segs = r.transcriptions.first?.segments ?? []
                    let sum = segs.reduce(0.0) { $0 + Double($1.confidence) }
                    let conf = segs.isEmpty ? nil : sum / Double(segs.count)
                    cont.resume(returning: STTResponse(text: best.formattedString, isFinal: true, confidence: conf, words: words))
                }
            }
        }
    }
}

// Live WS stream
final class STTStreamSession {
    private let recognizer: SFSpeechRecognizer
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var startedAt = Date()
    private let maxSeconds: TimeInterval = 50

    var onPartial: ((String)->Void)?
    var onFinal: ((String, Double?)->Void)?
    var onError: ((Error)->Void)?

    init(lang: String, requiresOnDevice: Bool) throws {
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: lang)) else { throw APIError.badRequest("Unsupported language \(lang)") }
        recognizer = rec
        try startNewTask(onDevice: requiresOnDevice)
    }

    private func startNewTask(onDevice: Bool) throws {
        stop()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if onDevice {
            if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
            else { throw APIError.preconditionFailed("offline=true requested, on-device recognition is not available.") }
        }
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }
            if let e = error { self.onError?(e); return }
            guard let r = result else { return }
            let text = r.bestTranscription.formattedString
            if r.isFinal {
                let segs = r.transcriptions.first?.segments ?? []
                let sum = segs.reduce(0.0) { $0 + Double($1.confidence) }
                let conf = segs.isEmpty ? nil : sum / Double(segs.count)
                self.onFinal?(text, conf)
            } else {
                self.onPartial?(text)
            }
        }
        startedAt = Date()
    }

    func append(_ data: Data) throws {
        if Date().timeIntervalSince(startedAt) > maxSeconds {
            try startNewTask(onDevice: request?.requiresOnDeviceRecognition ?? false)
        }
        guard let req = request else { return }
        let frames = data.count / 2
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in if let base = raw.baseAddress { memcpy(buf.int16ChannelData![0], base, data.count) } }
        req.append(buf)
    }

    func stop() {
        request?.endAudio()
        task?.cancel()
        task = nil; request = nil
    }
}
