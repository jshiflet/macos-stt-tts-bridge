import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import NIOSSL
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
    private var channels: [Channel] = []

    /// True when a host string is one of the loopback aliases.
    static func isLoopbackBind(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "127.0.0.1" || h == "::1" || h == "localhost"
    }

    /// True when every bound host is loopback. If false, the server is reachable
    /// from the network on at least one of its addresses.
    static func allLoopback(_ hosts: [String]) -> Bool {
        hosts.allSatisfy { isLoopbackBind($0) }
    }

    /// Subset of bound hosts that are non-loopback (for surfacing in error messages
    /// and warnings).
    static func nonLoopbackHosts(_ hosts: [String]) -> [String] {
        hosts.filter { !isLoopbackBind($0) }
    }

    /// Single source of truth for "is this caller allowed to use protected endpoints?".
    ///   - If an auth token is configured, the caller must supply it.
    ///   - If no token is configured and any bound host is non-loopback, refuse.
    ///   - If no token is configured and every bound host is loopback, allow (dev mode).
    static func authError(providedToken: String?, config: Config) -> APIError? {
        if let required = config.authToken, !required.isEmpty {
            return providedToken == required ? nil : .unauthorized("Missing or invalid token.")
        }
        if !allLoopback(config.bindHosts) {
            return .unauthorized("Authentication is required when the server is not bound exclusively to loopback. Set an auth token in Settings.")
        }
        return nil
    }

    /// Builds an `NIOSSLContext` from the imported certificate material plus the
    /// user's TLS version / cipher knobs. Supports both PKCS#12 bundles and PEM
    /// cert + key file pairs (with optional passphrase for AES/3DES-wrapped keys).
    /// Throws a descriptive error if anything is missing or fails to parse.
    static func makeSSLContext(config: Config) throws -> NIOSSLContext {
        let password = config.tlsP12Password ?? ""
        let chain: [NIOSSLCertificate]
        let privateKey: NIOSSLPrivateKey

        switch config.tlsCertFormat {
        case .pkcs12:
            let url: URL
            do { url = try CertificateStore.p12URL() } catch {
                throw TLSError.loadFailed("Could not resolve certificate path: \(error.localizedDescription)")
            }
            guard FileManager.default.fileExists(atPath: url.path) else { throw TLSError.noCertificate }
            do {
                let pass: [UInt8]? = password.isEmpty ? nil : Array(password.utf8)
                let bundle = try NIOSSLPKCS12Bundle(file: url.path, passphrase: pass)
                chain = bundle.certificateChain
                privateKey = bundle.privateKey
            } catch {
                throw TLSError.loadFailed(error.localizedDescription)
            }

        case .pem:
            let certURL: URL
            let keyURL: URL
            do {
                certURL = try CertificateStore.pemCertURL()
                keyURL = try CertificateStore.pemKeyURL()
            } catch {
                throw TLSError.loadFailed("Could not resolve PEM paths: \(error.localizedDescription)")
            }
            guard FileManager.default.fileExists(atPath: certURL.path) else { throw TLSError.noCertificate }
            guard FileManager.default.fileExists(atPath: keyURL.path) else {
                throw TLSError.loadFailed("Private key file is missing")
            }
            do {
                chain = try NIOSSLCertificate.fromPEMFile(certURL.path)
            } catch {
                throw TLSError.loadFailed("Certificate file: \(error.localizedDescription)")
            }
            do {
                privateKey = try CertificateStore.loadPEMPrivateKey(keyURL: keyURL, password: password)
            } catch {
                throw TLSError.loadFailed("Private key: \(error.localizedDescription)")
            }
        }

        var tls = TLSConfiguration.makeServerConfiguration(
            certificateChain: chain.map { NIOSSLCertificateSource.certificate($0) },
            privateKey: .privateKey(privateKey)
        )
        // Validate min ≤ max, swap if user got them wrong.
        let lo = min(config.tlsMinVersion.rank, config.tlsMaxVersion.rank)
        let hi = max(config.tlsMinVersion.rank, config.tlsMaxVersion.rank)
        let minVer = TLSVersionPref.ordered.first { $0.rank == lo } ?? .tls12
        let maxVer = TLSVersionPref.ordered.first { $0.rank == hi } ?? .tls13
        tls.minimumTLSVersion = minVer.niossl
        tls.maximumTLSVersion = maxVer.niossl

        if let ciphers = config.tlsCustomCiphers, !ciphers.isEmpty {
            tls.cipherSuites = ciphers.joined(separator: ":")
        }
        // HTTP/1.1 over TLS — declare it via ALPN so well-behaved clients don't
        // attempt h2 (we don't speak HTTP/2 here).
        tls.applicationProtocols = ["http/1.1"]

        return try NIOSSLContext(configuration: tls)
    }

    init(config: Config) {
        self.cfg = config
        self.stt = STTEngine(config: config)
    }

    /// Closes all listening channels, which causes `start()` to return.
    func stop() {
        for ch in channels { ch.close(promise: nil) }
    }

    func start() throws {
        let upgrader = NIOWebSocketServerUpgrader(maxFrameSize: 1 << 20,
            shouldUpgrade: { channel, head in channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { channel, req in self.installWebSocket(channel: channel, request: req)
            }
        )

        // Build the SSL context once. Any failure (missing cert, wrong password,
        // unreadable PKCS#12) surfaces here before the socket is bound, so the
        // user gets a clear error instead of mysterious handshake failures later.
        let sslContext: NIOSSLContext?
        if cfg.tlsEnabled {
            sslContext = try Self.makeSSLContext(config: cfg)
        } else {
            sslContext = nil
        }

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let handler = HTTPHandler(server: self, upgrader: upgrader)
                let prelude: EventLoopFuture<Void>
                if let ctx = sslContext {
                    let sslHandler = NIOSSLServerHandler(context: ctx)
                    prelude = channel.pipeline.addHandler(sslHandler)
                } else {
                    prelude = channel.eventLoop.makeSucceededFuture(())
                }
                return prelude.flatMap {
                    channel.pipeline.configureHTTPServerPipeline(
                        withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }),
                        withErrorHandling: true
                    )
                }.flatMap { channel.pipeline.addHandler(handler) }
            }
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

        // Bind every requested host. If one fails, close the ones already bound
        // and surface the error so the caller can report it without leaking sockets.
        var bound: [Channel] = []
        do {
            for host in cfg.bindHosts {
                let ch = try bootstrap.bind(host: host, port: cfg.port).wait()
                bound.append(ch)
            }
        } catch {
            for ch in bound { ch.close(promise: nil) }
            try? group.syncShutdownGracefully()
            throw error
        }

        // Optional HTTP → HTTPS redirect listener. Only meaningful when TLS is
        // active; binds on every host at `httpRedirectPort` and 308-redirects
        // every request to the matching https:// URL.
        let wantsRedirect =
            cfg.tlsEnabled &&
            cfg.httpRedirectPort > 0 &&
            cfg.httpRedirectPort != cfg.port
        if wantsRedirect {
            let redirectBootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 256)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { [tlsPort = cfg.port] channel in
                    channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                        channel.pipeline.addHandler(HTTPRedirectHandler(tlsPort: tlsPort))
                    }
                }
                .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            do {
                for host in cfg.bindHosts {
                    let ch = try redirectBootstrap.bind(host: host, port: cfg.httpRedirectPort).wait()
                    bound.append(ch)
                }
            } catch {
                for ch in bound { ch.close(promise: nil) }
                try? group.syncShutdownGracefully()
                throw error
            }
        }

        self.channels = bound
        let scheme = cfg.tlsEnabled ? "https" : "http"
        var urls = cfg.bindHosts.map { "\(scheme)://\($0):\(cfg.port)" }.joined(separator: ", ")
        if wantsRedirect {
            let redirectUrls = cfg.bindHosts.map { "http://\($0):\(cfg.httpRedirectPort)" }.joined(separator: ", ")
            urls += "  (redirect: \(redirectUrls) → \(scheme))"
        }
        print("🔊 STTBridge running at \(urls)")

        // Block until every bound channel is closed (stop() closes them all).
        for ch in bound {
            try ch.closeFuture.wait()
        }
        try? group.syncShutdownGracefully()
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
        let provided = token ?? request.headers.first(name: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
        if HTTPServer.authError(providedToken: provided, config: cfg) != nil {
            var buf = channel.allocator.buffer(capacity: 0)
            buf.writeString("{\"type\":\"error\",\"error\":\"unauthorized\"}")
            let frame = WebSocketFrame(fin: true, opcode: .text, data: buf)
            channel.writeAndFlush(frame, promise: nil)
            return channel.close()
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
            session.onError   = { [weak wsHandler] err in wsHandler?.send(json: ["type":"error","error":"\(err)"])
            }
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

        /// Caps the `text` size accepted by /say and /tts. ~10 minutes of
        /// continuous speech and bounds CPU/memory cost of any single request.
        static let maxSpeechTextLength = 8192

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
            let provided = head.headers.first(name: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
            return HTTPServer.authError(providedToken: provided, config: server.cfg)
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
            headers.add(name: "Content-Length", value: String(data.count))
            var buf = context.channel.allocator.buffer(capacity: data.count); buf.writeBytes(data)
            writeHeadBodyEnd(context, status: status, headers: headers, body: buf)
        }

        private func writeBytes(_ context: ChannelHandlerContext, data: Data, contentType: String, status: HTTPResponseStatus = .ok, extra: HTTPHeaders? = nil) {
            var headers = HTTPHeaders(); headers.add(name: "Content-Type", value: contentType)
            if let e = extra { for (n,v) in e { headers.add(name:n, value:v) } }
            headers.add(name: "Content-Length", value: String(data.count))
            var buf = context.channel.allocator.buffer(capacity: data.count); buf.writeBytes(data)
            writeHeadBodyEnd(context, status: status, headers: headers, body: buf)
        }

        /// Builds an `attachment` Content-Disposition with a filename derived from `text`.
        static func attachmentHeader(text: String, ext: String, fallback: String = "speech") -> (name: String, value: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = String(trimmed.prefix(24))
            let sanitized = prefix
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .joined(separator: "-")
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                .lowercased()
            let slug = sanitized.isEmpty ? fallback : sanitized
            return ("Content-Disposition", "attachment; filename=\"\(slug).\(ext)\"")
        }

        private func writeError(_ context: ChannelHandlerContext, _ error: APIError, extra: HTTPHeaders? = nil) {
            writeJSON(context, value: ["error": error.message], status: .init(statusCode: error.statusCode), extra: extra)
        }

        private func performTTS(context: ChannelHandlerContext,
                                text: String,
                                voiceId: String?,
                                rate: Double?,
                                pitch: Double?,
                                speakLocal: Bool,
                                extra: HTTPHeaders) {
            if text.utf8.count > Self.maxSpeechTextLength {
                writeError(context, .badRequest("text exceeds \(Self.maxSpeechTextLength) byte limit"), extra: extra)
                return
            }
            let eventLoop = context.eventLoop
            let loopBoundContext = NIOLoopBound(context, eventLoop: eventLoop)
            if speakLocal {
                Task { @MainActor in
                    self.server.tts.speakLocal(text, voiceId: voiceId, rate: rate, pitch: pitch)
                    eventLoop.execute { self.writeJSON(loopBoundContext.value, value: ["ok": true], extra: extra) }
                }
            } else {
                let attach = Self.attachmentHeader(text: text, ext: "wav")
                Task {
                    do {
                        let wav = try await self.server.tts.synthesizeToWAV(text: text, voiceId: voiceId, rate: rate, pitch: pitch)
                        var responseHeaders = extra
                        responseHeaders.add(name: attach.name, value: attach.value)
                        eventLoop.execute { self.writeBytes(loopBoundContext.value, data: wav, contentType: "audio/wav", extra: responseHeaders) }
                    } catch {
                        eventLoop.execute { self.writeError(loopBoundContext.value, .internalError("TTS error: \(error)"), extra: extra) }
                    }
                }
            }
        }

        private func performSay(context: ChannelHandlerContext,
                                text: String,
                                speakLocal: Bool,
                                extra: HTTPHeaders) {
            if text.utf8.count > Self.maxSpeechTextLength {
                writeError(context, .badRequest("text exceeds \(Self.maxSpeechTextLength) byte limit"), extra: extra)
                return
            }
            let eventLoop = context.eventLoop
            let loopBoundContext = NIOLoopBound(context, eventLoop: eventLoop)
            if speakLocal {
                Task {
                    do {
                        try await self.server.tts.speakWithSay(text)
                        eventLoop.execute { self.writeJSON(loopBoundContext.value, value: ["ok": true], extra: extra) }
                    } catch let error as APIError {
                        eventLoop.execute { self.writeError(loopBoundContext.value, error, extra: extra) }
                    } catch {
                        eventLoop.execute { self.writeError(loopBoundContext.value, .internalError("say error: \(error)"), extra: extra) }
                    }
                }
            } else {
                let attach = Self.attachmentHeader(text: text, ext: "wav")
                Task {
                    do {
                        let wav = try await self.server.tts.synthesizeWithSayToWAV(text)
                        var responseHeaders = extra
                        responseHeaders.add(name: attach.name, value: attach.value)
                        eventLoop.execute { self.writeBytes(loopBoundContext.value, data: wav, contentType: "audio/wav", extra: responseHeaders) }
                    } catch let error as APIError {
                        eventLoop.execute { self.writeError(loopBoundContext.value, error, extra: extra) }
                    } catch {
                        eventLoop.execute { self.writeError(loopBoundContext.value, .internalError("say error: \(error)"), extra: extra) }
                    }
                }
            }
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
                let lang = comps?.queryItems?.first(where: { $0.name == "lang" })?.value ??
                           head.headers.first(name: "X-Language") ??
                           server.cfg.defaultLang
                let offline = (server.cfg.offlineOnly || ((comps?.queryItems?.first(where: { $0.name == "offline" })?.value ?? "false").lowercased() == "true"))
                let ct = head.headers.first(name: "Content-Type")?.lowercased() ?? "application/octet-stream"
                var copy = body
                let payload = copy.readData(length: body.readableBytes) ?? Data()
                
                // Extract sample rate and channel count from headers (for Home Assistant compatibility)
                let sampleRateHeader = head.headers.first(name: "X-Sample-Rate")
                let channelCountHeader = head.headers.first(name: "X-Channel-Count")
                
                let eventLoop = context.eventLoop
                let loopBoundContext = NIOLoopBound(context, eventLoop: eventLoop)
                Task.detached {
                    do {
                        let resp: STTResponse
                        if ct.contains("audio/l16") {
                            // Explicit raw PCM
                            let sr = Double(head.headers.first(name: "X-Sample-Rate") ?? "16000") ?? 16000
                            let ch = Int(head.headers.first(name: "X-Channel-Count") ?? "1") ?? 1
                            resp = try await self.server.stt.transcribeRaw(data: payload, sampleRate: sr, channels: ch, lang: lang, offline: offline)
                        } else if let srStr = sampleRateHeader, let chStr = channelCountHeader {
                            // WAV with metadata headers (Home Assistant sends this)
                            let sr = Double(srStr) ?? 16000
                            let ch = Int(chStr) ?? 1
                            resp = try await self.server.stt.transcribeRaw(data: payload, sampleRate: sr, channels: ch, lang: lang, offline: offline)
                        } else {
                            // Regular WAV file
                            resp = try await self.server.stt.transcribeRaw(data: payload, sampleRate: nil, channels: nil, lang: lang, offline: offline)
                        }
                        let encoded = try await MainActor.run {
                            try JSONEncoder().encode(resp)
                        }
                        eventLoop.execute {
                            self.writeBytes(
                                loopBoundContext.value,
                                data: encoded,
                                contentType: "application/json; charset=utf-8",
                                extra: extra
                            )
                        }
                    } catch let e as APIError {
                        eventLoop.execute { self.writeError(loopBoundContext.value, e, extra: extra) }
                    } catch {
                        eventLoop.execute { self.writeError(loopBoundContext.value, .internalError("Internal error"), extra: extra) }
                    }
                }

            case (.POST, "/tts"):
                if let err = verifyAuth(head) { writeError(context, err, extra: extra); return }
                var copy = body
                guard let data = copy.readData(length: body.readableBytes),
                      let payload = try? JSONDecoder().decode(TTSPayload.self, from: data) else {
                    writeError(context, .badRequest("Invalid JSON body"), extra: extra); return
                }
                performTTS(context: context,
                           text: payload.text,
                           voiceId: payload.voiceId,
                           rate: payload.rate,
                           pitch: payload.pitch,
                           speakLocal: payload.speakLocal ?? false,
                           extra: extra)

            case (.GET, "/tts"):
                if let err = verifyAuth(head) { writeError(context, err, extra: extra); return }
                let comps = URLComponents(string: head.uri)
                guard let text = comps?.queryItems?.first(where: { $0.name == "text" })?.value,
                      !text.isEmpty else {
                    writeError(context, .badRequest("Missing 'text' query parameter"), extra: extra); return
                }
                let voiceId = comps?.queryItems?.first(where: { $0.name == "voiceId" })?.value
                let rate = (comps?.queryItems?.first(where: { $0.name == "rate" })?.value).flatMap { Double($0) }
                let pitch = (comps?.queryItems?.first(where: { $0.name == "pitch" })?.value).flatMap { Double($0) }
                let speakLocal = ((comps?.queryItems?.first(where: { $0.name == "speakLocal" })?.value) ?? "false").lowercased() == "true"
                performTTS(context: context,
                           text: text,
                           voiceId: voiceId,
                           rate: rate,
                           pitch: pitch,
                           speakLocal: speakLocal,
                           extra: extra)

            case (.POST, "/say"):
                if let err = verifyAuth(head) { writeError(context, err, extra: extra); return }
                var copy = body
                guard let data = copy.readData(length: body.readableBytes),
                      let payload = try? JSONDecoder().decode(SayPayload.self, from: data) else {
                    writeError(context, .badRequest("Invalid JSON body"), extra: extra); return
                }
                performSay(context: context,
                           text: payload.text,
                           speakLocal: payload.speakLocal ?? false,
                           extra: extra)

            case (.GET, "/say"):
                if let err = verifyAuth(head) { writeError(context, err, extra: extra); return }
                let comps = URLComponents(string: head.uri)
                guard let text = comps?.queryItems?.first(where: { $0.name == "text" })?.value,
                      !text.isEmpty else {
                    writeError(context, .badRequest("Missing 'text' query parameter"), extra: extra); return
                }
                let speakLocal = ((comps?.queryItems?.first(where: { $0.name == "speakLocal" })?.value) ?? "false").lowercased() == "true"
                performSay(context: context, text: text, speakLocal: speakLocal, extra: extra)

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
// MARK: - HTTP → HTTPS redirect handler

/// Plain-HTTP handler that 308-redirects every request to the matching https:// URL
/// on `tlsPort`. Bound on the same hosts as the main server when TLS is on and the
/// user has configured a redirect port.
final class HTTPRedirectHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let tlsPort: Int
    private var head: HTTPRequestHead?

    init(tlsPort: Int) {
        self.tlsPort = tlsPort
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = self.unwrapInboundIn(data)
        switch part {
        case .head(let h):
            head = h
        case .body:
            break  // Body discarded — client retries POST/PUT on the redirected URL.
        case .end:
            guard let h = head else { return }
            head = nil

            // Derive the destination host: strip any :port from the incoming Host
            // header. Fall back to "localhost" for ancient HTTP/1.0 clients.
            let hostHeader = h.headers.first(name: "Host") ?? "localhost"
            let hostOnly = hostHeader.split(separator: ":").first.map(String.init) ?? hostHeader
            let location = "https://\(hostOnly):\(tlsPort)\(h.uri)"

            var headers = HTTPHeaders()
            headers.add(name: "Location", value: location)
            headers.add(name: "Content-Length", value: "0")
            headers.add(name: "Connection", value: "close")

            let respHead = HTTPResponseHead(
                version: .http1_1,
                status: .permanentRedirect,   // 308: preserves request method
                headers: headers
            )
            context.write(self.wrapOutboundOut(.head(respHead)), promise: nil)
            context.writeAndFlush(self.wrapOutboundOut(.end(nil))).whenComplete { _ in
                context.close(promise: nil)
            }
        }
    }
}

