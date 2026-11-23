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
    private(set) var linkingState: AppleLinkState = .none

    var shouldOfferAppleLink: Bool { linkingState.session != nil || (linkingState == .passwordRequired && state == .authenticated) }
    var operationInProgress: Bool { activeOperationID != nil }
    var canStartApple: Bool {
        guard !operationInProgress else { return false }
        switch linkingState {
        case .none: return state != .authenticated && state != .restoring
        case .offer, .failure(_, .notConfirmed), .failure(_, .conflict),
             .failure(_, .tooManyAttempts), .failure(_, .unavailable): return state == .authenticated
        default: return false
        }
    }

    private enum ApplePurpose {
        case signIn
        case link(AppleLinkSession)
        var isSignIn: Bool {
            if case .signIn = self { return true }
            return false
        }
    }
    private let session: AuthenticationSession
    private let appleProvider: any AppleAuthorizationProviding
    private var appleTask: Task<Void, Never>?
    private var activeOperationID: UUID?

    init(session: AuthenticationSession, appleProvider: any AppleAuthorizationProviding) {
        self.session = session
        self.appleProvider = appleProvider
        appleOperationID = appleProvider.operationID
    }

    private func beginApple(operationID: UUID) -> ApplePurpose? {
        guard activeOperationID == nil, linkingState != .passwordRequired,
              operationID == appleProvider.operationID else { return nil }
        let purpose: ApplePurpose
        if let linkSession = linkingState.session {
            guard canStartApple else { return nil }
            purpose = .link(linkSession)
            linkingState = .authorizing(linkSession)
        } else {
            guard state != .authenticated else { return nil }
            purpose = .signIn
            state = .authenticating
        }
        activeOperationID = operationID
        return purpose
    }

    func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest, operationID: UUID) {
        guard let purpose = beginApple(operationID: operationID) else { return }
        do {
            try appleProvider.configure(request)
            appleTask = Task { await performApple(purpose: purpose, operationID: operationID) }
        } catch {
            applyAppleError(error, purpose: purpose, afterPOST: false)
            finish(operationID)
        }
    }

    func signInWithApple() async {
        let operationID = appleProvider.operationID
        guard let purpose = beginApple(operationID: operationID) else { return }
        let task = Task { await performApple(purpose: purpose, operationID: operationID) }
        appleTask = task
        await task.value
    }

    private func performApple(purpose: ApplePurpose, operationID: UUID) async {
        defer { finish(operationID) }
        let generation: Int
        switch purpose {
        case .signIn: generation = await session.currentGeneration()
        case let .link(linkSession): generation = linkSession.generation
        }
        guard await isCurrent(operationID, generation: generation) else { return }
        var afterPOST = false
        do {
            let authorization = try await appleProvider.authorization()
            guard await isCurrent(operationID, generation: generation) else { return }
            try Task.checkCancellation()
            switch purpose {
            case .signIn:
                afterPOST = true
                try await session.signInWithApple(authorization, expectedGeneration: generation)
                guard await isCurrent(operationID, generation: generation + 1) else { return }
                password = ""
                state = .authenticated
            case let .link(linkSession):
                linkingState = .submitting(linkSession)
                afterPOST = true
                try await session.linkApple(authorization, session: linkSession, operationID: operationID)
                guard await isCurrent(operationID, generation: generation) else { return }
                linkingState = .success(linkSession)
            }
        } catch {
            // Apple sign-in increments generation before HTTP; linking never does.
            let expectedGeneration = afterPOST && purpose.isSignIn ? generation + 1 : generation
            guard await isCurrent(operationID, generation: expectedGeneration) else { return }
            applyAppleError(error, purpose: purpose, afterPOST: afterPOST)
        }
    }

    private func isCurrent(_ operationID: UUID, generation: Int) async -> Bool {
        let current = await session.isCurrent(generation)
        guard activeOperationID == operationID else { return false }
        guard current else {
            abandonApple()
            linkingState = .none
            let authenticated = (try? await session.restore()) == true
            guard activeOperationID == nil else { return false }
            state = authenticated ? .authenticated : .unauthenticated
            return false
        }
        return true
    }

    private func applyAppleError(_ error: Error, purpose: ApplePurpose, afterPOST: Bool) {
        switch purpose {
        case .signIn:
            if !afterPOST, Self.isAppleCancellation(error) {
                state = .unauthenticated
            } else if error as? AuthenticationError == .accountLinkRequired {
                linkingState = .passwordRequired
                state = .unauthenticated
            } else {
                state = .failure(Self.displayError(for: error))
            }
        case let .link(linkSession):
            if !afterPOST, Self.isAppleCancellation(error) {
                linkingState = .offer(linkSession)
            } else {
                linkingState = .failure(linkSession, Self.linkError(for: error))
            }
        }
    }

    private static func isAppleCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? ASAuthorizationError)?.code == .canceled
    }

    private static func linkError(for error: Error) -> AppleLinkDisplayError {
        guard case let AuthenticationError.request(apiError) = error else { return .notConfirmed }
        switch apiError {
        case .http(statusCode: 403, message: _): return .passwordRequired
        case .idempotencyConflict: return .conflict
        case .http(statusCode: 429, message: _): return .tooManyAttempts
        case .server(statusCode: 503, message: _): return .unavailable
        default: return .notConfirmed
        }
    }

    func completeAppleAuthorization(_ result: Result<ASAuthorization, Error>, operationID: UUID) {
        guard activeOperationID == operationID else { return }
        appleProvider.complete(result, operationID: operationID)
    }

    private func finish(_ operationID: UUID) {
        guard activeOperationID == operationID else { return }
        activeOperationID = nil
        appleTask = nil
        appleOperationID = appleProvider.operationID
    }

    private func abandonApple() {
        if let operationID = activeOperationID { appleProvider.cancel(operationID: operationID) }
        activeOperationID = nil
        appleTask?.cancel()
        appleTask = nil
        appleOperationID = appleProvider.operationID
    }

    func dismissAppleLinkOffer() {
        // Abandon Apple work, but keep an already-started password login tracked.
        if appleTask != nil { abandonApple() }
        linkingState = .none
    }

    func requirePasswordForLink() {
        guard activeOperationID == nil,
              case .failure(_, .passwordRequired) = linkingState else { return }
        linkingState = .passwordRequired
        password = ""
    }

    func restore() async {
        guard activeOperationID == nil else { return }
        do { state = try await session.restore() ? .authenticated : .unauthenticated }
        catch { state = .failure(Self.displayError(for: error)) }
    }

    func observeSession() async {
        for await event in await session.events() {
            switch event {
            case let .reauthenticationRequired(generation):
                if await session.requiresReauthentication(for: generation) {
                    abandonApple()
                    linkingState = .none
                    state = .failure(.sessionExpired)
                }
            }
        }
    }

    func login() async { await authenticate(registering: false) }
    func register() async { await authenticate(registering: true) }

    func logout() async {
        abandonApple()
        linkingState = .none
        let operationID = UUID()
        activeOperationID = operationID
        state = .unauthenticated
        await session.logout()
        guard activeOperationID == operationID else { return }
        password = ""
        state = .unauthenticated
        finish(operationID)
    }

    private func authenticate(registering: Bool) async {
        guard activeOperationID == nil, linkingState.session == nil,
              !(registering && linkingState == .passwordRequired) else { return }
        let credentials = AuthenticationCredentials(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
        guard !credentials.email.isEmpty, !credentials.password.isEmpty else {
            state = .failure(.invalidCredentials)
            return
        }
        let operationID = UUID()
        let passwordRequired = linkingState == .passwordRequired
        let wasAuthenticated = state == .authenticated
        activeOperationID = operationID
        defer { finish(operationID) }
        if !wasAuthenticated { state = .authenticating }
        do {
            if registering { try await session.register(credentials) }
            else { try await session.login(credentials) }
            guard activeOperationID == operationID else { return }
            password = ""
            state = .authenticated
            if passwordRequired, linkingState == .passwordRequired {
                let linkSession = try await session.appleLinkSession()
                guard activeOperationID == operationID, linkingState == .passwordRequired else { return }
                linkingState = .offer(linkSession)
            }
        } catch {
            guard activeOperationID == operationID else { return }
            state = .failure(Self.displayError(for: error))
        }
    }

    private static func displayError(for error: Error) -> AuthenticationDisplayError {
        guard let error = error as? AuthenticationError else { return .unexpected }
        switch error {
        case .unauthenticated: return .invalidCredentials
        case .request(.unauthorized), .request(.badRequest): return .invalidCredentials
        case .refreshFailed, .reauthenticationRequired: return .sessionExpired
        case .refreshUnavailable, .credentialsUnavailable: return .unavailable
        default: return .unexpected
        }
    }
}
