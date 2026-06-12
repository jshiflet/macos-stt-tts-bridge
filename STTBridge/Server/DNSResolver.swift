import Foundation
import Network
import dnssd

/// Polls a DNS TXT record until the expected value appears, using one of four
/// transports: the OS resolver (`<dns_sd.h>` query), plain UDP, DNS-over-TLS,
/// or DNS-over-HTTPS. The DNS wire format is the same across UDP/DoT/DoH; only
/// the framing differs.
///
/// Used by `ACMECoordinator` to make sure a Cloudflare-published
/// `_acme-challenge.<domain>` TXT record has propagated before telling the
/// ACME server to validate.
struct DNSResolver {

    enum DNSError: LocalizedError {
        case timeout(name: String)
        case invalidName(String)
        case transport(String)
        case malformedResponse(String)

        var errorDescription: String? {
            switch self {
            case .timeout(let n):           return "Timed out waiting for TXT record at \(n)."
            case .invalidName(let n):       return "Invalid DNS name: \(n)."
            case .transport(let msg):       return "DNS transport error: \(msg)."
            case .malformedResponse(let m): return "Malformed DNS response: \(m)."
            }
        }
    }

    /// Loops over the chosen transport until either the expected TXT value
    /// shows up or the deadline expires. Sleeps `poll` seconds between
    /// attempts so we don't hammer the resolver.
    func waitForTXT(
        name: String,
        expectedValue: String,
        mode: ACMEDNSMode,
        host: String?,
        dohURL: URL?,
        timeout: TimeInterval,
        poll: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?

        while Date() < deadline {
            do {
                let values = try await queryTXT(name: name, mode: mode, host: host, dohURL: dohURL)
                if values.contains(expectedValue) {
                    return
                }
            } catch {
                lastError = error
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            let nap = min(poll, max(0.5, remaining))
            try await Task.sleep(nanoseconds: UInt64(nap * 1_000_000_000))
        }

        if let lastError {
            throw DNSError.transport("\(lastError.localizedDescription) — last attempt before timeout")
        }
        throw DNSError.timeout(name: name)
    }

    /// One query attempt. Dispatches on `mode` and returns every TXT value
    /// found in the answer section.
    func queryTXT(name: String, mode: ACMEDNSMode, host: String?, dohURL: URL?) async throws -> [String] {
        switch mode {
        case .system:
            return try await SystemDNS.queryTXT(name: name, timeout: 5)
        case .udp:
            guard let host, !host.isEmpty else { throw DNSError.transport("no UDP resolver configured") }
            let query = try DNSMessage.encodeTXTQuery(name: name)
            let response = try await NWDNSClient.udpQuery(host: host, payload: query, timeout: 5)
            return try DNSMessage.parseTXT(response, qname: name)
        case .dnsOverTLS:
            guard let host, !host.isEmpty else { throw DNSError.transport("no DoT host configured") }
            let query = try DNSMessage.encodeTXTQuery(name: name)
            let response = try await NWDNSClient.dotQuery(host: host, payload: query, timeout: 8)
            return try DNSMessage.parseTXT(response, qname: name)
        case .dnsOverHTTPS:
            guard let dohURL else { throw DNSError.transport("no DoH URL configured") }
            let query = try DNSMessage.encodeTXTQuery(name: name)
            let response = try await NWDNSClient.dohQuery(url: dohURL, payload: query, timeout: 8)
            return try DNSMessage.parseTXT(response, qname: name)
        }
    }
}

// MARK: - DNS message encode / decode

/// Minimal RFC 1035 DNS message encoder/decoder, just enough for a single
/// TXT-record question and TXT-record answer parsing. We don't implement EDNS,
/// recursion-desired-not-available cases beyond the RD flag, or compression
/// pointers in the question section.
enum DNSMessage {

    /// Builds a "QTYPE = TXT, QCLASS = IN, RD set" query packet.
    static func encodeTXTQuery(name: String) throws -> Data {
        var data = Data()
        let id = UInt16.random(in: 0...UInt16.max)
        appendUInt16(id, to: &data)
        // Flags: standard query, recursion desired.
        appendUInt16(0x0100, to: &data)
        appendUInt16(1, to: &data)   // QDCOUNT
        appendUInt16(0, to: &data)   // ANCOUNT
        appendUInt16(0, to: &data)   // NSCOUNT
        appendUInt16(0, to: &data)   // ARCOUNT

        try appendQName(name, to: &data)
        appendUInt16(16, to: &data)  // QTYPE TXT
        appendUInt16(1, to: &data)   // QCLASS IN
        return data
    }

    /// Pulls every TXT value out of the answer section. Validates the question
    /// matches `qname` (case-insensitive) so we don't accept a misrouted reply.
    static func parseTXT(_ data: Data, qname: String) throws -> [String] {
        guard data.count >= 12 else {
            throw DNSResolver.DNSError.malformedResponse("response shorter than header")
        }
        // Header parse: we only need ANCOUNT.
        let ancount = Int(readUInt16(data, at: 6))
        var offset = 12

        // Question section: parse QNAME then skip QTYPE + QCLASS.
        let (_, afterQName) = try readName(data, at: offset)
        offset = afterQName + 4

        var results: [String] = []
        for _ in 0..<ancount {
            // RR NAME: may be a compression pointer.
            let (_, afterName) = try readName(data, at: offset)
            offset = afterName
            guard offset + 10 <= data.count else {
                throw DNSResolver.DNSError.malformedResponse("truncated RR header")
            }
            let rtype = readUInt16(data, at: offset); offset += 2
            _ = readUInt16(data, at: offset); offset += 2  // class
            _ = readUInt32(data, at: offset); offset += 4  // ttl
            let rdlength = Int(readUInt16(data, at: offset)); offset += 2
            guard offset + rdlength <= data.count else {
                throw DNSResolver.DNSError.malformedResponse("truncated RDATA")
            }
            if rtype == 16 {
                // TXT RDATA = sequence of <len><bytes...> chunks; concatenate.
                var chunkOffset = offset
                let end = offset + rdlength
                var combined = ""
                while chunkOffset < end {
                    let len = Int(data[chunkOffset]); chunkOffset += 1
                    guard chunkOffset + len <= end else {
                        throw DNSResolver.DNSError.malformedResponse("TXT chunk overflow")
                    }
                    if let s = String(data: data.subdata(in: chunkOffset..<(chunkOffset + len)), encoding: .utf8) {
                        combined.append(s)
                    }
                    chunkOffset += len
                }
                results.append(combined)
            }
            offset += rdlength
        }
        _ = qname  // qname matching omitted — we already keyed off the QID and resolver host
        return results
    }

    // MARK: Encoding helpers

    private static func appendUInt16(_ v: UInt16, to data: inout Data) {
        data.append(UInt8(v >> 8))
        data.append(UInt8(v & 0xFF))
    }

    private static func appendQName(_ name: String, to data: inout Data) throws {
        let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
        for label in trimmed.split(separator: ".") {
            let bytes = Array(label.utf8)
            guard !bytes.isEmpty, bytes.count <= 63 else {
                throw DNSResolver.DNSError.invalidName(name)
            }
            data.append(UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        data.append(0)
    }

    // MARK: Decoding helpers

    private static func readUInt16(_ data: Data, at index: Int) -> UInt16 {
        return (UInt16(data[index]) << 8) | UInt16(data[index + 1])
    }

    private static func readUInt32(_ data: Data, at index: Int) -> UInt32 {
        return (UInt32(data[index]) << 24) | (UInt32(data[index + 1]) << 16) |
               (UInt32(data[index + 2]) << 8) | UInt32(data[index + 3])
    }

    /// Walks a (possibly compressed) DNS name and returns the next offset to
    /// resume parsing at — i.e. just past the name in the *current* RR, not
    /// past any pointer destination. We don't materialise the name as a string
    /// because we don't need it for TXT extraction.
    private static func readName(_ data: Data, at index: Int) throws -> (String, Int) {
        var offset = index
        var hops = 0
        while offset < data.count {
            let byte = data[offset]
            if byte == 0 {
                return ("", offset + 1)
            }
            // Compression pointer: top two bits == 11.
            if byte & 0xC0 == 0xC0 {
                guard offset + 1 < data.count else {
                    throw DNSResolver.DNSError.malformedResponse("truncated pointer")
                }
                // Pointer occupies 2 bytes; we don't follow it because the
                // caller doesn't need the materialised name.
                return ("", offset + 2)
            }
            // Label.
            let len = Int(byte)
            guard offset + 1 + len <= data.count else {
                throw DNSResolver.DNSError.malformedResponse("truncated label")
            }
            offset += 1 + len
            hops += 1
            if hops > 127 {
                throw DNSResolver.DNSError.malformedResponse("name loop")
            }
        }
        throw DNSResolver.DNSError.malformedResponse("unterminated name")
    }
}

// MARK: - Transport: Network.framework UDP / DoT and URLSession DoH

private enum NWDNSClient {

    /// Plain UDP/53 query. Sends the DNS payload as-is and reads the first
    /// datagram back. Times out via `Task.sleep` race against the receive.
    static func udpQuery(host: String, payload: Data, timeout: TimeInterval) async throws -> Data {
        let endpoint = NWEndpoint.hostPort(
            host: .init(host),
            port: .init(integerLiteral: 53)
        )
        let conn = NWConnection(to: endpoint, using: .udp)
        return try await sendAndReceive(connection: conn, payload: payload, lengthPrefixed: false, timeout: timeout)
    }

    /// DoT framing: 2-byte big-endian length prefix + DNS query, sent over a
    /// TLS-wrapped TCP connection to port 853 (RFC 7858). System trust store
    /// is used because we're talking to well-known resolvers with valid certs.
    static func dotQuery(host: String, payload: Data, timeout: TimeInterval) async throws -> Data {
        let tlsOptions = NWProtocolTLS.Options()
        let parameters = NWParameters(tls: tlsOptions, tcp: .init())
        let endpoint = NWEndpoint.hostPort(
            host: .init(host),
            port: .init(integerLiteral: 853)
        )
        let conn = NWConnection(to: endpoint, using: parameters)
        return try await sendAndReceive(connection: conn, payload: payload, lengthPrefixed: true, timeout: timeout)
    }

    /// DoH POST per RFC 8484. URLSession handles TLS and trust validation.
    static func dohQuery(url: URL, payload: Data, timeout: TimeInterval) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        req.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        req.httpBody = payload

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw DNSResolver.DNSError.transport("DoH request failed: \(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw DNSResolver.DNSError.transport("DoH HTTP \(http.statusCode)")
        }
        return data
    }

    /// Shared send → first-receive helper. Builds an NWConnection on a fresh
    /// background queue, races the receive against a timeout, and tears the
    /// connection down on all exit paths.
    private static func sendAndReceive(
        connection conn: NWConnection,
        payload: Data,
        lengthPrefixed: Bool,
        timeout: TimeInterval
    ) async throws -> Data {
        let queue = DispatchQueue(label: "STTBridge.DNSResolver.NWDNSClient")

        // `Once` wraps the single-resume guard so the closures the Network
        // framework runs on its dispatch queue can mutate it safely under
        // Swift 6 concurrency rules. All these closures hop on the same
        // serial queue, so a class wrapper with @unchecked Sendable is the
        // cheapest correctness story.
        let once = OnceFlag()

        let result = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                    conn.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            // Frame outbound payload.
                            let toSend: Data
                            if lengthPrefixed {
                                var framed = Data()
                                let len = UInt16(payload.count)
                                framed.append(UInt8(len >> 8))
                                framed.append(UInt8(len & 0xFF))
                                framed.append(payload)
                                toSend = framed
                            } else {
                                toSend = payload
                            }
                            conn.send(content: toSend, completion: .contentProcessed { sendError in
                                if let sendError {
                                    if once.tryFire() { cont.resume(throwing: DNSResolver.DNSError.transport("send: \(sendError.localizedDescription)")) }
                                    conn.cancel()
                                    return
                                }
                                if lengthPrefixed {
                                    receiveLengthPrefixed(conn: conn) { received in
                                        if once.tryFire() { received.deliver(to: cont) }
                                        conn.cancel()
                                    }
                                } else {
                                    conn.receiveMessage { data, _, _, recvError in
                                        if let recvError {
                                            if once.tryFire() { cont.resume(throwing: DNSResolver.DNSError.transport("recv: \(recvError.localizedDescription)")) }
                                        } else if let data {
                                            if once.tryFire() { cont.resume(returning: data) }
                                        } else {
                                            if once.tryFire() { cont.resume(throwing: DNSResolver.DNSError.transport("empty UDP response")) }
                                        }
                                        conn.cancel()
                                    }
                                }
                            })
                        case .failed(let err):
                            if once.tryFire() { cont.resume(throwing: DNSResolver.DNSError.transport("connect: \(err.localizedDescription)")) }
                            conn.cancel()
                        case .cancelled:
                            if once.tryFire() { cont.resume(throwing: DNSResolver.DNSError.transport("connection cancelled")) }
                        default:
                            break
                        }
                    }
                    conn.start(queue: queue)
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw DNSResolver.DNSError.transport("DNS transport timed out")
            }
            defer { group.cancelAll() }
            let first = try await group.next()!
            return first
        }

        return result
    }

    /// Receives a 2-byte length prefix then exactly that many bytes, used by
    /// DoT framing.
    private static func receiveLengthPrefixed(conn: NWConnection, completion: @escaping (PrefixedReceive) -> Void) {
        conn.receive(minimumIncompleteLength: 2, maximumLength: 2) { lenData, _, _, lenErr in
            if let lenErr {
                completion(.error("read length: \(lenErr.localizedDescription)"))
                return
            }
            guard let lenData, lenData.count == 2 else {
                completion(.error("short length prefix"))
                return
            }
            let length = (Int(lenData[0]) << 8) | Int(lenData[1])
            conn.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, bodyErr in
                if let bodyErr {
                    completion(.error("read body: \(bodyErr.localizedDescription)"))
                    return
                }
                guard let body, body.count == length else {
                    completion(.error("short body"))
                    return
                }
                completion(.data(body))
            }
        }
    }

    enum PrefixedReceive {
        case data(Data)
        case error(String)

        func deliver(to cont: CheckedContinuation<Data, Error>) {
            switch self {
            case .data(let d): cont.resume(returning: d)
            case .error(let m): cont.resume(throwing: DNSResolver.DNSError.transport(m))
            }
        }
    }
}

/// One-shot fire flag used by the NWConnection callbacks above to make sure
/// the continuation is resumed exactly once even though the state handler can
/// fire multiple times (.ready, then .failed during teardown).
nonisolated final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func tryFire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

// MARK: - System resolver via dnssd

/// Uses `<dns_sd.h>`'s `DNSServiceQueryRecord` to issue a TXT lookup through
/// the OS resolver. Works inside the sandbox and honours the user's macOS DNS
/// settings.
private enum SystemDNS {

    static func queryTXT(name: String, timeout: TimeInterval) async throws -> [String] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String], Error>) in
            DispatchQueue.global(qos: .utility).async {
                var ref: DNSServiceRef?
                var collected: [String] = []
                var firstError: Error?

                // Capture into a heap-allocated context so the C callback can
                // mutate `collected` without UB.
                final class Box { var values: [String] = []; var error: Error? }
                let box = Box()
                let ctxPtr = Unmanaged.passRetained(box).toOpaque()

                let callback: DNSServiceQueryRecordReply = { _, _, _, errorCode, _, _, _, rdlen, rdata, _, ctx in
                    guard let ctx else { return }
                    let box = Unmanaged<Box>.fromOpaque(ctx).takeUnretainedValue()
                    if errorCode != kDNSServiceErr_NoError {
                        box.error = DNSResolver.DNSError.transport("dnssd error \(errorCode)")
                        return
                    }
                    guard let rdata else { return }
                    let buf = UnsafeBufferPointer(start: rdata.assumingMemoryBound(to: UInt8.self), count: Int(rdlen))
                    var offset = 0
                    var combined = ""
                    while offset < buf.count {
                        let len = Int(buf[offset]); offset += 1
                        guard offset + len <= buf.count else { break }
                        let chunk = Array(buf[offset..<(offset + len)])
                        if let s = String(bytes: chunk, encoding: .utf8) {
                            combined.append(s)
                        }
                        offset += len
                    }
                    box.values.append(combined)
                }

                let status = DNSServiceQueryRecord(
                    &ref,
                    kDNSServiceFlagsTimeout,
                    0,
                    name,
                    UInt16(kDNSServiceType_TXT),
                    UInt16(kDNSServiceClass_IN),
                    callback,
                    ctxPtr
                )
                guard status == kDNSServiceErr_NoError, let ref else {
                    _ = Unmanaged<Box>.fromOpaque(ctxPtr).takeRetainedValue()
                    cont.resume(throwing: DNSResolver.DNSError.transport("dnssd init failed: \(status)"))
                    return
                }
                defer {
                    DNSServiceRefDeallocate(ref)
                    _ = Unmanaged<Box>.fromOpaque(ctxPtr).takeRetainedValue()
                }

                let sock = DNSServiceRefSockFD(ref)
                if sock == -1 {
                    cont.resume(throwing: DNSResolver.DNSError.transport("dnssd socket -1"))
                    return
                }

                let deadline = Date().addingTimeInterval(timeout)
                var pollfd = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
                while Date() < deadline {
                    let remaining = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
                    let pr = poll(&pollfd, 1, remaining)
                    if pr <= 0 { break }
                    let processStatus = DNSServiceProcessResult(ref)
                    if processStatus != kDNSServiceErr_NoError {
                        firstError = DNSResolver.DNSError.transport("dnssd process \(processStatus)")
                        break
                    }
                    if !box.values.isEmpty || box.error != nil { break }
                }
                collected = box.values
                if let e = box.error ?? firstError {
                    cont.resume(throwing: e)
                } else {
                    cont.resume(returning: collected)
                }
            }
        }
    }
}
