import Foundation
import AVFoundation

@MainActor
final class TTSEngine: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private let resampler = AudioResampler()

    /// Sentinel voice identifier that routes TTS through the `say` CLI instead
    /// of AVSpeechSynthesizer. Selecting it makes /tts behave like /say.
    static let siriVoiceIdentifier = "Siri"

    func listVoices() -> [VoiceInfo] {
        var voices = AVSpeechSynthesisVoice.speechVoices().map { v in
            VoiceInfo(name: v.name, identifier: v.identifier, language: v.language, quality: v.quality.rawValue)
        }
        let siri = VoiceInfo(
            name: "Siri",
            identifier: Self.siriVoiceIdentifier,
            language: "system",
            quality: AVSpeechSynthesisVoiceQuality.enhanced.rawValue
        )
        voices.insert(siri, at: 0)
        return voices
    }

    func speakLocal(_ text: String, voiceId: String?, rate: Double?, pitch: Double?) {
        if voiceId == Self.siriVoiceIdentifier {
            // Route through `say` CLI to match /say's exact behavior. Fire-and-forget,
            // mirroring AVSpeechSynthesizer.speak(_:).
            Task { [weak self] in
                try? await self?.speakWithSay(text)
            }
            return
        }
        let u = makeUtterance(text: text, voiceId: voiceId, rate: rate, pitch: pitch)
        synth.speak(u)
    }

    func speakWithSay(_ text: String) async throws {
        try await runSay(text: text, outputURL: nil)
    }

    func synthesizeWithSayToWAV(_ text: String) async throws -> Data {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        defer {
            try? FileManager.default.removeItem(at: outputURL)
        }

        try await runSay(text: text, outputURL: outputURL)
        do {
            return try Data(contentsOf: outputURL)
        } catch {
            throw AudioError.io("Unable to read synthesized WAV file")
        }
    }

    func synthesizeWithSayToFile(_ text: String, outputURL: URL) async throws {
        try await runSay(text: text, outputURL: outputURL)
    }

    /// Note about better voices:
    /// macOS -> System Settings -> Accessibility -> Spoken Content -> "Voices".
    /// Download an "Enhanced" voice for the desired language (for example, German).
    /// AVSpeechSynthesizer cannot use Siri voices directly, but enhanced voices are much higher quality.
    private func makeUtterance(text: String, voiceId: String?, rate: Double?, pitch: Double?) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)

        // Choose voice: explicit, non-empty identifier wins
        if let id = voiceId, !id.isEmpty, let v = AVSpeechSynthesisVoice(identifier: id) {
            u.voice = v
        } else {
            // 2) Preferred: Anna (en-US), highest quality
            let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-US" }
            if let annaBest = candidates
                .filter({ $0.name == "Anna" })
                .sorted(by: { $0.quality.rawValue > $1.quality.rawValue })
                .first
            {
                u.voice = annaBest
            } else if let bestDE = candidates.sorted(by: { $0.quality.rawValue > $1.quality.rawValue }).first {
                // 3) Fallback: best German voice
                u.voice = bestDE
            }
        }

        // Useful optional setting:
        u.prefersAssistiveTechnologySettings = true

        // Rate: map 0.5..2.0 around default for natural prosody
        if let r = rate {
            let clamped = max(0.5, min(2.0, r))
            u.rate = Float(clamped) * AVSpeechUtteranceDefaultSpeechRate
        } else {
            u.rate = AVSpeechUtteranceDefaultSpeechRate
        }

        // Pitch: -1..1 → 0.5..2.0
        if let p = pitch {
            let mapped = max(0.0, min(2.0, 1.0 + p))
            u.pitchMultiplier = Float(mapped)
        }

        return u
    }

    /// Synthesize → 16kHz mono PCM16 WAV
    func synthesizeToWAV(text: String, voiceId: String?, rate: Double?, pitch: Double?) async throws -> Data {
        if voiceId == Self.siriVoiceIdentifier {
            // The "Siri" voice routes through the `say` CLI, producing the same
            // WAV output that /say returns.
            return try await synthesizeWithSayToWAV(text)
        }
        let utterance = makeUtterance(text: text, voiceId: voiceId, rate: rate, pitch: pitch)
        var collected: [AVAudioPCMBuffer] = []
        var fmt: AVAudioFormat?

        var nullableContinuation: CheckedContinuation<Data, Error>?
        let wav: Data = try await withCheckedThrowingContinuation { cont in
            nullableContinuation = cont
            self.synth.write(utterance) { buffer in
                // Only proceed if the continuation hasn't been resumed yet.
                guard nullableContinuation != nil else { return }

                guard let pcm = buffer as? AVAudioPCMBuffer else {
                    // Non-PCM buffer might indicate an issue, but we wait for the final zero-length buffer.
                    return
                }

                if pcm.frameLength > 0 {
                    collected.append(pcm)
                    if fmt == nil { fmt = pcm.format }
                    return // Still collecting data
                }

                // Final callback (frameLength == 0). This is where we process and resume.
                do {
                    guard let f = fmt, !collected.isEmpty else {
                        throw AudioError.io("TTS produced no audio data")
                    }
                    let total = collected.reduce(0) { $0 + Int($1.frameLength) }
                    guard let stitched = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(total)) else {
                        throw AudioError.conversionFailed("alloc")
                    }
                    stitched.frameLength = AVAudioFrameCount(total)
                    var cursor = 0
                    for b in collected {
                        let n = Int(b.frameLength)
                        if f.commonFormat == .pcmFormatFloat32 {
                            stitched.floatChannelData![0].advanced(by: cursor).update(from: b.floatChannelData![0], count: n)
                        } else if f.commonFormat == .pcmFormatInt16 {
                            stitched.int16ChannelData![0].advanced(by: cursor).update(from: b.int16ChannelData![0], count: n)
                        }
                        cursor += n
                    }
                    let dstFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
                    let mono = try self.resampler.convert(stitched, to: dstFmt)
                    let data = try self.resampler.wavData(from: mono, sampleRate: 16000)
                    
                    nullableContinuation?.resume(returning: data)
                    nullableContinuation = nil
                } catch {
                    nullableContinuation?.resume(throwing: error)
                    nullableContinuation = nil
                }
            }
        }
        return wav
    }

    /// Caps how many `say` subprocesses can be in flight at once across the
    /// whole app. Prevents a flood of requests from spawning unbounded children.
    private static let sayLimiter = SayConcurrencyLimiter(maxConcurrent: 4)

    private func runSay(text: String, outputURL: URL?) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.badRequest("Text is required")
        }

        await Self.sayLimiter.acquire()
        do {
            try await launchSayProcess(text: text, outputURL: outputURL)
            await Self.sayLimiter.release()
        } catch {
            await Self.sayLimiter.release()
            throw error
        }
    }

    private func launchSayProcess(text: String, outputURL: URL?) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")

        var arguments: [String] = []
        if let outputURL {
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            arguments += [
                "-o", outputURL.path,
                "--file-format=WAVE",
                "--data-format=LEI16@44100"
            ]
        }
        // End-of-options terminator: every argv after `--` is treated as a
        // positional argument, so a caller-supplied `text` that begins with `-`
        // or `--foo=bar` cannot be parsed as a `say` option.
        arguments.append("--")
        arguments.append(text)
        process.arguments = arguments

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { process in
                let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: ())
                    return
                }

                let errorMessage = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(throwing: AudioError.io(errorMessage?.isEmpty == false ? errorMessage! : "say command failed"))
            }

            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: AudioError.io("Failed to launch say"))
            }
        }
    }

}

/// Counting semaphore (actor-isolated) limiting how many `say` subprocesses can
/// run concurrently. `acquire()` suspends until a slot is free; `release()`
/// hands the slot to the next waiter, or just frees it.
actor SayConcurrencyLimiter {
    private let maxConcurrent: Int
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
    }

    func acquire() async {
        if inFlight < maxConcurrent {
            inFlight += 1
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
        // Resumed by release(): the slot was handed to us, so inFlight is
        // already accounted for and must not be incremented again.
    }

    func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            inFlight -= 1
        }
    }
}
