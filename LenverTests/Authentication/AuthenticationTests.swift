import Foundation
import Synchronization
import Testing
@testable import Lenver

@Suite(.serialized, .timeLimit(.minutes(1)))
struct AuthenticationTests {
    private let baseURL = URL(string: "https://authentication.unit.test/api")!

    @MainActor
    @Test
    func registrationRejectsAnInvalidPasswordBeforeCallingService() async {
        let service = ControlledAuthenticationService()
        let model = AuthenticationViewModel(
            session: AuthenticationSession(service: service, credentialStore: ControlledCredentialStore()),
            appleProvider: AppleAuthorizationProvider()
        )
        model.email = "person@example.test"
        model.password = String(repeating: "a", count: 11)

        await model.register()

        #expect(model.state == .failure(.invalidNewPassword))
        #expect(await service.registerCalls == 0)
    }

    @MainActor
    @Test
    func loginAllowsAnExistingPasswordBelowNewPasswordMinimum() async {
        let service = ControlledAuthenticationService()
        let model = AuthenticationViewModel(
            session: AuthenticationSession(service: service, credentialStore: ControlledCredentialStore()),
            appleProvider: AppleAuthorizationProvider()
        )
        model.email = "person@example.test"
        model.password = "legacy"

        await model.login()

        #expect(model.state == .authenticated)
        #expect(await service.loginCalls == 1)
    }

    @MainActor
    @Test
    func malformedEmailIsRejectedBeforeCallingService() async {
        let service = ControlledAuthenticationService()
        let model = AuthenticationViewModel(
            session: AuthenticationSession(service: service, credentialStore: ControlledCredentialStore()),
            appleProvider: AppleAuthorizationProvider()
        )
        model.email = "not-an-email"
        model.password = "password"

        await model.login()

        #expect(model.state == .failure(.invalidEmail))
        #expect(await service.loginCalls == 0)
    }

    @Test
    func authenticatedRequestRefreshesOnceAndPreservesRequest() async throws {
        let store = InMemoryCredentialStore(tokens: oldTokens)
        let requests = Mutex<[URLRequest]>([])
        let refreshCalls = Mutex(0)

        URLProtocolStub.install(for: baseURL) { request in
            requests.withLock { $0.append(request) }
            switch request.url?.path {
            case "/api/auth/refresh":
                refreshCalls.withLock { $0 += 1 }
                return .response(
                    try response(for: request, statusCode: 200),
                    tokenData(accessToken: "new-access", refreshToken: "new-refresh")
                )
            case "/api/transactions" where requests.withLock({ $0.count }) == 1:
                return .response(try response(for: request, statusCode: 401), Data())
            default:
                return .response(
                    try response(for: request, statusCode: 201),
                    Data(#"{"value":"ok"}"#.utf8)
                )
            }
        }
        defer { URLProtocolStub.reset(for: baseURL) }

        let client = makeAuthenticatedClient(store: store)
        let body = ProbeRequest(value: "stable")
        let result: ProbeResponse = try await client.post(
            path: "/transactions",
            body: body,
            headers: ["Idempotency-Key": "stable-key"],
            expectedStatusCode: 201
        )

        let captured = requests.withLock { $0 }
        #expect(result.value == "ok")
        #expect(refreshCalls.withLock { $0 } == 1)
        try #require(captured.count == 3)
        #expect(captured[0].value(forHTTPHeaderField: "Authorization") == "Bearer old-access")
        #expect(captured[2].value(forHTTPHeaderField: "Authorization") == "Bearer new-access")
        #expect(captured[0].value(forHTTPHeaderField: "Idempotency-Key") == "stable-key")
        #expect(captured[2].value(forHTTPHeaderField: "Idempotency-Key") == "stable-key")
        #expect(captured[0].httpBody == captured[2].httpBody)
    }

    @Test
    func concurrentUnauthorizedRequestsShareOneRefresh() async throws {
        let store = ControlledCredentialStore(tokens: oldTokens)
        let service = ControlledAuthenticationService()
        let session = AuthenticationSession(service: service, credentialStore: store)
        let (waits, continuation) = AsyncStream<UUID>.makeStream()
        defer { continuation.finish() }
        var iterator = waits.makeAsyncIterator()
        let first = Task {
            try await session.accessToken(afterUnauthorizedFor: "old-access", onRefreshWait: { continuation.yield($0) })
        }
        let firstID = try #require(await iterator.next())
        await service.waitForRefreshCalls(1)
        let second = Task {
            try await session.accessToken(afterUnauthorizedFor: "old-access", onRefreshWait: { continuation.yield($0) })
        }
        let secondID = try #require(await iterator.next())
        #expect(firstID == secondID)
        #expect(await session.refreshOperationID == firstID)
        #expect(await service.refreshTokens() == ["old-refresh"])
        // Both consumers reached the same await while HTTP is still retained by the double.
        await service.completeRefresh(1, with: .success(rotatedTokens))
        #expect(try await first.value == "rotated-access")
        #expect(try await second.value == "rotated-access")
        #expect(await service.refreshTokens() == ["old-refresh"])
        #expect(try await store.load() == rotatedTokens)
    }

    @Test
    func failedRefreshEndsSession() async throws {
        let store = InMemoryCredentialStore(tokens: oldTokens)
        URLProtocolStub.install(for: baseURL) { request in
            switch request.url?.path {
            case "/api/auth/refresh":
                .response(try response(for: request, statusCode: 401), Data())
            default:
                .response(try response(for: request, statusCode: 401), Data())
            }
        }
        defer { URLProtocolStub.reset(for: baseURL) }

        let session = makeSession(store: store)
        let client = APIClient(
            baseURL: baseURL,
            session: makeSessionURLSession(),
            authenticationSession: session
        )

        await #expect(throws: APIError.reauthenticationRequired) {
            let _: ProbeResponse = try await client.post(
                path: "/transactions",
                body: ProbeRequest(value: "stable"),
                headers: [:],
                expectedStatusCode: 201
            )
        }
        #expect(try await store.load() == nil)
        await #expect(throws: AuthenticationError.unauthenticated) {
            _ = try await session.accessToken()
        }
    }

    @Test
    func temporaryRefreshFailurePreservesCredentialsForLaterAttempt() async throws {
        let store = InMemoryCredentialStore(tokens: oldTokens)
        let refreshCalls = Mutex(0)
        URLProtocolStub.install(for: baseURL) { request in
            let call = refreshCalls.withLock { value in
                value += 1
                return value
            }
            if call == 1 {
                return .response(try response(for: request, statusCode: 503), Data())
            }
            return .response(
                try response(for: request, statusCode: 200),
                tokenData(accessToken: "new-access", refreshToken: "new-refresh")
            )
        }
        defer { URLProtocolStub.reset(for: baseURL) }

        let session = makeSession(store: store)
        await #expect(throws: AuthenticationError.refreshUnavailable) {
            _ = try await session.accessToken(afterUnauthorizedFor: "old-access")
        }
        #expect(try await store.load() == oldTokens)
        #expect(try await session.restore())
        #expect(try await makeSession(store: store).restore())
        #expect(try await session.accessToken(afterUnauthorizedFor: "old-access") == "new-access")
    }

    @Test
    func temporaryRefreshDoesNotReplayRequestOrEmitReauthentication() async throws {
        let store = InMemoryCredentialStore(tokens: oldTokens)
        let paths = Mutex<[String]>([])
        URLProtocolStub.install(for: baseURL) { request in
            let path = try #require(request.url?.path)
            paths.withLock { $0.append(path) }
            return .response(try response(for: request, statusCode: path == "/api/auth/refresh" ? 503 : 401), Data())
        }
        defer { URLProtocolStub.reset(for: baseURL) }
        let session = makeSession(store: store)
        let events = await session.events()
        let observed = Task { () -> [Int] in
            var result: [Int] = []
            for await event in events {
                if case let .reauthenticationRequired(generation) = event {
                    result.append(generation)
                    if generation == 1 { break }
                }
            }
            return result
        }
        let client = APIClient(baseURL: baseURL, session: makeSessionURLSession(), authenticationSession: session)
        await #expect(throws: APIError.refreshUnavailable) {
            let _: ProbeResponse = try await client.post(path: "/probe", body: ProbeRequest(value: "stable"), headers: [:], expectedStatusCode: 200)
        }
        #expect(paths.withLock { $0 } == ["/api/probe", "/api/auth/refresh"])
        #expect(try await session.restore())
        #expect(try await store.load() == oldTokens)
        await session.invalidate()
        #expect(await observed.value == [1])
    }

    @Test
    func ambiguousRefreshFailureRequiresReauthenticationAndDoesNotRetry() async throws {
        let store = InMemoryCredentialStore(tokens: oldTokens)
        let refreshCalls = Mutex(0)
        URLProtocolStub.install(for: baseURL) { request in
            refreshCalls.withLock { $0 += 1 }
            return .failure(URLError(.timedOut))
        }
        defer { URLProtocolStub.reset(for: baseURL) }

        let session = makeSession(store: store)
        await #expect(throws: AuthenticationError.reauthenticationRequired) {
            _ = try await session.accessToken(afterUnauthorizedFor: "old-access")
        }
        #expect(refreshCalls.withLock { $0 } == 1)
        #expect(try await store.load() == nil)
    }

    @Test(arguments: [URLError.Code.timedOut, .networkConnectionLost, .notConnectedToInternet])
    func ambiguousRefreshCannotBeRestoredOrRetriedAfterRelaunch(_ code: URLError.Code) async throws {
        let store = ControlledCredentialStore(tokens: oldTokens)
        let service = ControlledAuthenticationService()
        let session = AuthenticationSession(service: service, credentialStore: store)
        let refresh = Task { try await session.accessToken(afterUnauthorizedFor: "old-access") }
        await service.waitForRefreshCalls(1)
        // The potentially consumed refresh is already absent before HTTP completes.
        let relaunched = AuthenticationSession(service: service, credentialStore: store)
        #expect(try await relaunched.restore() == false)
        await store.failDeletion()
        await service.completeRefresh(1, with: .failure(AuthenticationError.request(.transport(code: code))))
        await #expect(throws: AuthenticationError.reauthenticationRequired) { try await refresh.value }
        await #expect(throws: AuthenticationError.unauthenticated) {
            try await session.accessToken(afterUnauthorizedFor: "old-access")
        }
        #expect(try await relaunched.restore() == false)
        #expect(await service.refreshTokens() == ["old-refresh"])
    }

    @Test(arguments: [401, 503, 0])
    func lateRefreshFailureCannotInvalidateReplacementSession(_ status: Int) async throws {
        let store = ControlledCredentialStore(tokens: oldTokens)
        let service = ControlledAuthenticationService()
        let session = AuthenticationSession(service: service, credentialStore: store)
        let stream = await session.events()
        let observed = Task { () -> [Int] in
            var generations: [Int] = []
            for await event in stream {
                if case let .reauthenticationRequired(generation) = event {
                    generations.append(generation)
                    if generation == 2 { break }
                }
            }
            return generations
        }
        let refresh = Task { try await session.accessToken(afterUnauthorizedFor: "old-access") }
        await service.waitForRefreshCalls(1)
        try await session.login(AuthenticationCredentials(email: "test@example.com", password: "password"))
        let failure: AuthenticationError = status == 0
            ? .request(.transport(code: .timedOut))
            : status == 401 ? .request(.unauthorized(messages: []))
            : .request(.server(statusCode: status, message: nil))
        await service.completeRefresh(1, with: .failure(failure))
        await #expect(throws: CancellationError.self) { try await refresh.value }
        #expect(try await session.accessToken() == "replacement-access")
        #expect(try await store.load()?.refreshToken == "replacement-refresh")
        // Invalidation of the current session is the deterministic end-of-observation barrier.
        await session.invalidate()
        #expect(await observed.value == [2])
    }

    @Test
    func oldRefreshCannotClearReplacementSingleFlight() async throws {
        let store = ControlledCredentialStore(tokens: oldTokens)
        let service = ControlledAuthenticationService()
        let session = AuthenticationSession(service: service, credentialStore: store)
        let old = Task { try await session.accessToken(afterUnauthorizedFor: "old-access") }
        await service.waitForRefreshCalls(1)
        try await session.login(AuthenticationCredentials(email: "test@example.com", password: "password"))
        let current = Task { try await session.accessToken(afterUnauthorizedFor: "replacement-access") }
        await service.waitForRefreshCalls(2)
        let currentID = try #require(await session.refreshOperationID)
        await service.completeRefresh(1, with: .failure(AuthenticationError.request(.transport(code: .timedOut))))
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(await session.refreshOperationID == currentID)
        // With the old waiter finished, start another request while refresh #2 is retained.
        let (waits, continuation) = AsyncStream<UUID>.makeStream()
        defer { continuation.finish() }
        var iterator = waits.makeAsyncIterator()
        let shared = Task {
            try await session.accessToken(afterUnauthorizedFor: "replacement-access", onRefreshWait: { continuation.yield($0) })
        }
        #expect(await iterator.next() == currentID)
        #expect(await service.refreshTokens() == ["old-refresh", "replacement-refresh"])
        await service.completeRefresh(2, with: .success(rotatedTokens))
        #expect(try await current.value == "rotated-access")
        #expect(try await shared.value == "rotated-access")
        #expect(await service.refreshTokens() == ["old-refresh", "replacement-refresh"])
    }

    @Test
    func failedPreflightDeletionPreventsRefreshTransmission() async throws {
        let store = ControlledCredentialStore(tokens: oldTokens)
        await store.failDeletion()
        let service = ControlledAuthenticationService()
        let session = AuthenticationSession(service: service, credentialStore: store)
        await #expect(throws: AuthenticationError.credentialsUnavailable) {
            try await session.accessToken(afterUnauthorizedFor: "old-access")
        }
        #expect(await service.refreshTokens().isEmpty)
        #expect(try await store.load() == oldTokens)
    }

    @Test
    func failedReplacementCannotRevivePotentiallyConsumedRefresh() async throws {
        let store = ControlledCredentialStore(tokens: oldTokens)
        let service = ControlledAuthenticationService()
        let session = AuthenticationSession(service: service, credentialStore: store)
        let refresh = Task { try await session.accessToken(afterUnauthorizedFor: "old-access") }
        await service.waitForRefreshCalls(1)
        await service.failLogin()
        await #expect(throws: AuthenticationError.request(.unauthorized(messages: []))) {
            try await session.login(AuthenticationCredentials(email: "test@example.com", password: "incorrect"))
        }
        await service.completeRefresh(1, with: .failure(AuthenticationError.request(.transport(code: .timedOut))))
        await #expect(throws: CancellationError.self) { try await refresh.value }
        await #expect(throws: AuthenticationError.unauthenticated) {
            try await session.accessToken(afterUnauthorizedFor: "old-access")
        }
        #expect(try await AuthenticationSession(service: service, credentialStore: store).restore() == false)
        #expect(await service.refreshTokens() == ["old-refresh"])
    }

    @Test(arguments: [false, true])
    func failedPersistenceNeverRestoresPotentiallyConsumedRefresh(_ temporaryFailure: Bool) async throws {
        let store = ControlledCredentialStore(tokens: oldTokens)
        let service = ControlledAuthenticationService()
        let session = AuthenticationSession(service: service, credentialStore: store)
        let refresh = Task { try await session.accessToken(afterUnauthorizedFor: "old-access") }
        await service.waitForRefreshCalls(1)
        await store.failSaving()
        if temporaryFailure {
            await service.completeRefresh(1, with: .failure(AuthenticationError.request(.server(statusCode: 503, message: nil))))
        } else {
            await service.completeRefresh(1, with: .success(rotatedTokens))
        }
        await #expect(throws: AuthenticationError.credentialsUnavailable) { try await refresh.value }
        let relaunched = AuthenticationSession(service: service, credentialStore: store)
        #expect(try await relaunched.restore() == false)
        await #expect(throws: AuthenticationError.unauthenticated) { try await session.accessToken() }
        #expect(await service.refreshTokens().count == 1)
    }

    @Test
    func storageReadFailureIsReportedWithoutRefresh() async throws {
        let store = ControlledCredentialStore(tokens: oldTokens)
        await store.failLoading()
        let service = ControlledAuthenticationService()
        let session = AuthenticationSession(service: service, credentialStore: store)
        await #expect(throws: AuthenticationError.credentialsUnavailable) { try await session.restore() }
        #expect(await service.refreshTokens().isEmpty)
    }

    @Test
    func localSignOutClearsStorageBeforeRemoteCallAndReportsOffline() async throws {
        let store = InMemoryCredentialStore(tokens: oldTokens)
        let requests = Mutex<[String]>([])
        URLProtocolStub.install(for: baseURL) { request in
            requests.withLock { $0.append(request.url?.path ?? "") }
            return .failure(URLError(.notConnectedToInternet))
        }
        defer { URLProtocolStub.reset(for: baseURL) }
        let session = makeSession(store: store)
        #expect(try await session.restore())

        let local = await session.signOutLocally()
        #expect(local.confirmed)
        #expect(requests.withLock { $0.isEmpty })
        #expect(try await makeSession(store: store).restore() == false)
        await #expect(throws: AuthenticationError.unauthenticated) { try await session.accessToken() }

        let result = await session.revokeSignedOutSession(local)
        #expect(result.localConfirmed)
        #expect(!result.remoteConfirmed)
        #expect(requests.withLock { $0 } == ["/api/auth/logout"])
    }

    private func makeAuthenticatedClient(
        store: InMemoryCredentialStore
    ) -> APIClient {
        APIClient(
            baseURL: baseURL,
            session: makeSessionURLSession(),
            authenticationSession: makeSession(store: store)
        )
    }

    private func makeSession(
        store: InMemoryCredentialStore
    ) -> AuthenticationSession {
        let rawClient = APIClient(baseURL: baseURL, session: makeSessionURLSession())
        return AuthenticationSession(
            service: AuthenticationService(apiClient: rawClient),
            credentialStore: store
        )
    }

    private func makeSessionURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private var oldTokens: AuthTokens {
        AuthTokens(
            accessToken: "old-access",
            refreshToken: "old-refresh",
            tokenType: "Bearer",
            expiresIn: 900
        )
    }

    private var rotatedTokens: AuthTokens {
        AuthTokens(accessToken: "rotated-access", refreshToken: "rotated-refresh", tokenType: "Bearer", expiresIn: 900)
    }

    private func tokenData(accessToken: String, refreshToken: String) -> Data {
        Data(
            "{\"accessToken\":\"\(accessToken)\",\"refreshToken\":\"\(refreshToken)\",\"tokenType\":\"Bearer\",\"expiresIn\":900}".utf8
        )
    }
}

// HTTP completion is explicitly controlled and deliberately ignores task cancellation.
// This models responses that arrive after the session has been replaced.
private actor ControlledAuthenticationServiceState {
    private var requestedRefreshTokens: [String] = []
    private var refreshContinuations: [Int: CheckedContinuation<AuthTokens, Error>] = [:]
    private var callWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    var appleFailure: AuthenticationError?
    private(set) var appleCalls = 0
    private(set) var loginCalls = 0
    private(set) var registerCalls = 0
    private var loginFails = false

    func failLogin() { loginFails = true }
    func login(_ credentials: AuthenticationCredentials) async throws -> AuthTokens {
        loginCalls += 1
        if loginFails { throw AuthenticationError.request(.unauthorized(messages: [])) }
        return replacementTokens
    }
    func register(_ credentials: AuthenticationCredentials) async throws -> AuthTokens {
        registerCalls += 1
        return replacementTokens
    }
    func logout(refreshToken: String) async throws {}
    func signInWithApple(_ authorization: AppleAuthorizationResult) async throws -> AuthTokens {
        appleCalls += 1
        if let appleFailure { throw appleFailure }
        return replacementTokens
    }
    func linkApple(_ authorization: AppleAuthorizationResult, accessToken: String) async throws {}
    func setAppleFailure(_ error: AuthenticationError) { appleFailure = error }
    func refresh(refreshToken: String) async throws -> AuthTokens {
        requestedRefreshTokens.append(refreshToken)
        let call = requestedRefreshTokens.count
        return try await withCheckedThrowingContinuation { continuation in
            refreshContinuations[call] = continuation
            callWaiters.removeValue(forKey: call)?.forEach { $0.resume() }
        }
    }
    func waitForRefreshCalls(_ count: Int) async {
        guard requestedRefreshTokens.count < count else { return }
        await withCheckedContinuation { callWaiters[count, default: []].append($0) }
    }
    func completeRefresh(_ call: Int, with result: Result<AuthTokens, Error>) {
        refreshContinuations.removeValue(forKey: call)?.resume(with: result)
    }
    func refreshTokens() -> [String] { requestedRefreshTokens }

    private var replacementTokens: AuthTokens {
        AuthTokens(accessToken: "replacement-access", refreshToken: "replacement-refresh", tokenType: "Bearer", expiresIn: 900)
    }
}

struct ControlledAuthenticationService: AuthenticationServicing {
    private let state: ControlledAuthenticationServiceState

    init() {
        state = ControlledAuthenticationServiceState()
    }

    func failLogin() async { await state.failLogin() }
    func login(_ credentials: AuthenticationCredentials) async throws -> AuthTokens { try await state.login(credentials) }
    func register(_ credentials: AuthenticationCredentials) async throws -> AuthTokens { try await state.register(credentials) }
    func logout(refreshToken: String) async throws { try await state.logout(refreshToken: refreshToken) }
    func signInWithApple(_ authorization: AppleAuthorizationResult) async throws -> AuthTokens {
        try await state.signInWithApple(authorization)
    }
    func linkApple(_ authorization: AppleAuthorizationResult, accessToken: String) async throws {
        try await state.linkApple(authorization, accessToken: accessToken)
    }
    func setAppleFailure(_ error: AuthenticationError) async { await state.setAppleFailure(error) }
    var appleCalls: Int { get async { await state.appleCalls } }
    var loginCalls: Int { get async { await state.loginCalls } }
    var registerCalls: Int { get async { await state.registerCalls } }
    func refresh(refreshToken: String) async throws -> AuthTokens { try await state.refresh(refreshToken: refreshToken) }
    func waitForRefreshCalls(_ count: Int) async { await state.waitForRefreshCalls(count) }
    func completeRefresh(_ call: Int, with result: Result<AuthTokens, Error>) async {
        await state.completeRefresh(call, with: result)
    }
    func refreshTokens() async -> [String] { await state.refreshTokens() }
}

private actor ControlledCredentialStoreState {
    private var tokens: AuthTokens?
    private var savingFails = false
    private var deletionFails = false
    private var loadingFails = false

    init(tokens: AuthTokens? = nil) { self.tokens = tokens }
    func failSaving() { savingFails = true }
    func failDeletion() { deletionFails = true }
    func failLoading() { loadingFails = true }
    func load() async throws -> AuthTokens? {
        if loadingFails { throw KeychainError.interactionNotAllowed }
        return tokens
    }
    func save(_ tokens: AuthTokens) async throws {
        if savingFails { throw KeychainError.interactionNotAllowed }
        self.tokens = tokens
    }
    func delete() async throws {
        if deletionFails { throw KeychainError.interactionNotAllowed }
        tokens = nil
    }
}

struct ControlledCredentialStore: CredentialStoring {
    private let state: ControlledCredentialStoreState

    init(tokens: AuthTokens? = nil) {
        state = ControlledCredentialStoreState(tokens: tokens)
    }

    func failSaving() async { await state.failSaving() }
    func failDeletion() async { await state.failDeletion() }
    func failLoading() async { await state.failLoading() }
    func load() async throws -> AuthTokens? { try await state.load() }
    func save(_ tokens: AuthTokens) async throws { try await state.save(tokens) }
    func delete() async throws { try await state.delete() }
}

private struct ProbeRequest: Encodable, Sendable {
    let value: String
}

private struct ProbeResponse: Decodable, Equatable, Sendable {
    let value: String
}

private actor InMemoryCredentialStore: CredentialStoring {
    private var tokens: AuthTokens?

    init(tokens: AuthTokens?) {
        self.tokens = tokens
    }

    func load() async throws -> AuthTokens? { tokens }

    func save(_ tokens: AuthTokens) async throws {
        self.tokens = tokens
    }

    func delete() async throws {
        tokens = nil
    }
}

private func response(
    for request: URLRequest,
    statusCode: Int
) throws -> HTTPURLResponse {
    HTTPURLResponse(
        url: try #require(request.url),
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    )!
}
