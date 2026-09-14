import Foundation
import Observation
import AuthenticationServices

@MainActor
@Observable
final class AuthenticationViewModel {
    var email = ""
    var password = ""
    private(set) var state: AuthenticationViewState = .restoring
    private(set) var appleOperationID: UUID

    private let session: AuthenticationSession
    private let appleProvider: any AppleAuthorizationProviding
    private var appleTask: Task<Void, Never>?

    init(
        session: AuthenticationSession,
        appleProvider: any AppleAuthorizationProviding
    ) {
        self.session = session
        self.appleProvider = appleProvider
        appleOperationID = appleProvider.operationID
    }

    func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest, operationID: UUID) {
        guard operationID == appleProvider.operationID, state != .authenticating else { return }
        do {
            try appleProvider.configure(request)
            state = .authenticating
            appleTask = Task { @MainActor in
                await signInWithApple()
                appleOperationID = appleProvider.operationID
                appleTask = nil
            }
        } catch let error as AuthenticationError {
            state = .failure(Self.displayError(for: error))
        } catch {
            state = .failure(.unexpected)
        }
    }

    func signInWithApple() async {
        state = .authenticating
        let authorization: AppleAuthorizationResult
        do {
            authorization = try await appleProvider.authorization()
            try Task.checkCancellation()
        } catch is CancellationError {
            state = .unauthenticated
            return
        } catch let error as ASAuthorizationError where error.code == .canceled {
            state = .unauthenticated
            return
        } catch {
            state = .failure(.unexpected)
            return
        }

        // After the POST starts, cancellation cannot establish whether the code was consumed.
        do {
            try await session.signInWithApple(authorization)
            password = ""
            state = .authenticated
        } catch let error as AuthenticationError {
            state = .failure(Self.displayError(for: error))
        } catch {
            state = .failure(.unexpected)
        }
    }

    func completeAppleAuthorization(_ result: Result<ASAuthorization, Error>, operationID: UUID) {
        appleProvider.complete(result, operationID: operationID)
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

    func observeSession() async {
        for await event in await session.events() {
            switch event {
            case let .reauthenticationRequired(generation):
                if await session.requiresReauthentication(for: generation) {
                    state = .failure(.sessionExpired)
                }
            }
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
        case .refreshUnavailable:
            .unavailable
        case .reauthenticationRequired:
            .sessionExpired
        case .credentialsUnavailable:
            .unavailable
        case .invalidTokenResponse, .operationInProgress:
            .unexpected
        }
    }
}
