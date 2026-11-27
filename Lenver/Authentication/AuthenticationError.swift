import Foundation

nonisolated enum AuthenticationError: Error, Equatable, Sendable {
    case unauthenticated
    case invalidTokenResponse
    case credentialsUnavailable
    case refreshFailed
    case refreshUnavailable
    case reauthenticationRequired
    case operationInProgress
    case accountLinkRequired
    case appleAuthorizationUnavailable
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
        case .refreshUnavailable:
            "Authentication is temporarily unavailable."
        case .reauthenticationRequired:
            "Please sign in again."
        case .operationInProgress:
            "Authentication is already in progress."
        case .accountLinkRequired:
            "An existing account can be linked explicitly after signing in."
        case .appleAuthorizationUnavailable:
            "Sign in with Apple requires a build for this environment."
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
