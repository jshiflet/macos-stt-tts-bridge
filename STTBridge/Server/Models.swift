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

struct SayPayload: Codable {
    let text: String
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
