import Foundation

nonisolated enum AuthenticationViewState: Equatable, Sendable {
    case restoring
    case unauthenticated
    case authenticating
    case authenticated
    case failure(AuthenticationDisplayError)
}

nonisolated enum AuthenticationDisplayError: Error, Equatable, Sendable {
    case invalidCredentials
    case sessionExpired
    case unavailable
    case unexpected

    var message: String {
        switch self {
        case .invalidCredentials:
            "Check your email and password."
        case .sessionExpired:
            "Your session expired. Sign in again."
        case .unavailable:
            "Authentication is temporarily unavailable."
        case .unexpected:
            "Authentication could not be completed."
        }
    }
}
