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
    case submitting(AppleLinkSession)
    case success(AppleLinkSession)
    case failure(AppleLinkSession, AppleLinkDisplayError)

    var session: AppleLinkSession? {
        switch self {
        case let .offer(session), let .authorizing(session), let .submitting(session),
             let .success(session), let .failure(session, _): session
        case .none, .passwordRequired: nil
        }
    }
}

nonisolated enum AppleLinkDisplayError: Equatable, Sendable {
    case notConfirmed
    case passwordRequired
    case conflict
    case tooManyAttempts
    case unavailable

    var message: String {
        switch self {
        case .notConfirmed: "O vínculo não pôde ser confirmado. Uma nova tentativa exige uma nova autorização Apple. Sua sessão Lenver foi preservada."
        case .passwordRequired: "Entre novamente com email e senha antes de tentar vincular. Sua sessão Lenver foi preservada."
        case .conflict: "Há um conflito de vínculo. Nenhuma conta será mesclada."
        case .tooManyAttempts: "Excesso de tentativas. Aguarde antes de iniciar uma nova autorização Apple."
        case .unavailable: "O vínculo está temporariamente indisponível. Tente mais tarde com uma nova autorização Apple."
        }
    }
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
