
# STTBridge – MVP (macOS, Swift, Apple-only) – **Complete Guide + Source Code**

**Goal:** A minimal working macOS app (.app bundle) as a **local speech bridge** with
- HTTP (SwiftNIO): `GET /healthz`, `GET /languages`, `GET /voices`, `POST /stt`, `POST /tts`
- WebSocket: `WS /stt/stream` (PCM16‑Chunks → Partials/Finals)
- **Apple frameworks only**: `Speech`, `AVFoundation`
- **Web‑Demo** (statische Seite)

> **Note about this document:**  
> All code blocks use **escaped backticks** (`\`\`\``) so this chat view does **not render** them.  
> In deiner lokalen Datei kannst du einfach die Backslashes **stehen lassen** (Markdown-Renderer akzeptiert das in der Regel) **oder** sie entfernen, wenn du „echte“ Fences willst.

---

## 1) Xcode‑Projekt anlegen

1. Xcode → **File → New → Project…**  
   Template: **App (macOS)**  
   Product Name: **STTBridge** · Interface: **SwiftUI** · Language: **Swift**

2. **Add SwiftNIO**  
   - Projekt (blaues Icon) → Tab **Package Dependencies** → **+**
   - URL: `https://github.com/apple/swift-nio.git` → **Add Package**
   - Pakete dem **App‑Target STTBridge** zuweisen: **NIO**, **NIOHTTP1**, **NIOWebSocket**

3. **Set privacy keys** (Targets → STTBridge → **Info**)  
   - `NSMicrophoneUsageDescription` : "Access to the microphone for local STT."  
   - `NSSpeechRecognitionUsageDescription` : "Speech recognition runs locally on this Mac."

4. **(Empfohlen) App Sandbox** (Targets → **Signing & Capabilities** → **+ Capability** → App Sandbox)  
   - **Network** → **Incoming Connections (Server)**  
   - **Hardware** → **Audio Input (Microphone)**  
   - **Speech Recognition** aktivieren

5. **Static web resources**  
   - Im Finder einen Ordner **WebRoot** anlegen mit `index.html`, `app.js`, `styles.css` (siehe unten).  
   - **In Xcode importieren**: im Navigator auf das Target ziehen →
     choose **Create folder references** (blue folder).

6. **Ohne Debugger laufen lassen** (optional, stabiler)  
   - Product → Scheme → Edit Scheme… → **Run**  
   - **[ ] Debug executable** ausschalten  
   - (Optional) **Build configuration: Release**

---

## 2) Create Files (Swift Source)

Lege in Xcode einen Ordner **Server** an und erstelle dort diese Dateien.

### 2.1 `Config.swift`
\`\`\`swift
import Foundation

struct Config {
    let port: Int
    let bindHost: String
    let authToken: String?
    let defaultLang: String
    let offlineOnly: Bool

    init(env: [String:String] = ProcessInfo.processInfo.environment) {
        port = Int(env["PORT"] ?? "") ?? 8787
        bindHost = env["BIND_HOST"] ?? "127.0.0.1"
        authToken = env["AUTH_TOKEN"]
        defaultLang = env["DEFAULT_LANG"] ?? "de-DE"
        offlineOnly = (env["OFFLINE_ONLY"] ?? "false").lowercased() == "true"
    }
}
\`\`\`

### 2.2 `Models.swift`
\`\`\`swift
import Foundation

struct Healthz: Codable {
    let status: String
    let lang: String
    let onDeviceSTT: Bool
}

struct STTWord: Codable, Sendable {
    let token: String
    let start: Double
    let end: Double
}

struct STTResponse: Codable, Sendable {
    let text: String
    let isFinal: Bool
    let confidence: Double?
    let words: [STTWord]
}

struct TTSPayload: Codable {
    let text: String
    let voiceId: String?
    let rate: Double?
    let pitch: Double?
    let speakLocal: Bool?
}

struct VoiceInfo: Codable {
    let name: String
    let identifier: String
    let language: String
    let quality: Int
}

enum APIError: Error {
    case badRequest(String)
    case unauthorized(String)
    case conflict(String)
    case preconditionFailed(String)
    case internalError(String)

    var statusCode: Int {
        switch self {
        case .badRequest: return 400
        case .unauthorized: return 401
        case .conflict: return 409
        case .preconditionFailed: return 412
        case .internalError: return 500
        }
    }
    var message: String {
        switch self {
        case .badRequest(let s),
             .unauthorized(let s),
             .conflict(let s),
             .preconditionFailed(let s),
             .internalError(let s): return s
        }
    }
}
\`\`\`

### 2.3 `AudioResampler.swift`
\`\`\`swift
import Foundation
import AVFoundation

enum AudioError: Error {
    case unsupportedFormat(String)
    case conversionFailed(String)
    case io(String)
}

final class AudioResampler {
    func fileToPCM16Mono16k(url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let src = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard let buf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: frames) else {
            throw AudioError.conversionFailed("allocate src")
        }
        try file.read(into: buf)

        let dst = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        return try convert(buf, to: dst)
    }

    func rawL16ToBuffer(data: Data, sampleRate: Double, channels: AVAudioChannelCount) throws -> AVAudioPCMBuffer {
        let src = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: channels, interleaved: true)!
        let frames = AVAudioFrameCount(data.count / Int(channels) / 2)
        guard let buf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: frames) else {
            throw AudioError.conversionFailed("allocate raw")
        }
        buf.frameLength = frames
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(buf.int16ChannelData![0], base, data.count)
            }
        }
        if sampleRate == 16000 && channels == 1 { return buf }
        let dst = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        return try convert(buf, to: dst)
    }

    func convert(_ src: AVAudioPCMBuffer, to dst: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let conv = AVAudioConverter(from: src.format, to: dst) else {
            throw AudioError.conversionFailed("create converter")
        }
        let ratio = Double(dst.sampleRate) / src.format.sampleRate
        let dstFrames = AVAudioFrameCount(Double(src.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: dstFrames) else {
            throw AudioError.conversionFailed("allocate dst")
        }
        var err: NSError?
        let status = conv.convert(to: out, error: &err, withInputFrom: { _, outStatus in
            outStatus.pointee = .haveData
            return src
        })
        if status == .error || err != nil { throw AudioError.conversionFailed("convert fail: \(err?.localizedDescription ?? "unknown")") }
        out.frameLength = out.frameCapacity
        return out
    }

    func wavData(from int16buf: AVAudioPCMBuffer, sampleRate: Int = 16000) throws -> Data {
        guard int16buf.format.commonFormat == .pcmFormatInt16 else {
            throw AudioError.unsupportedFormat("expect Int16")
        }
        let ch = Int(int16buf.format.channelCount)
        let bits = 16
        let byteRate = sampleRate * ch * bits / 8
        let blockAlign = ch * bits / 8
        let frames = Int(int16buf.frameLength)
        let dataBytes = frames * blockAlign

        var out = Data()
        func u32(_ v: UInt32){ var x=v.littleEndian; withUnsafeBytes(of:&x){ out.append(contentsOf:$0) } }
        func u16(_ v: UInt16){ var x=v.littleEndian; withUnsafeBytes(of:&x){ out.append(contentsOf:$0) } }

        out.append("RIFF".data(using:.ascii)!); u32(UInt32(36+dataBytes)); out.append("WAVE".data(using:.ascii)!)
        out.append("fmt ".data(using:.ascii)!); u32(16); u16(1); u16(UInt16(ch)); u32(UInt32(sampleRate)); u32(UInt32(byteRate)); u16(UInt16(blockAlign)); u16(UInt16(bits))
        out.append("data".data(using:.ascii)!); u32(UInt32(dataBytes))

        var pcm = Data(count: dataBytes)
        let dest = pcm.withUnsafeMutableBytes { $0.bindMemory(to: Int16.self).baseAddress! }
        let src = int16buf.int16ChannelData![0]
        dest.update(from: src, count: frames * ch)
        out.append(pcm)
        return out
    }
}
\`\`\`

### 2.4 `TTSEngine.swift`
\`\`\`swift
import Foundation
import AVFoundation

@MainActor
final class TTSEngine: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private let resampler = AudioResampler()

    func listVoices() -> [VoiceInfo] {
        AVSpeechSynthesisVoice.speechVoices().map { v in
            VoiceInfo(name: v.name, identifier: v.identifier, language: v.language, quality: v.quality.rawValue)
        }
    }

    func speakLocal(_ text: String, voiceId: String?, rate: Double?, pitch: Double?) {
        let u = makeUtterance(text: text, voiceId: voiceId, rate: rate, pitch: pitch)
        synth.speak(u)
    }

    private func makeUtterance(text: String, voiceId: String?, rate: Double?, pitch: Double?) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        if let id = voiceId, let v = AVSpeechSynthesisVoice(identifier: id) { u.voice = v }
        if let r = rate { u.rate = max(0.5, min(2.0, Float(r))) * AVSpeechUtteranceDefaultSpeechRate }
        if let p = pitch { u.pitchMultiplier = max(0.5, min(2.0, Float(1.0 + p))) }
        return u
    }

    /// Synthesize → 16kHz mono PCM16 WAV
    func synthesizeToWAV(text: String, voiceId: String?, rate: Double?, pitch: Double?) async throws -> Data {
        let utterance = makeUtterance(text: text, voiceId: voiceId, rate: rate, pitch: pitch)
        var collected: [AVAudioPCMBuffer] = []
        var fmt: AVAudioFormat?

        let wav: Data = try await withCheckedThrowingContinuation { cont in
            self.synth.write(utterance) { buffer in
                if let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 {
                    collected.append(pcm)
                    if fmt == nil { fmt = pcm.format }
                    return
                }
                // final callback
                do {
                    guard let f = fmt, !collected.isEmpty else { throw AudioError.io("TTS produced no audio data") }
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
                    cont.resume(returning: data)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        return wav
    }
}
\`\`\`

### 2.5 `STTEngine.swift`
\`\`\`swift
import Foundation
import Speech
import AVFoundation

final class STTEngine {
    private let cfg: Config
    private let resampler = AudioResampler()

    init(config: Config) { self.cfg = config }

    func onDeviceSupported(lang: String) -> Bool {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: lang)) else { return false }
        return r.supportsOnDeviceRecognition
    }

    func languages() -> [String] {
        SFSpeechRecognizer.supportedLocales().map { $0.identifier }.sorted()
    }

    func transcribeFile(url: URL, lang: String, offline: Bool?) async throws -> STTResponse {
        let locale = Locale(identifier: lang)
        guard let rec = SFSpeechRecognizer(locale: locale) else { throw APIError.badRequest("Unsupported language \(lang)") }
        let req = SFSpeechURLRecognitionRequest(url: url)
        if cfg.offlineOnly || (offline ?? false) {
            if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
            else { throw APIError.preconditionFailed("offline=true requested, on-device recognition for \(lang) is not available.") }
        }
        return try await recognize(recognizer: rec, request: req)
    }

    func transcribeRaw(data: Data, sampleRate: Double?, channels: Int?, lang: String, offline: Bool?) async throws -> STTResponse {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stt-\(UUID().uuidString).wav")
        if let sr = sampleRate, let ch = channels {
            let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sr, channels: AVAudioChannelCount(ch), interleaved: true)!
            let frames = AVAudioFrameCount(data.count / ch / 2)
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { throw APIError.internalError("alloc") }
            buf.frameLength = frames
            data.withUnsafeBytes { ptr in if let base = ptr.baseAddress { memcpy(buf.int16ChannelData![0], base, data.count) } }
            let dst = try resampler.convert(buf, to: AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!)
            let wav = try resampler.wavData(from: dst, sampleRate: 16000)
            try wav.write(to: tmp)
        } else {
            try data.write(to: tmp)
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try await transcribeFile(url: tmp, lang: lang, offline: offline)
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

// Live WS-Stream
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
\`\`\`

### 2.6 `HTTPServer.swift`
\`\`\`swift
import Foundation
import NIO
import NIOHTTP1
import NIOWebSocket
import AVFoundation
import Speech

extension ByteBuffer {
    mutating func readData(length: Int) -> Data? {
        guard let bytes = self.readBytes(length: length) else { return nil }
        return Data(bytes)
    }
}

final class HTTPServer {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    private let cfg: Config
    private let stt: STTEngine
    private let tts = TTSEngine()

    init(config: Config) {
        self.cfg = config
        self.stt = STTEngine(config: config)
    }

    func start() throws {
        let upgrader = NIOWebSocketServerUpgrader(maxFrameSize: 1 << 20,
            shouldUpgrade: { channel, head in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
            upgradePipelineHandler: { channel, req in self.installWebSocket(channel: channel, request: req) }
        )

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let handler = HTTPHandler(server: self, upgrader: upgrader)
                return channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true,
                    withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in })
                ).flatMap { channel.pipeline.addHandler(handler) }
            }
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

        let ch = try bootstrap.bind(host: cfg.bindHost, port: cfg.port).wait()
        print("🔊 STTBridge running at http://\(cfg.bindHost):\(cfg.port)")
        try ch.closeFuture.wait()
    }

    private func installWebSocket(channel: Channel, request: HTTPRequestHead) -> EventLoopFuture<Void> {
        let path = URL(string: request.uri)?.path ?? request.uri
        guard path == "/stt/stream" else {
            var buf = channel.allocator.buffer(capacity: 0)
            buf.writeString("{\"type\":\"error\",\"error\":\"invalid_path\"}")
            let frame = WebSocketFrame(fin: true, opcode: .text, data: buf)
            channel.writeAndFlush(frame, promise: nil)
            return channel.close()
        }

        var lang = cfg.defaultLang
        var offline = false
        var partials = true
        var token: String? = nil
        if let url = URL(string: request.uri), let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            for q in comps.queryItems ?? [] {
                switch q.name {
                case "lang": lang = q.value ?? lang
                case "offline": offline = (q.value ?? "false").lowercased() == "true" || cfg.offlineOnly
                case "partials": partials = (q.value ?? "true").lowercased() == "true"
                case "token": token = q.value
                default: break
                }
            }
        }
        if let required = cfg.authToken {
            let provided = token ?? request.headers.first(name: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
            if provided != required {
                var buf = channel.allocator.buffer(capacity: 0)
                buf.writeString("{\"type\":\"error\",\"error\":\"unauthorized\"}")
                let frame = WebSocketFrame(fin: true, opcode: .text, data: buf)
                channel.writeAndFlush(frame, promise: nil)
                return channel.close()
            }
        }

        do {
            let session = try STTStreamSession(lang: lang, requiresOnDevice: offline || cfg.offlineOnly)
            let wsHandler = WebSocketStreamHandler(session: session, sendPartials: partials)
            session.onPartial = { [weak wsHandler] text in wsHandler?.send(json: ["type":"partial","text":text]) }
            session.onFinal   = { [weak wsHandler] text, conf in
                var obj: [String:Any] = ["type":"final","text":text]
                if let c = conf { obj["confidence"] = c }
                wsHandler?.send(json: obj)
            }
            session.onError   = { [weak wsHandler] err in wsHandler?.send(json: ["type":"error","error":"\(err)"]) }
            return channel.pipeline.addHandler(wsHandler, name: "ws-handler", position: .last)
        } catch {
            var buf = channel.allocator.buffer(capacity: 0)
            buf.writeString("{\"type\":\"error\",\"error\":\"\(error)\"}")
            let frame = WebSocketFrame(fin: true, opcode: .text, data: buf)
            channel.writeAndFlush(frame, promise: nil)
            return channel.close()
        }
    }

    // MARK: HTTP Handler
    final class HTTPHandler: ChannelInboundHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private let server: HTTPServer
        private let upgrader: NIOWebSocketServerUpgrader
        private var head: HTTPRequestHead?
        private var bodyBuf: ByteBuffer?

        init(server: HTTPServer, upgrader: NIOWebSocketServerUpgrader) {
            self.server = server
            self.upgrader = upgrader
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let part = self.unwrapInboundIn(data)
            switch part {
            case .head(let h): head = h; bodyBuf = context.channel.allocator.buffer(capacity: 0)
            case .body(var b): bodyBuf?.writeBuffer(&b)
            case .end:
                if let h = head, let body = bodyBuf { route(context: context, head: h, body: body) }
                head = nil; bodyBuf = nil
            }
        }

        private func corsHeaders(for origin: String?) -> HTTPHeaders {
            var h = HTTPHeaders()
            let allow = (origin?.hasPrefix("http://localhost") ?? false) ? origin! : "http://localhost"
            h.add(name: "Access-Control-Allow-Origin", value: allow)
            h.add(name: "Access-Control-Allow-Methods", value: "GET,POST,OPTIONS")
            h.add(name: "Access-Control-Allow-Headers", value: "Content-Type,Authorization,X-Sample-Rate,X-Channel-Count")
            h.add(name: "Access-Control-Max-Age", value: "86400")
            return h
        }

        private func verifyAuth(_ head: HTTPRequestHead) -> APIError? {
            guard let required = server.cfg.authToken else { return nil }
            let provided = head.headers.first(name: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
            if provided != required { return .unauthorized("Missing or invalid token.") }
            return nil
        }

        private func writeHeadBodyEnd(_ context: ChannelHandlerContext, status: HTTPResponseStatus, headers: HTTPHeaders, body: ByteBuffer?) {
            let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
            context.write(self.wrapOutboundOut(.head(head)), promise: nil)
            if let body = body {
                context.write(self.wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
            }
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }

        private func writeJSON<T: Encodable>(_ context: ChannelHandlerContext, value: T, status: HTTPResponseStatus = .ok, extra: HTTPHeaders? = nil) {
            var headers = HTTPHeaders(); headers.add(name: "Content-Type", value: "application/json; charset=utf-8")
            if let e = extra { for (n,v) in e { headers.add(name:n, value:v) } }
            let data = try! JSONEncoder().encode(value)
            var buf = context.channel.allocator.buffer(capacity: data.count); buf.writeBytes(data)
            writeHeadBodyEnd(context, status: status, headers: headers, body: buf)
        }

        private func writeBytes(_ context: ChannelHandlerContext, data: Data, contentType: String, status: HTTPResponseStatus = .ok, extra: HTTPHeaders? = nil) {
            var headers = HTTPHeaders(); headers.add(name: "Content-Type", value: contentType)
            if let e = extra { for (n,v) in e { headers.add(name:n, value:v) } }
            var buf = context.channel.allocator.buffer(capacity: data.count); buf.writeBytes(data)
            writeHeadBodyEnd(context, status: status, headers: headers, body: buf)
        }

        private func writeError(_ context: ChannelHandlerContext, _ error: APIError, extra: HTTPHeaders? = nil) {
            writeJSON(context, value: ["error": error.message], status: .init(statusCode: error.statusCode), extra: extra)
        }

        private func route(context: ChannelHandlerContext, head: HTTPRequestHead, body: ByteBuffer) {
            let origin = head.headers.first(name: "Origin")
            let extra = corsHeaders(for: origin)

            if head.method == .OPTIONS {
                writeHeadBodyEnd(context, status: .ok, headers: extra, body: nil); return
            }

            let path = URL(string: head.uri)?.path ?? head.uri
            switch (head.method, path) {
            case (.GET, "/healthz"):
                let supported = server.stt.onDeviceSupported(lang: server.cfg.defaultLang)
                writeJSON(context, value: Healthz(status: "ok", lang: server.cfg.defaultLang, onDeviceSTT: supported), extra: extra)

            case (.GET, "/languages"):
                writeJSON(context, value: server.stt.languages(), extra: extra)

            case (.GET, "/voices"):
                writeJSON(context, value: server.tts.listVoices(), extra: extra)

            case (.GET, "/"):
                if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "WebRoot"),
                   let data = try? Data(contentsOf: url) {
                    writeBytes(context, data: data, contentType: "text/html; charset=utf-8", extra: extra)
                } else { writeError(context, .internalError("index.html is missing"), extra: extra) }

            case (.GET, "/app.js"):
                if let url = Bundle.main.url(forResource: "app", withExtension: "js", subdirectory: "WebRoot"),
                   let data = try? Data(contentsOf: url) {
                    writeBytes(context, data: data, contentType: "application/javascript", extra: extra)
                } else { writeError(context, .internalError("app.js is missing"), extra: extra) }

            case (.GET, "/styles.css"):
                if let url = Bundle.main.url(forResource: "styles", withExtension: "css", subdirectory: "WebRoot"),
                   let data = try? Data(contentsOf: url) {
                    writeBytes(context, data: data, contentType: "text/css", extra: extra)
                } else { writeError(context, .internalError("styles.css is missing"), extra: extra) }

            case (.POST, "/stt"):
                if let err = verifyAuth(head) { writeError(context, err, extra: extra); return }
                let comps = URLComponents(string: head.uri)
                let lang = comps?.queryItems?.first(where: { $0.name == "lang" })?.value ?? server.cfg.defaultLang
                let offline = (server.cfg.offlineOnly || ((comps?.queryItems?.first(where: { $0.name == "offline" })?.value ?? "false").lowercased() == "true"))
                let ct = head.headers.first(name: "Content-Type")?.lowercased() ?? "application/octet-stream"
                var copy = body
                let payload = copy.readData(length: body.readableBytes) ?? Data()
                Task.detached {
                    do {
                        let resp: STTResponse
                        if ct.contains("audio/l16") {
                            let sr = Double(head.headers.first(name: "X-Sample-Rate") ?? "16000") ?? 16000
                            let ch = Int(head.headers.first(name: "X-Channel-Count") ?? "1") ?? 1
                            resp = try await self.server.stt.transcribeRaw(data: payload, sampleRate: sr, channels: ch, lang: lang, offline: offline)
                        } else {
                            resp = try await self.server.stt.transcribeRaw(data: payload, sampleRate: nil, channels: nil, lang: lang, offline: offline)
                        }
                        context.eventLoop.execute { self.writeJSON(context, value: resp, extra: extra) }
                    } catch let e as APIError {
                        context.eventLoop.execute { self.writeError(context, e, extra: extra) }
                    } catch {
                        context.eventLoop.execute { self.writeError(context, .internalError("Internal error"), extra: extra) }
                    }
                }

            case (.POST, "/tts"):
                if let err = verifyAuth(head) { writeError(context, err, extra: extra); return }
                var copy = body
                guard let data = copy.readData(length: body.readableBytes),
                      let payload = try? JSONDecoder().decode(TTSPayload.self, from: data) else {
                    writeError(context, .badRequest("Invalid JSON body"), extra: extra); return
                }
                if payload.speakLocal ?? false {
                    Task { @MainActor in
                        self.server.tts.speakLocal(payload.text, voiceId: payload.voiceId, rate: payload.rate, pitch: payload.pitch)
                        self.writeJSON(context, value: ["ok": true], extra: extra)
                    }
                } else {
                    Task {
                        do {
                            let wav = try await self.server.tts.synthesizeToWAV(text: payload.text, voiceId: payload.voiceId, rate: payload.rate, pitch: payload.pitch)
                            context.eventLoop.execute { self.writeBytes(context, data: wav, contentType: "audio/wav", extra: extra) }
                        } catch {
                            context.eventLoop.execute { self.writeError(context, .internalError("TTS error: \(error)"), extra: extra) }
                        }
                    }
                }

            default:
                let headResp = HTTPResponseHead(version: .http1_1, status: .notFound, headers: extra)
                context.write(self.wrapOutboundOut(.head(headResp)), promise: nil)
                context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}

// MARK: WebSocket stream handler
final class WebSocketStreamHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    private let session: STTStreamSession
    private let sendPartials: Bool
    private weak var channel: Channel?

    init(session: STTStreamSession, sendPartials: Bool) {
        self.session = session; self.sendPartials = sendPartials
    }
    func handlerAdded(context: ChannelHandlerContext) { self.channel = context.channel }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        switch frame.opcode {
        case .binary:
            var d = frame.data; let n = d.readableBytes
            if let payload = d.readData(length: n) { try? session.append(payload) }
        case .connectionClose:
            session.stop(); context.close(promise: nil)
        default: break
        }
    }
    func handlerRemoved(context: ChannelHandlerContext) { session.stop() }

    func send(json: [String:Any]) {
        guard let ch = channel else { return }
        if !sendPartials, (json["type"] as? String) == "partial" { return }
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        var buf = ch.allocator.buffer(capacity: data.count); buf.writeBytes(data)
        ch.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, data: buf), promise: nil)
    }
}
\`\`\`

---

## 3) SwiftUI App Skeleton

### 3.1 `STTBridgeApp.swift` + `ContentView.swift`
\`\`\`swift
import SwiftUI
import Speech

@main
struct STTBridgeApp: App {
    @StateObject private var serverMgr = ServerManager()

    var body: some Scene {
        WindowGroup {
            ContentView(status: serverMgr.status)
        }
    }
}

final class ServerManager: ObservableObject {
    @Published var status: String = "Starting..."
    private var server: HTTPServer?

    init() {
        SFSpeechRecognizer.requestAuthorization { st in
            print("Speech auth: \(st)")
        }
        let cfg = Config()
        DispatchQueue.global(qos: .userInitiated).async {
            let srv = HTTPServer(config: cfg)
            self.server = srv
            do {
                DispatchQueue.main.async { self.status = "Server running at http://\(cfg.bindHost):\(cfg.port)" }
                try srv.start()
            } catch {
                DispatchQueue.main.async { self.status = "Server error: \(error)" }
            }
        }
    }
}

struct ContentView: View {
    let status: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STTBridge").font(.title).bold()
            Text(status).font(.body).textSelection(.enabled)
            Text("• Endpunkte: /healthz, /languages, /voices, /stt, /tts, WS: /stt/stream")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 520, alignment: .leading)
    }
}
\`\`\`

---

## 4) WebRoot‑Dateien (als **Folder Reference** einbinden)

### 4.1 `WebRoot/index.html`
\`\`\`html
<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>STTBridge – Demo</title>
<link rel="stylesheet" href="/styles.css">
</head>
<body>
<main>
  <h1>STTBridge – local speech bridge</h1>
  <section class="card">
    <h2>WebSocket STT</h2>
    <div class="row">
      <label>Language:</label><input id="lang" value="de-DE">
      <label><input id="offline" type="checkbox"> offline</label>
      <label><input id="partials" type="checkbox" checked> Partials</label>
    </div>
    <div class="row">
      <button id="startBtn">Start</button>
      <button id="stopBtn" disabled>Stop</button>
    </div>
    <pre id="sttOut"></pre>
  </section>
  <section class="card">
    <h2>TTS</h2>
    <div class="row"><textarea id="ttsText" rows="3">Hello Stuttgart! This is a local TTS demo.</textarea></div>
    <div class="row">
      <label>Voice ID:</label><input id="voiceId" size="40" placeholder="com.apple.speech.synthesis.voice...">
      <label>Rate:</label><input id="rate" type="number" min="0.5" max="2.0" step="0.1" value="1.0">
      <label>Pitch:</label><input id="pitch" type="number" min="-1" max="1" step="0.1" value="0">
      <label><input id="speakLocal" type="checkbox"> direkt am Mac ausgeben</label>
    </div>
    <div class="row"><button id="ttsBtn">Speak</button></div>
    <audio id="player" controls></audio>
  </section>
</main>
<script src="/app.js"></script>
</body>
</html>
\`\`\`

### 4.2 `WebRoot/app.js`
\`\`\`javascript
let ws, mediaStream;
const log = (m)=>{const el=document.getElementById('sttOut'); el.textContent+=m+"\n"; el.scrollTop=el.scrollHeight;};
const start = async ()=>{
  document.getElementById('sttOut').textContent='';
  const lang = document.getElementById('lang').value || 'de-DE';
  const offline = document.getElementById('offline').checked;
  const partials = document.getElementById('partials').checked;
  mediaStream = await navigator.mediaDevices.getUserMedia({ audio: true });
  const audioCtx = new AudioContext({ sampleRate: 16000 });
  const source = audioCtx.createMediaStreamSource(mediaStream);
  const proc = audioCtx.createScriptProcessor(4096,1,1);
  source.connect(proc); proc.connect(audioCtx.destination);
  ws = new WebSocket(`ws://${location.host}/stt/stream?lang=${encodeURIComponent(lang)}&offline=${offline}&partials=${partials}`);
  ws.onopen = ()=>log('WS connected');
  ws.onmessage = ev=>{ try{ const o=JSON.parse(ev.data);
    if(o.type==='partial') log('· '+o.text);
    if(o.type==='final') log('✔ '+o.text+(o.confidence!=null?` (conf=${o.confidence.toFixed(2)})`:''));
    if(o.type==='error') log('⚠ Error: '+o.error);
  }catch{} };
  ws.onclose = ()=>log('WS closed');
  proc.onaudioprocess = e=>{
    if(!ws || ws.readyState!==1) return;
    const input=e.inputBuffer.getChannelData(0);
    const buf=new ArrayBuffer(input.length*2), view=new DataView(buf);
    for(let i=0;i<input.length;i++){ let s=Math.max(-1,Math.min(1,input[i])); view.setInt16(i*2, s<0?s*0x8000:s*0x7FFF, true); }
    ws.send(buf);
  };
  document.getElementById('startBtn').disabled=true;
  document.getElementById('stopBtn').disabled=false;
};
const stop = ()=>{
  if(ws) ws.close();
  if(mediaStream) mediaStream.getTracks().forEach(t=>t.stop());
  document.getElementById('startBtn').disabled=false;
  document.getElementById('stopBtn').disabled=true;
};
document.getElementById('startBtn').onclick=start;
document.getElementById('stopBtn').onclick=stop;
document.getElementById('ttsBtn').onclick=async()=>{
  const text=document.getElementById('ttsText').value;
  const voiceId=document.getElementById('voiceId').value || null;
  const rate=parseFloat(document.getElementById('rate').value);
  const pitch=parseFloat(document.getElementById('pitch').value);
  const speakLocal=document.getElementById('speakLocal').checked;
  const res=await fetch('/tts',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({text,voiceId,rate,pitch,speakLocal})});
  if(speakLocal){ await res.json(); alert('Local playback started.'); return; }
  const blob=await res.blob(); const url=URL.createObjectURL(blob); const player=document.getElementById('player'); player.src=url; player.play();
};
\`\`\`

### 4.3 `WebRoot/styles.css`
\`\`\`css
*{box-sizing:border-box}body{font-family:-apple-system,system-ui,Segoe UI,Roboto,Ubuntu,Helvetica,Arial,sans-serif;margin:0;padding:0;line-height:1.5}
main{max-width:900px;margin:40px auto;padding:0 16px}
h1{font-weight:700}
.card{background:#14161a;padding:16px;border-radius:12px;margin:16px 0;border:1px solid #2a2e33;color:#e6eef7}
.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin:8px 0}
pre{background:#0a0f14;color:#7dd3fc;padding:12px;border-radius:8px;height:220px;overflow:auto}
@media (prefers-color-scheme: light){body{background:#f6f7fb;color:#1d232a}.card{background:#fff;border-color:#e0e6ee;color:#1d232a}pre{background:#111;color:#0bf}}
\`\`\`

---

## 5) Run & Test

1. **Run** (▶︎ or `⌘R`). Approve the permission dialogs for **Microphone** and **Speech Recognition**.
2. Browser: `http://127.0.0.1:8787/` → Web‑Demo.
3. **cURL**:
\`\`\`bash
# Health
curl http://127.0.0.1:8787/healthz

# STT mit WAV
curl --data-binary @sample.wav -H "Content-Type: audio/wav" \
  "http://127.0.0.1:8787/stt?lang=de-DE&offline=true"

# TTS → WAV
curl -X POST http://127.0.0.1:8787/tts \
  -H 'Content-Type: application/json' \
  -d '{"text":"Hello Stuttgart"}' --output out.wav
\`\`\`

> **Stabile Freigaben:** App in **/Applications** kopieren und immer **dieselbe Kopie** starten.  
> Reset TCC if needed:  
> \`\`\`bash
> tccutil reset Microphone local.sttbridge
> tccutil reset SpeechRecognition local.sttbridge
> \`\`\`

---

## 6) Optional: Auth & ENV
- `AUTH_TOKEN=secret` → mutating endpoints require `Authorization: Bearer secret`.
- `PORT`, `BIND_HOST`, `DEFAULT_LANG`, `OFFLINE_ONLY` werden gelesen.

---

## 7) MVP‑Scope & Next
- Multipart upload for `/stt`, `/tts/stream` (SSE/chunked), Prometheus metrics, LaunchAgent, and a menu bar UI can be added easily.
