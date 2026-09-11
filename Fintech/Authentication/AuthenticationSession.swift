import Foundation

actor AuthenticationSession {
    private let service: AuthenticationService
    private let credentialStore: any CredentialStoring
    private var tokens: AuthTokens?
    private var loaded = false
    private var refreshTask: Task<AuthTokens, Error>?
    private var generation = 0

    init(
        service: AuthenticationService,
        credentialStore: any CredentialStoring
    ) {
        self.service = service
        self.credentialStore = credentialStore
    }

    func restore() async throws -> Bool {
        try await loadIfNeeded()
        return tokens != nil
    }

    func login(_ credentials: AuthenticationCredentials) async throws {
        cancelRefresh()
        generation += 1
        let requestGeneration = generation
        let newTokens = try await service.login(credentials)
        guard generation == requestGeneration else { throw CancellationError() }
        try await persist(newTokens)
    }

    func register(_ credentials: AuthenticationCredentials) async throws {
        cancelRefresh()
        generation += 1
        let requestGeneration = generation
        let newTokens = try await service.register(credentials)
        guard generation == requestGeneration else { throw CancellationError() }
        try await persist(newTokens)
    }

    func accessToken() async throws -> String {
        try await loadIfNeeded()
        guard let accessToken = tokens?.accessToken else {
            throw AuthenticationError.unauthenticated
        }
        return accessToken
    }

    func accessToken(afterUnauthorizedFor rejectedToken: String) async throws -> String {
        try await loadIfNeeded()

        guard let currentTokens = tokens else {
            throw AuthenticationError.unauthenticated
        }
        guard currentTokens.accessToken == rejectedToken else {
            return currentTokens.accessToken
        }

        if let refreshTask {
            return try await refreshTask.value.accessToken
        }

        let requestGeneration = generation
        let refreshToken = currentTokens.refreshToken
        let task = Task { [weak self] in
            guard let self else { throw AuthenticationError.refreshFailed }
            return try await self.refreshAndPersist(
                refreshToken: refreshToken,
                generation: requestGeneration
            )
        }
        refreshTask = task

        do {
            let newTokens = try await task.value
            refreshTask = nil
            return newTokens.accessToken
        } catch {
            if generation == requestGeneration {
                tokens = nil
                loaded = true
                try? await credentialStore.delete()
                refreshTask = nil
            }
            throw AuthenticationError.refreshFailed
        }
    }

    private func refreshAndPersist(
        refreshToken: String,
        generation requestGeneration: Int
    ) async throws -> AuthTokens {
        let newTokens = try await service.refresh(refreshToken: refreshToken)
        guard generation == requestGeneration,
              tokens?.refreshToken == refreshToken else {
            throw CancellationError()
        }
        try await persist(newTokens)
        return newTokens
    }

    func logout() async {
        generation += 1
        cancelRefresh()
        try? await loadIfNeeded()
        if let refreshToken = tokens?.refreshToken {
            try? await service.logout(refreshToken: refreshToken)
        }
        tokens = nil
        loaded = true
        try? await credentialStore.delete()
    }

    func invalidate() async {
        generation += 1
        cancelRefresh()
        tokens = nil
        loaded = true
        try? await credentialStore.delete()
    }

    private func loadIfNeeded() async throws {
        guard !loaded else { return }
        do {
            tokens = try await credentialStore.load()
            loaded = true
        } catch {
            throw AuthenticationError.credentialsUnavailable
        }
    }

    private func persist(_ newTokens: AuthTokens) async throws {
        do {
            try await credentialStore.save(newTokens)
            tokens = newTokens
            loaded = true
        } catch {
            tokens = nil
            loaded = true
            throw AuthenticationError.credentialsUnavailable
        }
    }

    private func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}
