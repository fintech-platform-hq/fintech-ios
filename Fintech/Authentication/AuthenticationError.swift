import Foundation

nonisolated enum AuthenticationError: Error, Equatable, Sendable {
    case unauthenticated
    case invalidTokenResponse
    case credentialsUnavailable
    case refreshFailed
    case request(APIError)
}

extension AuthenticationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unauthenticated:
            "Authentication is required."
        case .invalidTokenResponse:
            "The authentication response was invalid."
        case .credentialsUnavailable:
            "Saved credentials are temporarily unavailable."
        case .refreshFailed:
            "Your session expired. Sign in again."
        case let .request(error):
            error.errorDescription
        }
    }
}

nonisolated enum KeychainError: Error, Equatable, Sendable {
    case itemNotFound
    case interactionNotAllowed
    case invalidData
    case unexpectedStatus(Int32)
}
