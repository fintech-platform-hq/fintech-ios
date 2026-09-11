import Foundation
import Observation

@MainActor
@Observable
final class AuthenticationViewModel {
    var email = ""
    var password = ""
    private(set) var state: AuthenticationViewState = .restoring

    private let session: AuthenticationSession

    init(session: AuthenticationSession) {
        self.session = session
    }

    func restore() async {
        do {
            state = try await session.restore() ? .authenticated : .unauthenticated
        } catch let error as AuthenticationError {
            state = .failure(Self.displayError(for: error))
        } catch {
            state = .failure(.unexpected)
        }
    }

    func login() async {
        let credentials = self.credentials
        let session = self.session
        await authenticate { try await session.login(credentials) }
    }

    func register() async {
        let credentials = self.credentials
        let session = self.session
        await authenticate { try await session.register(credentials) }
    }

    func logout() async {
        await session.logout()
        password = ""
        state = .unauthenticated
    }

    private var credentials: AuthenticationCredentials {
        AuthenticationCredentials(
            email: email.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password
        )
    }

    private func authenticate(
        _ operation: @escaping @Sendable () async throws -> Void
    ) async {
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !password.isEmpty else {
            state = .failure(.invalidCredentials)
            return
        }

        state = .authenticating
        do {
            try await operation()
            password = ""
            state = .authenticated
        } catch is CancellationError {
            state = .failure(.unexpected)
        } catch let error as AuthenticationError {
            state = .failure(Self.displayError(for: error))
        } catch {
            state = .failure(.unexpected)
        }
    }

    private static func displayError(
        for error: AuthenticationError
    ) -> AuthenticationDisplayError {
        switch error {
        case .unauthenticated:
            .invalidCredentials
        case .request(let apiError):
            switch apiError {
            case .unauthorized, .badRequest:
                .invalidCredentials
            default:
                .unexpected
            }
        case .refreshFailed:
            .sessionExpired
        case .credentialsUnavailable:
            .unavailable
        case .invalidTokenResponse:
            .unexpected
        }
    }
}
