import Foundation

nonisolated enum APIError: Error, Equatable, Sendable {
    case encoding
    case transport(code: URLError.Code)
    case invalidResponse
    case decoding
    case unauthorized(messages: [String])
    case badRequest(messages: [String])
    case idempotencyConflict(message: String?)
    case server(statusCode: Int, message: String?)
    case http(statusCode: Int, message: String?)
}

extension APIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .encoding:
            "The request could not be encoded."
        case let .transport(code):
            "The request failed because of a network error (\(code.rawValue))."
        case .invalidResponse:
            "The server returned an invalid response."
        case .decoding:
            "The server response could not be decoded."
        case let .unauthorized(messages):
            messages.first ?? "Authentication is required."
        case let .badRequest(messages):
            messages.first ?? "The transaction request was rejected."
        case let .idempotencyConflict(message):
            message ?? "The idempotency key conflicts with an earlier transaction request."
        case let .server(statusCode, message):
            message ?? "The server failed to process the request (HTTP \(statusCode))."
        case let .http(statusCode, message):
            message ?? "The request failed with HTTP status \(statusCode)."
        }
    }
}
