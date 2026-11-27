import Foundation
import Observation
import AuthenticationServices

@MainActor
@Observable
final class AuthenticationViewModel {
    var email = ""
    var password = ""
    private(set) var state: AuthenticationViewState = .restoring
    private(set) var identityStatus: IdentityStatus?
    private(set) var identityGeneration: Int?
    private(set) var remoteSignOutPending = false
    private(set) var signOutResult: SignOutResult?
    var linkPassword = ""
    var usesIdentityV1: Bool { identityService != nil }
    var appleAuthorizationAvailable: Bool { appleProvider.isAvailable }
    private(set) var authenticationProgress: LocalizedStringResource = "Signing in…"
    private var legacyAppleLinkUnconfirmed = false
    private var pendingMethodGeneration: Int?
    private(set) var pendingMethodIntent: IdentityMethodIntent?
    private(set) var methodRecoveryReady = false
    private(set) var methodChangeInProgress = false
    var appleLinkNeedsReconciliation: Bool {
        legacyAppleLinkUnconfirmed || pendingMethodIntent?.action == .linkApple
    }
    var canChangeMethods: Bool {
        (identityService == nil || identityGeneration != nil) && methodRecoveryReady && pendingMethodIntent == nil && !methodChangeInProgress
    }

    private(set) var appleOperationID: UUID
    private(set) var linkFromSecurity = false
    private(set) var linkingState: AppleLinkState = .none

    var shouldOfferAppleLink: Bool { linkingState.session != nil || (linkingState == .passwordRequired && state == .authenticated) }
    var operationInProgress: Bool { activeOperationID != nil }
    var canStartApple: Bool {
        guard appleAuthorizationAvailable, !operationInProgress else { return false }
        if appleLinkNeedsReconciliation, linkingState.session != nil { return false }
        if usesIdentityV1, linkingState.session != nil, !IdentityValidation.isExistingPassword(linkPassword) { return false }
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
    private let identityService: IdentityService?
    private let methodIntentStore: IdentityMethodIntentStore?
    private let appleProvider: any AppleAuthorizationProviding
    private var pendingAppleLink: (authorization: AppleAuthorizationResult, password: String)?
    private var appleTask: Task<Void, Never>?
    private var identityReadID = UUID()
    private var activeOperationID: UUID?

    init(
        session: AuthenticationSession,
        appleProvider: any AppleAuthorizationProviding,
        identityService: IdentityService? = nil,
        methodIntentStore: IdentityMethodIntentStore? = nil
    ) {
        self.identityService = identityService
        self.methodIntentStore = methodIntentStore
        methodRecoveryReady = methodIntentStore == nil
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
            signOutResult = nil
            remoteSignOutPending = false
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
                await loadIdentity(generation: generation + 1)
                guard await isCurrent(operationID, generation: generation + 1) else { return }
                state = .authenticated
            case let .link(linkSession):
                if usesIdentityV1 {
                    pendingAppleLink = (authorization, linkPassword)
                    linkPassword = ""
                    linkingState = .review(linkSession)
                    return
                }
                linkingState = .submitting(linkSession)
                afterPOST = true
                try await session.linkApple(authorization, session: linkSession, operationID: operationID)
                await loadIdentity(generation: generation)
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

    func confirmAppleLink() async {
        guard activeOperationID == nil, case let .review(linkSession) = linkingState,
              let pendingAppleLink else { return }
        self.pendingAppleLink = nil
        let operationID = UUID()
        activeOperationID = operationID
        defer { finish(operationID) }
        linkingState = .submitting(linkSession)
        do {
            try await changeIdentityMethod(.linkApple, generation: linkSession.generation) { id in
                try await self.session.linkApple(
                    pendingAppleLink.authorization, session: linkSession,
                    operationID: id, password: pendingAppleLink.password
                )
            }
            guard await isCurrent(operationID, generation: linkSession.generation) else { return }
            await loadIdentity(generation: linkSession.generation)
            guard await isCurrent(operationID, generation: linkSession.generation) else { return }
            linkingState = .success(linkSession)
        } catch {
            guard await isCurrent(operationID, generation: linkSession.generation) else { return }
            applyAppleError(error, purpose: .link(linkSession), afterPOST: true)
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
                if afterPOST && (Self.isUnconfirmedMutation(error) || error is CancellationError) {
                    if !usesIdentityV1 { legacyAppleLinkUnconfirmed = true }
                }
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
        case let .rateLimited(retryAfter): return .tooManyAttempts(retryAfter: retryAfter)
        case .http(statusCode: 429, message: _): return .tooManyAttempts(retryAfter: nil)
        case .server(statusCode: 503, message: _): return .unavailable
        default: return .notConfirmed
        }
    }

    private static func isUnconfirmedMutation(_ error: Error) -> Bool {
        guard case let AuthenticationError.request(apiError) = error else { return false }
        return switch apiError {
        case .transport, .invalidResponse, .server: true
        case .http(statusCode: 500...599, message: _): true
        default: false
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
        pendingAppleLink = nil
        if let operationID = activeOperationID { appleProvider.cancel(operationID: operationID) }
        activeOperationID = nil
        appleTask?.cancel()
        appleTask = nil
        appleOperationID = appleProvider.operationID
    }

    func dismissAppleLinkOffer() {
        pendingAppleLink = nil
        linkPassword = ""
        // Abandon Apple work, but keep an already-started password login tracked.
        if appleTask != nil || linkingState.session != nil { abandonApple() }
        linkingState = .none
        linkFromSecurity = false
    }

    func requirePasswordForLink() {
        guard activeOperationID == nil,
              case .failure(_, .passwordRequired) = linkingState else { return }
        linkingState = .passwordRequired
        password = ""
    }

    func restore() async {
        guard activeOperationID == nil else { return }
        do {
            guard try await session.restore() else {
                state = .unauthenticated
                return
            }
            let generation = await session.currentGeneration()
            await loadIdentity(generation: generation)
            guard activeOperationID == nil else { return }
            state = await session.hasActiveSession(generation: generation)
                ? .authenticated : .failure(.sessionExpired)
        }
        catch { state = .failure(Self.displayError(for: error)) }
    }

    func observeSession() async {
        for await event in await session.events() {
            switch event {
            case let .reauthenticationRequired(generation):
                if await session.requiresReauthentication(for: generation) {
                    abandonApple()
                    linkingState = .none
                    identityStatus = nil
                    identityGeneration = nil
                    resetMethodRecovery()
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
        identityStatus = nil
        identityGeneration = nil
        resetMethodRecovery()
        let operationID = UUID()
        activeOperationID = operationID
        password = ""
        linkPassword = ""
        state = .unauthenticated
        // Only the durable local credential clear gates another login. Remote revocation
        // uses the captured family and can complete after the entry screen is available.
        let local = await session.signOutLocally()
        guard activeOperationID == operationID else { return }
        let generation = await session.currentGeneration()
        if !local.confirmed {
            signOutResult = SignOutResult(localConfirmed: false, remoteConfirmed: true)
        }
        remoteSignOutPending = true
        finish(operationID)
        let result = await session.revokeSignedOutSession(local)
        guard await session.isCurrent(generation), activeOperationID == nil else { return }
        remoteSignOutPending = false
        signOutResult = result
    }

    func reloadIdentity() async {
        await loadIdentity(generation: session.currentGeneration())
    }

    func requestAppleLink(fromSecurity: Bool = false) async throws {
        guard appleAuthorizationAvailable, !appleLinkNeedsReconciliation, canChangeMethods,
              let status = identityStatus, status.passwordVerified,
              status.authMethod == "password", let email = status.email else {
            throw AuthenticationError.unauthenticated
        }
        let generation = await session.currentGeneration()
        guard await session.hasActiveSession(generation: generation) else { throw CancellationError() }
        try await session.restorePasswordLinkContext(email: email, generation: generation)
        linkFromSecurity = fromSecurity
        linkingState = .offer(AppleLinkSession(generation: generation, email: email))
    }

    func changeIdentityMethod(
        _ action: IdentityMethodIntent.Action,
        generation: Int,
        submit: (UUID) async throws -> Void
    ) async throws {
        guard identityGeneration == generation else { throw CancellationError() }
        guard canChangeMethods else { throw AuthenticationError.operationInProgress }
        methodChangeInProgress = true
        defer { methodChangeInProgress = false }
        guard await session.hasActiveSession(generation: generation) else { throw CancellationError() }

        let intent = IdentityMethodIntent(id: UUID(), action: action)
        let family = try await methodFamily(generation: generation)
        if let family, let methodIntentStore {
            try await methodIntentStore.save(intent, family: family)
        }
        guard await session.hasActiveSession(generation: generation) else { throw CancellationError() }
        pendingMethodIntent = intent
        pendingMethodGeneration = generation
        do {
            try await submit(intent.id)
        } catch {
            if !Self.methodOutcomeUncertain(error) {
                try await clearMethodIntent(intent, family: family, generation: generation)
            }
            throw error
        }
        try await clearMethodIntent(intent, family: family, generation: generation)
    }

    func checkIdentityMethod() async throws -> Bool {
        guard let identityService, let intent = pendingMethodIntent, !methodChangeInProgress else { return false }
        methodChangeInProgress = true
        defer { methodChangeInProgress = false }
        guard let generation = pendingMethodGeneration else { return false }
        let family = try await methodFamily(generation: generation)
        guard pendingMethodIntent == intent, await session.hasActiveSession(generation: generation) else {
            throw CancellationError()
        }
        guard try await identityService.methodCommitted(intent, generation: generation) else { return false }
        try await clearMethodIntent(intent, family: family, generation: generation)
        await loadIdentity(generation: generation)
        guard await session.hasActiveSession(generation: generation) else { throw CancellationError() }
        if intent.action == .linkApple, let linkSession = linkingState.session, linkSession.generation == generation {
            linkingState = .success(linkSession)
        }
        return true
    }

    private func methodFamily(generation: Int) async throws -> UUID? {
        guard methodIntentStore != nil else { return nil }
        return try await session.identityReceiptFamily(generation: generation)
    }

    private func clearMethodIntent(_ intent: IdentityMethodIntent, family: UUID?, generation: Int) async throws {
        if let family, let methodIntentStore {
            try await methodIntentStore.remove(intent, family: family)
        }
        guard await session.hasActiveSession(generation: generation) else { throw CancellationError() }
        if pendingMethodIntent == intent {
            pendingMethodIntent = nil
            pendingMethodGeneration = nil
        }
    }

    private static func methodOutcomeUncertain(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let apiError: APIError
        if case let AuthenticationError.request(wrapped) = error { apiError = wrapped }
        else if let direct = error as? APIError { apiError = direct }
        else { return true }

        return switch apiError {
        case .transport, .invalidResponse, .decoding, .server, .refreshUnavailable, .reauthenticationRequired:
            true
        case .http(statusCode: 500...599, message: _):
            true
        default:
            false
        }
    }

    private func resetMethodRecovery() {
        legacyAppleLinkUnconfirmed = false
        pendingMethodIntent = nil
        pendingMethodGeneration = nil
        methodRecoveryReady = methodIntentStore == nil
    }

    private func restoreMethodIntent(generation: Int, readID: UUID) async {
        guard let methodIntentStore, !methodChangeInProgress else { return }
        do {
            let family = try await session.identityReceiptFamily(generation: generation)
            let intent = try await methodIntentStore.load(family: family)
            guard await session.hasActiveSession(generation: generation), identityReadID == readID, !methodChangeInProgress else { return }
            pendingMethodIntent = intent
            pendingMethodGeneration = intent == nil ? nil : generation
            methodRecoveryReady = true
        } catch {
            guard await session.hasActiveSession(generation: generation), identityReadID == readID, !methodChangeInProgress else { return }
            methodRecoveryReady = false
        }
    }

    private func loadIdentity(generation: Int) async {
        guard let identityService else { return }
        let readID = UUID()
        identityReadID = readID
        do {
            let status = try await identityService.status(generation: generation)
            guard await session.hasActiveSession(generation: generation), identityReadID == readID else { return }
            identityStatus = status
            identityGeneration = generation
            await restoreMethodIntent(generation: generation, readID: readID)
            guard await session.hasActiveSession(generation: generation), identityReadID == readID else { return }
            if status.financialAccess, status.authMethod == "password", linkingState == .passwordRequired {
                try await requestAppleLink()
            }
        } catch {
            guard await session.hasActiveSession(generation: generation), identityReadID == readID else { return }
            identityStatus = nil
            identityGeneration = nil
        }
    }

    private func authenticate(registering: Bool) async {
        guard activeOperationID == nil, linkingState.session == nil,
              !(registering && linkingState == .passwordRequired) else { return }
        let credentials = AuthenticationCredentials(email: IdentityValidation.normalizedEmail(email), password: password)
        guard IdentityValidation.isValidEmail(credentials.email) else {
            state = .failure(.invalidEmail)
            return
        }
        guard (registering ? IdentityValidation.isNewPassword(credentials.password) : IdentityValidation.isExistingPassword(credentials.password)) else {
            state = .failure(registering ? .invalidNewPassword : .invalidCredentials)
            return
        }
        let operationID = UUID()
        let passwordRequired = linkingState == .passwordRequired
        signOutResult = nil
        remoteSignOutPending = false
        let wasAuthenticated = state == .authenticated
        activeOperationID = operationID
        defer { finish(operationID) }
        authenticationProgress = registering ? "Creating your account…" : "Signing in…"
        if !wasAuthenticated { state = .authenticating }
        do {
            if registering { try await session.register(credentials) }
            else { try await session.login(credentials) }
            guard activeOperationID == operationID else { return }
            resetMethodRecovery()
            identityStatus = nil
            identityGeneration = nil
            password = ""
            let generation = await session.currentGeneration()
            await loadIdentity(generation: generation)
            guard activeOperationID == operationID, await session.isCurrent(generation) else { return }
            state = .authenticated
            if !usesIdentityV1, passwordRequired, linkingState == .passwordRequired {
                let linkSession = try await session.appleLinkSession()
                guard activeOperationID == operationID, linkingState == .passwordRequired else { return }
                linkingState = .offer(linkSession)
            }
        } catch {
            guard activeOperationID == operationID else { return }
            state = .failure(Self.displayError(for: error, registering: registering))
        }
    }

    private static func displayError(for error: Error, registering: Bool = false) -> AuthenticationDisplayError {
        guard let error = error as? AuthenticationError else { return .unexpected }
        switch error {
        case .request(.rateLimited(let seconds)):
            return .rateLimited(isRegistration: registering, retryAfter: seconds)
        case .unauthenticated: return .invalidCredentials
        case .request(.unauthorized), .request(.badRequest), .request(.http(statusCode: 403, message: _)):
            return registering ? .registrationRejected : .invalidCredentials
        case .request(.transport), .request(.invalidResponse), .request(.server),
             .request(.http(statusCode: 500...599, message: _)):
            return registering ? .registrationUnavailable : .signInUnavailable
        case .refreshFailed, .reauthenticationRequired: return .sessionExpired
        case .refreshUnavailable, .credentialsUnavailable: return .unavailable
        default: return .unexpected
        }
    }
}
