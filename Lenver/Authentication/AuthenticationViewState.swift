import Foundation

nonisolated enum AuthenticationViewState: Equatable, Sendable {
    case restoring
    case unauthenticated
    case authenticating
    case authenticated
    case failure(AuthenticationDisplayError)
}

nonisolated enum AppleLinkState: Equatable, Sendable {
    case none
    case passwordRequired
    case offer(AppleLinkSession)
    case authorizing(AppleLinkSession)
    case review(AppleLinkSession)
    case submitting(AppleLinkSession)
    case success(AppleLinkSession)
    case failure(AppleLinkSession, AppleLinkDisplayError)

    var session: AppleLinkSession? {
        switch self {
        case let .offer(session), let .authorizing(session), let .review(session), let .submitting(session),
             let .success(session), let .failure(session, _): session
        case .none, .passwordRequired: nil
        }
    }
}

nonisolated enum AppleLinkDisplayError: Equatable, Sendable {
    case notConfirmed
    case passwordRequired
    case conflict
    case tooManyAttempts(retryAfter: Int?)
    case unavailable

    var message: LocalizedStringResource {
        switch self {
        case .notConfirmed: "The Apple link result is unknown. Keep using your password and do not repeat this request yet."
        case .passwordRequired: "Confirm your Lenver password before retrying the Apple link."
        case .conflict: "This Apple Account cannot be linked to this Lenver account."
        case let .tooManyAttempts(retryAfter):
            if let retryAfter {
                "Too many Apple link attempts. Try again in \(retryAfter) seconds."
            } else {
                "Too many Apple link attempts. Wait before trying again."
            }
        case .unavailable: "The Apple link result could not be confirmed. Keep using your password and do not repeat this request yet."
        }
    }
}

nonisolated enum AuthenticationDisplayError: Error, Equatable, Sendable {
    case invalidEmail
    case invalidNewPassword
    case invalidCredentials
    case registrationRejected
    case signInUnavailable
    case registrationUnavailable
    case rateLimited(isRegistration: Bool, retryAfter: Int?)
    case sessionExpired
    case unavailable
    case unexpected

    var message: LocalizedStringResource {
        switch self {
        case .invalidEmail:
            "Enter a valid email address."
        case .invalidNewPassword:
            "Use a password between 12 and 128 characters."
        case .invalidCredentials:
            "Check your email and password."
        case .registrationRejected:
            "Your account could not be created. Check your details and try again."
        case .signInUnavailable:
            "Sign in could not be completed. Check your connection and try again."
        case .registrationUnavailable:
            "Account creation could not be completed. Check your connection and try again."
        case let .rateLimited(isRegistration, retryAfter):
            if let retryAfter {
                isRegistration
                    ? "Too many registration attempts. Try again in \(retryAfter) seconds."
                    : "Too many sign-in attempts. Try again in \(retryAfter) seconds."
            } else {
                isRegistration
                    ? "Too many registration attempts. Wait a little before trying again."
                    : "Too many sign-in attempts. Wait a little before trying again."
            }
        case .sessionExpired:
            "Your session expired. Sign in again."
        case .unavailable:
            "Authentication is temporarily unavailable."
        case .unexpected:
            "Authentication could not be completed."
        }
    }
}
