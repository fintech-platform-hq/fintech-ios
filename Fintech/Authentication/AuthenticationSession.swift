import Foundation

enum AuthenticationSessionEvent: Sendable {
    case reauthenticationRequired(generation: Int)
}

nonisolated struct AppleLinkSession: Equatable, Sendable {
    let generation: Int
    let email: String
}

actor AuthenticationSession {
    private let service: any AuthenticationServicing
    private let credentialStore: any CredentialStoring
    private var tokens: AuthTokens?
    private var loaded = false
    private var refreshTask: Task<AuthTokens, Error>?
    private(set) var refreshOperationID: UUID?
    private var credentialMutation: Task<Void, Error>?
    private var generation = 0
    private var passwordEmail: String?
    private var linkOperationID: UUID?
    private var eventContinuations: [UUID: AsyncStream<AuthenticationSessionEvent>.Continuation] = [:]

    init(
        service: any AuthenticationServicing,
        credentialStore: any CredentialStoring
    ) {
        self.service = service
        self.credentialStore = credentialStore
    }

    func restore() async throws -> Bool {
        try await loadIfNeeded()
        return tokens != nil
    }

    func requiresReauthentication(for eventGeneration: Int) -> Bool {
        generation == eventGeneration && tokens == nil
    }

    func events() -> AsyncStream<AuthenticationSessionEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(id) }
            }
        }
    }

    func login(_ credentials: AuthenticationCredentials) async throws {
        linkOperationID = nil
        passwordEmail = nil
        cancelRefresh()
        generation += 1
        let requestGeneration = generation
        let newTokens = try await service.login(credentials)
        guard generation == requestGeneration else { throw CancellationError() }
        try await persist(newTokens, generation: requestGeneration)
        guard generation == requestGeneration else { throw CancellationError() }
        passwordEmail = credentials.email
    }

    func register(_ credentials: AuthenticationCredentials) async throws {
        linkOperationID = nil
        passwordEmail = nil
        cancelRefresh()
        generation += 1
        let requestGeneration = generation
        let newTokens = try await service.register(credentials)
        guard generation == requestGeneration else { throw CancellationError() }
        try await persist(newTokens, generation: requestGeneration)
    }

    func signInWithApple(_ authorization: AppleAuthorizationResult, expectedGeneration: Int? = nil) async throws {
        if let expectedGeneration, generation != expectedGeneration { throw CancellationError() }
        linkOperationID = nil
        passwordEmail = nil
        cancelRefresh()
        generation += 1
        let requestGeneration = generation
        let newTokens = try await service.signInWithApple(authorization)
        guard generation == requestGeneration else { throw CancellationError() }
        try await persist(newTokens, generation: requestGeneration)
    }

    func currentGeneration() -> Int { generation }

    func isCurrent(_ expectedGeneration: Int) -> Bool { generation == expectedGeneration }

    func appleLinkSession() throws -> AppleLinkSession {
        guard tokens != nil, let passwordEmail else {
            throw AuthenticationError.request(.http(statusCode: 403, message: nil))
        }
        return AppleLinkSession(generation: generation, email: passwordEmail)
    }

    func linkApple(_ authorization: AppleAuthorizationResult, session: AppleLinkSession, operationID: UUID) async throws {
        guard generation == session.generation else { throw CancellationError() }
        guard passwordEmail == session.email, let token = tokens?.accessToken else {
            throw AuthenticationError.request(.http(statusCode: 403, message: nil))
        }
        guard linkOperationID == nil else { throw AuthenticationError.operationInProgress }
        try Task.checkCancellation()
        linkOperationID = operationID
        defer { if linkOperationID == operationID { linkOperationID = nil } }
        do {
            try await service.linkApple(authorization, accessToken: token)
        } catch {
            guard generation == session.generation, linkOperationID == operationID else { throw CancellationError() }
            throw error
        }
        guard generation == session.generation, linkOperationID == operationID else { throw CancellationError() }
        try Task.checkCancellation()
    }

    func signInWithApple(using provider: any AppleAuthorizationProviding) async throws {
        let authorization = try await provider.authorization()
        try Task.checkCancellation()
        try await signInWithApple(authorization)
    }

    func accessToken() async throws -> String {
        try await loadIfNeeded()
        guard let accessToken = tokens?.accessToken else {
            throw AuthenticationError.unauthenticated
        }
        return accessToken
    }

    func accessToken(
        afterUnauthorizedFor rejectedToken: String,
        onRefreshWait: @Sendable (UUID) -> Void = { _ in }
    ) async throws -> String {
        try await loadIfNeeded()

        guard let currentTokens = tokens else {
            throw AuthenticationError.unauthenticated
        }
        guard currentTokens.accessToken == rejectedToken else {
            return currentTokens.accessToken
        }

        if let refreshTask {
            let requestGeneration = generation
            // Synchronous observation makes pending single-flight consumers testable.
            if let refreshOperationID { onRefreshWait(refreshOperationID) }
            let result = try await refreshTask.value
            guard generation == requestGeneration else { throw CancellationError() }
            return result.accessToken
        }

        let requestGeneration = generation
        let operationID = UUID()
        let task = Task { [weak self] in
            guard let self else { throw AuthenticationError.refreshFailed }
            return try await self.refreshAndPersist(
                previousTokens: currentTokens,
                generation: requestGeneration
            )
        }
        refreshTask = task
        refreshOperationID = operationID
        defer {
            if refreshOperationID == operationID {
                refreshTask = nil
                refreshOperationID = nil
            }
        }
        onRefreshWait(operationID)
        let newTokens = try await task.value
        guard generation == requestGeneration else { throw CancellationError() }
        return newTokens.accessToken
    }

    private func refreshAndPersist(
        previousTokens: AuthTokens,
        generation requestGeneration: Int
    ) async throws -> AuthTokens {
        // Fail closed across relaunch without changing the Keychain record format.
        // ponytail: a crash during refresh requires sign-in; a durable in-flight record
        // is only needed if future requirements must preserve that session across relaunch.
        // A definitive 503 restores the record.
        try await mutateCredentials(generation: requestGeneration) { store in
            try await store.delete()
        }
        guard generation == requestGeneration else { throw CancellationError() }
        try Task.checkCancellation()
        let newTokens: AuthTokens
        do {
            newTokens = try await service.refresh(refreshToken: previousTokens.refreshToken)
        } catch {
            guard generation == requestGeneration else { throw CancellationError() }
            if case AuthenticationError.request(.server(statusCode: 503, message: _)) = error {
                try await persist(previousTokens, generation: requestGeneration)
                throw AuthenticationError.refreshUnavailable
            }
            endSession(generation: requestGeneration)
            throw AuthenticationError.reauthenticationRequired
        }
        guard generation == requestGeneration,
              tokens?.refreshToken == previousTokens.refreshToken else {
            throw CancellationError()
        }
        try await persist(newTokens, generation: requestGeneration)
        return newTokens
    }

    func logout() async {
        passwordEmail = nil
        linkOperationID = nil
        generation += 1
        let requestGeneration = generation
        cancelRefresh()
        try? await loadIfNeeded()
        guard generation == requestGeneration else { return }
        if let refreshToken = tokens?.refreshToken {
            try? await service.logout(refreshToken: refreshToken)
        }
        guard generation == requestGeneration else { return }
        tokens = nil
        loaded = true
        do {
            try await mutateCredentials(generation: requestGeneration) { try await $0.delete() }
        } catch {
            if generation == requestGeneration {
                emit(.reauthenticationRequired(generation: requestGeneration))
            }
        }
    }

    func invalidate() async {
        passwordEmail = nil
        linkOperationID = nil
        generation += 1
        let requestGeneration = generation
        cancelRefresh()
        tokens = nil
        loaded = true
        do {
            try await mutateCredentials(generation: requestGeneration) { try await $0.delete() }
        } catch {
            // Local invalidation remains in force; the event requests reauthentication.
        }
        guard generation == requestGeneration else { return }
        emit(.reauthenticationRequired(generation: requestGeneration))
    }

    private func endSession(generation requestGeneration: Int) {
        guard generation == requestGeneration else { return }
        tokens = nil
        loaded = true
        emit(.reauthenticationRequired(generation: requestGeneration))
    }

    private func emit(_ event: AuthenticationSessionEvent) {
        eventContinuations.values.forEach { $0.yield(event) }
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations[id] = nil
    }

    private func loadIfNeeded() async throws {
        guard !loaded else { return }
        let requestGeneration = generation
        do {
            let restored = try await credentialStore.load()
            guard generation == requestGeneration, !loaded else { return }
            tokens = restored
            loaded = true
        } catch {
            throw AuthenticationError.credentialsUnavailable
        }
    }

    private func persist(_ newTokens: AuthTokens, generation requestGeneration: Int) async throws {
        do {
            try await mutateCredentials(generation: requestGeneration) { store in
                try await store.save(newTokens)
            }
            guard generation == requestGeneration else { throw CancellationError() }
            tokens = newTokens
            loaded = true
        } catch {
            guard generation == requestGeneration else { throw CancellationError() }
            endSession(generation: requestGeneration)
            throw AuthenticationError.credentialsUnavailable
        }
    }

    private func mutateCredentials(
        generation requestGeneration: Int,
        _ mutation: @escaping @Sendable (any CredentialStoring) async throws -> Void
    ) async throws {
        guard generation == requestGeneration else { throw CancellationError() }
        let previous = credentialMutation
        let store = credentialStore
        // Only storage mutations are queued, so replacement sign-in need not wait for HTTP.
        let task = Task {
            _ = await previous?.result
            guard generation == requestGeneration else { throw CancellationError() }
            try await mutation(store)
        }
        credentialMutation = task
        do {
            try await task.value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AuthenticationError.credentialsUnavailable
        }
    }

    private func cancelRefresh() {
        if refreshTask != nil {
            // A replacement attempt must not revive a refresh already sent if sign-in fails.
            tokens = nil
            loaded = true
        }
        refreshTask?.cancel()
        refreshTask = nil
        refreshOperationID = nil
    }
}
