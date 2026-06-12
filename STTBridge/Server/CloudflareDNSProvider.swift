import Foundation

/// Thin Cloudflare API v4 client scoped to the calls we need for DNS-01:
/// finding a zone, creating a TXT record, deleting it on cleanup. Reads the
/// scoped API token from the Keychain via `KeychainCloudflareToken`.
///
/// The token must carry `Zone:Read` + `Zone.DNS:Edit` for the zone(s) being
/// validated. The error model surfaces the Cloudflare-returned messages so a
/// missing or wrong-scoped token shows up in the ACME tab status line instead
/// of a cryptic HTTP code.
struct CloudflareDNSProvider {
    private static let baseURL = URL(string: "https://api.cloudflare.com/client/v4")!

    enum CloudflareError: LocalizedError, Equatable {
        case missingToken
        case unauthorized
        case forbidden
        case zoneNotFound
        case apiError(code: Int, message: String)
        case network(String)
        case decode(String)

        var errorDescription: String? {
            switch self {
            case .missingToken:       return "No Cloudflare API token is set."
            case .unauthorized:       return "Cloudflare rejected the API token (unauthorized)."
            case .forbidden:          return "Cloudflare token lacks the required Zone:Read / DNS:Edit scopes."
            case .zoneNotFound:       return "No matching Cloudflare zone for the requested domain."
            case .apiError(let c, let m): return "Cloudflare API error \(c): \(m)"
            case .network(let m):     return "Network error talking to Cloudflare: \(m)"
            case .decode(let m):      return "Could not decode Cloudflare response: \(m)"
            }
        }
    }

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public API

    /// Walks the supplied domain label by label until it finds a Cloudflare
    /// zone that covers it. `sub.example.com` first tries `sub.example.com`,
    /// then `example.com`. Returns the matching zone ID or throws `zoneNotFound`.
    func findZoneID(coveringDomain domain: String) async throws -> String {
        let base = domain.hasPrefix("*.") ? String(domain.dropFirst(2)) : domain
        let labels = base.split(separator: ".")
        guard labels.count >= 2 else { throw CloudflareError.zoneNotFound }

        var attempts: [String] = []
        for i in 0..<(labels.count - 1) {
            attempts.append(labels[i...].joined(separator: "."))
        }

        for candidate in attempts {
            if let id = try await zoneID(for: candidate) {
                return id
            }
        }
        throw CloudflareError.zoneNotFound
    }

    /// Creates a TXT record. Returns the new record's ID for cleanup later.
    /// TTL defaults to 60s — the minimum Cloudflare accepts while still
    /// shorter than typical caching windows so validation isn't slowed.
    @discardableResult
    func createTXTRecord(zoneID: String, name: String, value: String, ttl: Int = 60) async throws -> String {
        let token = try requireToken()
        let url = Self.baseURL.appendingPathComponent("zones/\(zoneID)/dns_records")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Cloudflare requires TXT content quoted; the API also accepts the raw
        // string and quotes it internally, but explicit quoting is safer.
        let body: [String: Any] = [
            "type": "TXT",
            "name": name,
            "content": "\"\(value)\"",
            "ttl": ttl
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let envelope: CreateTXTResponse = try await call(req)
        guard let result = envelope.result else {
            throw CloudflareError.decode("missing result")
        }
        return result.id
    }

    /// Best-effort delete; failures are returned to the caller but the ACME
    /// coordinator treats them as warnings, not fatal errors.
    func deleteTXTRecord(zoneID: String, recordID: String) async throws {
        let token = try requireToken()
        let url = Self.baseURL.appendingPathComponent("zones/\(zoneID)/dns_records/\(recordID)")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let _: DeleteTXTResponse = try await call(req)
    }

    // MARK: - Internals

    private func requireToken() throws -> String {
        guard let t = KeychainCloudflareToken.load(), !t.isEmpty else {
            throw CloudflareError.missingToken
        }
        return t
    }

    private func zoneID(for name: String) async throws -> String? {
        let token = try requireToken()
        var comps = URLComponents(url: Self.baseURL.appendingPathComponent("zones"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "name", value: name)]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let envelope: ZoneListResponse = try await call(req)
        return envelope.result?.first?.id
    }

    /// Single shared request → decode pipeline. Maps HTTP and Cloudflare error
    /// codes to typed `CloudflareError` cases so callers don't deal with raw
    /// status codes.
    private func call<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CloudflareError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CloudflareError.network("non-HTTP response")
        }

        switch http.statusCode {
        case 401: throw CloudflareError.unauthorized
        case 403: throw CloudflareError.forbidden
        case 404: throw CloudflareError.zoneNotFound
        default: break
        }

        // Cloudflare returns 200 even for application-level failures; inspect
        // the `success` flag and surface the first error message if any.
        do {
            let decoder = JSONDecoder()
            let envelope = try decoder.decode(T.self, from: data)
            if let base = envelope as? CloudflareBaseResponse, base.success == false {
                let msg = base.errors?.first?.message ?? "unknown"
                let code = base.errors?.first?.code ?? -1
                throw CloudflareError.apiError(code: code, message: msg)
            }
            return envelope
        } catch let e as CloudflareError {
            throw e
        } catch {
            throw CloudflareError.decode(error.localizedDescription)
        }
    }
}

// MARK: - Response shapes

/// Common envelope fields every Cloudflare response carries. Concrete response
/// types conform to this so `call()` can do generic success/error handling.
protocol CloudflareBaseResponse {
    var success: Bool { get }
    var errors: [CloudflareAPIError]? { get }
}

struct CloudflareAPIError: Decodable {
    let code: Int
    let message: String
}

struct ZoneListResponse: Decodable, CloudflareBaseResponse {
    struct Zone: Decodable { let id: String; let name: String }
    let success: Bool
    let errors: [CloudflareAPIError]?
    let result: [Zone]?
}

struct CreateTXTResponse: Decodable, CloudflareBaseResponse {
    struct Record: Decodable { let id: String }
    let success: Bool
    let errors: [CloudflareAPIError]?
    let result: Record?
}

struct DeleteTXTResponse: Decodable, CloudflareBaseResponse {
    struct Result: Decodable { let id: String }
    let success: Bool
    let errors: [CloudflareAPIError]?
    let result: Result?
}
