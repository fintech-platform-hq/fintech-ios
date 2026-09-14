import AuthenticationServices
import Foundation
import Synchronization
import Testing
@testable import Fintech

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct AppleAccountLinkingTests {
    private let baseURL = URL(string: "https://apple-link.unit.test/api")!

    @Test(arguments: [true, false])
    func onlyAppleAccountLinkCodeRequiresPassword(_ hasCode: Bool) async throws {
        let body = hasCode ? #"{"code":"ACCOUNT_LINK_REQUIRED","message":"existing"}"# : #"{"message":"conflict"}"#
        URLProtocolStub.install(for: baseURL) { request in
            .response(HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        defer { URLProtocolStub.reset(for: baseURL) }
        let client = rawClient()
        let service = AuthenticationService(apiClient: client)
        let model = AuthenticationViewModel(session: AuthenticationSession(service: service, credentialStore: LinkStore()), appleProvider: LinkProvider())
        await model.restore()
        await model.signInWithApple()
        #expect(model.linkingState == (hasCode ? .passwordRequired : .none))
        #expect(model.state != .authenticated)
        if hasCode { await #expect(throws: APIError.idempotencyConflict(message: "existing")) {
            // Even this code must not change the existing transaction conflict contract.
            let _: AuthTokens = try await client.post(path: "/transactions", body: AuthenticationCredentials(email: "x", password: "x"), headers: [:], expectedStatusCode: 201)
        } }
    }

    @Test
    func passwordLoginThenFreshNativeAuthorizationLinksWithoutTokenMutation() async throws {
        let requests = Mutex<[URLRequest]>([])
        URLProtocolStub.install(for: baseURL) { request in
            requests.withLock { $0.append(request) }
            switch request.url?.path {
            case "/api/auth/apple":
                return .response(HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!, Data(#"{"code":"ACCOUNT_LINK_REQUIRED"}"#.utf8))
            case "/api/auth/login":
                return .response(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"accessToken":"password-access","refreshToken":"password-refresh","tokenType":"Bearer","expiresIn":900}"#.utf8))
            default:
                return .response(HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            }
        }
        defer { URLProtocolStub.reset(for: baseURL) }
        let provider = NativeLinkProvider()
        let store = LinkStore()
        let session = AuthenticationSession(service: AuthenticationService(apiClient: rawClient()), credentialStore: store)
        let model = AuthenticationViewModel(session: session, appleProvider: provider)
        await model.restore()
        let requestA = ASAuthorizationAppleIDProvider().createRequest()
        try provider.configure(requestA)
        provider.resolve(identity: "token-A", code: "code-A")
        await model.signInWithApple()
        #expect(model.linkingState == .passwordRequired)
        let countA = provider.calls
        await model.signInWithApple()
        #expect(provider.calls == countA)
        #expect(!model.canStartApple)
        model.email = "password@example.com"
        model.password = "password"
        await model.login()
        let offer = try #require(model.linkingState.session)
        #expect(model.linkingState == .offer(offer))
        #expect(offer.email == "password@example.com")
        let mutations = await store.mutations
        let requestB = ASAuthorizationAppleIDProvider().createRequest()
        try provider.configure(requestB)
        provider.resolve(identity: "token-B", code: "code-B")
        await model.signInWithApple()
        #expect(model.state == .authenticated)
        #expect(model.linkingState == .success(offer))
        #expect(requestA.nonce != requestB.nonce)
        #expect(await store.mutations == mutations)
        #expect(try await session.accessToken() == "password-access")
        let captured = requests.withLock { $0 }
        #expect(captured.map { $0.url!.path } == ["/api/auth/apple", "/api/auth/login", "/api/auth/apple/link"])
        let link = try #require(captured.last)
        #expect(link.value(forHTTPHeaderField: "Authorization") == "Bearer password-access")
        let linkBody = try #require(link.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: linkBody) as? [String: String])
        let nonceB = try #require(requestB.nonce)
        #expect(payload == ["identityToken": "token-B", "authorizationCode": "code-B", "nonce": nonceB])
        #expect(!payload.values.contains("token-A") && !payload.values.contains("code-A"))
        model.dismissAppleLinkOffer()
        #expect(model.linkingState == .none && model.state == .authenticated)
        #expect(await store.mutations == mutations)
    }

    @Test(arguments: [401, 403, 409, 429, 503, -1, -2, -3, -4])
    func linkingHTTPAndAmbiguousResultsNeverRefreshReplayOrMutateTokens(_ result: Int) async throws {
        let calls = Mutex<[URLRequest]>([])
        URLProtocolStub.install(for: baseURL) { request in
            calls.withLock { $0.append(request) }
            switch result {
            case -1: return .failure(URLError(.timedOut))
            case -2: return .failure(URLError(.networkConnectionLost))
            case -3: return .response(URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil), Data())
            case -4: return .failure(URLError(.cancelled))
            default: return .response(HTTPURLResponse(url: request.url!, statusCode: result, httpVersion: nil, headerFields: nil)!, Data())
            }
        }
        defer { URLProtocolStub.reset(for: baseURL) }
        let store = LinkStore()
        let loginService = LinkService()
        let session = AuthenticationSession(service: loginService, credentialStore: store)
        try await session.login(AuthenticationCredentials(email: "p@example.com", password: "p"))
        let mutations = await store.mutations
        // Injecting an authenticated client must still not allow replay for this endpoint.
        let service = AuthenticationService(apiClient: APIClient(baseURL: baseURL, session: urlSession(), authenticationSession: session))
        do {
            try await service.linkApple(artifact("B"), accessToken: "explicit-password-bearer")
            Issue.record("Expected linking failure")
        } catch {}
        #expect(calls.withLock { $0.count } == 1)
        #expect(calls.withLock { $0.first?.url?.path } == "/api/auth/apple/link")
        #expect(calls.withLock { $0.first?.value(forHTTPHeaderField: "Authorization") } == "Bearer explicit-password-bearer")
        #expect(try await session.accessToken() == "password-access")
        #expect(await store.mutations == mutations)
        #expect(await loginService.refreshCalls == 0)
    }

    @Test(arguments: [401, 403, 409, 429, 503, 0, -1])
    func viewModelKeepsAuthenticationAndUsesSpecificLinkErrors(_ status: Int) async throws {
        let fixture = try await offeredModel()
        let linkSession = try #require(fixture.model.linkingState.session)
        let error: Error = status == 0 ? AuthenticationError.request(.transport(code: .timedOut))
            : status == -1 ? CancellationError()
            : status == 401 ? AuthenticationError.request(.unauthorized(messages: []))
            : status == 409 ? AuthenticationError.request(.idempotencyConflict(message: nil))
            : status == 503 ? AuthenticationError.request(.server(statusCode: 503, message: nil))
            : AuthenticationError.request(.http(statusCode: status, message: nil))
        await fixture.service.setLinkResult(.failure(error))
        let mutations = await fixture.store.mutations
        await fixture.model.signInWithApple()
        let expected: AppleLinkDisplayError = status == 403 ? .passwordRequired : status == 409 ? .conflict
            : status == 429 ? .tooManyAttempts : status == 503 ? .unavailable : .notConfirmed
        #expect(fixture.model.linkingState == .failure(linkSession, expected))
        #expect(fixture.model.state == .authenticated)
        #expect(await fixture.store.mutations == mutations)
        #expect(try await fixture.session.accessToken() == "password-access")
        #expect(await fixture.service.linkCalls.count == 1)
        if status == 403 {
            #expect(!fixture.model.canStartApple)
            await fixture.model.signInWithApple()
            #expect(await fixture.service.linkCalls.count == 1)
            fixture.model.requirePasswordForLink()
            #expect(fixture.model.linkingState == .passwordRequired)
            fixture.model.password = "password"
            await fixture.model.login()
            #expect(fixture.model.linkingState.session != nil)
        }
    }

    @Test
    func failedPasswordLoginCannotOfferLinkOrAuthenticate() async throws {
        let service = LinkService()
        let provider = LinkProvider()
        let model = AuthenticationViewModel(session: AuthenticationSession(service: service, credentialStore: LinkStore()), appleProvider: provider)
        await model.restore()
        await model.signInWithApple()
        await service.setLoginFailure(true)
        model.email = "p@example.com"
        model.password = "bad"
        await model.register()
        #expect(await service.registerCalls == 0)
        await model.login()
        #expect(model.linkingState == .passwordRequired)
        #expect(model.state == .failure(.invalidCredentials))
        await model.signInWithApple()
        #expect(provider.calls == 1)
        #expect(await service.linkCalls.isEmpty)
    }

    @Test(arguments: [true, false])
    func appleCancellationBeforePOSTReturnsToOffer(_ appleCancellation: Bool) async throws {
        let fixture = try await offeredModel()
        let offer = fixture.model.linkingState
        fixture.provider.nextResult = .failure(appleCancellation ? ASAuthorizationError(.canceled) : CancellationError())
        await fixture.model.signInWithApple()
        #expect(fixture.model.linkingState == offer)
        #expect(fixture.model.state == .authenticated)
        #expect(await fixture.service.linkCalls.isEmpty)
    }

    @Test
    func abandoningLinkIntentDuringPasswordLoginKeepsLoginTracked() async throws {
        let service = LinkService()
        let provider = LinkProvider()
        let store = LinkStore()
        let session = AuthenticationSession(service: service, credentialStore: store)
        let model = AuthenticationViewModel(session: session, appleProvider: provider)
        await model.restore()
        await model.signInWithApple()
        #expect(model.linkingState == .passwordRequired)
        let authorizationCalls = provider.calls
        await service.setHoldLogin(true)
        model.email = "p@example.com"
        model.password = "p"
        let login = Task { await model.login() }
        await service.loginStarted.wait()
        #expect(model.state == .authenticating)
        model.dismissAppleLinkOffer()
        #expect(model.linkingState == .none)
        #expect(model.operationInProgress)
        #expect(!model.canStartApple)
        await model.login()
        await model.register()
        await model.signInWithApple()
        #expect(await service.loginCalls == 1)
        #expect(await service.registerCalls == 0)
        #expect(provider.calls == authorizationCalls)
        await service.releaseLogin(.success(passwordTokens))
        await login.value
        #expect(model.state == .authenticated)
        #expect(!model.operationInProgress)
        #expect(model.linkingState == .none)
        #expect(!model.shouldOfferAppleLink)
        #expect(try await session.restore())
        #expect(try await session.accessToken() == passwordTokens.accessToken)
        #expect(try await store.load() == passwordTokens)
        #expect(await store.mutations == ["save"])
        #expect(provider.calls == authorizationCalls)
        #expect(await service.appleCalls.count == 1)
        #expect(await service.linkCalls.isEmpty)
    }

    @Test
    func duplicateAndIncompatibleOperationsAreGuardedDuringAuthorizationAndPOST() async throws {
        let fixture = try await offeredModel()
        fixture.provider.hold = true
        await fixture.service.setHoldLink(true)
        let linking = Task { await fixture.model.signInWithApple() }
        await fixture.provider.waiting.wait()
        #expect(fixture.model.state == .authenticated)
        #expect(fixture.model.operationInProgress)
        let calls = fixture.provider.calls
        await fixture.model.signInWithApple()
        fixture.model.configureAppleRequest(ASAuthorizationAppleIDProvider().createRequest(), operationID: fixture.provider.operationID)
        await fixture.model.login()
        await fixture.model.register()
        #expect(fixture.provider.calls == calls)
        #expect(await fixture.service.loginCalls == 1)
        fixture.provider.release(.success(artifact("B")))
        await fixture.service.linkStarted.wait()
        #expect(fixture.model.state == .authenticated)
        #expect(fixture.model.linkingState == .submitting(try #require(fixture.model.linkingState.session)))
        await fixture.model.signInWithApple()
        #expect(await fixture.service.linkCalls.count == 1)
        await fixture.service.releaseLink(.success(()))
        await linking.value
        #expect(!fixture.model.operationInProgress)
        #expect(fixture.model.state == .authenticated)
    }

    @Test(arguments: [false, true])
    func abandoningAuthorizationNeverConvertsLinkToSignIn(_ logout: Bool) async throws {
        let fixture = try await offeredModel()
        fixture.provider.hold = true
        let linking = Task { await fixture.model.signInWithApple() }
        await fixture.provider.waiting.wait()
        if logout { await fixture.model.logout() }
        else { fixture.model.dismissAppleLinkOffer() }
        // Double intentionally ignores cancellation and returns a late credential.
        fixture.provider.release(.success(artifact("late-B")))
        await linking.value
        #expect(await fixture.service.appleCalls.count == 1)
        #expect(await fixture.service.linkCalls.isEmpty)
        #expect(fixture.model.linkingState == .none)
        #expect(fixture.model.state == (logout ? .unauthenticated : .authenticated))
    }

    @Test(arguments: [false, true])
    func replacementSessionDuringAuthorizationPreventsPOST(_ logout: Bool) async throws {
        let fixture = try await offeredModel()
        fixture.provider.hold = true
        let linking = Task { await fixture.model.signInWithApple() }
        await fixture.provider.waiting.wait()
        if logout { await fixture.session.logout() }
        else { try await fixture.session.login(AuthenticationCredentials(email: "new@example.com", password: "p")) }
        fixture.provider.release(.success(artifact("B")))
        await linking.value
        #expect(await fixture.service.linkCalls.isEmpty)
        #expect(await fixture.service.appleCalls.count == 1)
        #expect(fixture.model.linkingState == .none)
        #expect(fixture.model.state == (logout ? .unauthenticated : .authenticated))
    }

    @Test(arguments: [0, 401], [false, true])
    func late204And401CannotAffectLogoutOrReplacement(_ status: Int, _ logout: Bool) async throws {
        let fixture = try await offeredModel()
        await fixture.service.setHoldLink(true)
        let linking = Task { await fixture.model.signInWithApple() }
        await fixture.service.linkStarted.wait()
        #expect(fixture.model.state == .authenticated)
        if logout { await fixture.model.logout() }
        else { try await fixture.session.login(AuthenticationCredentials(email: "replacement@example.com", password: "p")) }
        let mutations = await fixture.store.mutations
        await fixture.service.releaseLink(status == 0 ? .success(()) : .failure(AuthenticationError.request(.unauthorized(messages: []))))
        await linking.value
        #expect(fixture.model.linkingState == .none)
        #expect(fixture.model.state == (logout ? .unauthenticated : .authenticated))
        #expect(await fixture.store.mutations == mutations)
        #expect(await fixture.service.appleCalls.count == 1)
    }

    @Test
    func newOperationIsNotReleasedByAbandonedOperation() async throws {
        let fixture = try await offeredModel()
        await fixture.service.setHoldLink(true)
        let old = Task { await fixture.model.signInWithApple() }
        await fixture.service.linkStarted.wait()
        await fixture.model.logout()
        fixture.model.email = "new@example.com"
        fixture.model.password = "p"
        await fixture.model.login()
        // New sign-in authorization remains pending while old linking completes.
        await fixture.model.logout()
        fixture.provider.hold = true
        let new = Task { await fixture.model.signInWithApple() }
        await fixture.provider.waiting.wait()
        #expect(fixture.model.operationInProgress)
        await fixture.service.releaseLink(.failure(AuthenticationError.request(.unauthorized(messages: []))))
        await old.value
        #expect(fixture.model.operationInProgress)
        fixture.provider.release(.failure(ASAuthorizationError(.canceled)))
        await new.value
        #expect(!fixture.model.operationInProgress)
    }

    @Test
    func sessionRejectsNonPasswordAndStaleContext() async throws {
        let service = LinkService()
        let session = AuthenticationSession(service: service, credentialStore: LinkStore(tokens: passwordTokens))
        _ = try await session.restore()
        await #expect(throws: AuthenticationError.request(.http(statusCode: 403, message: nil))) { try await session.appleLinkSession() }
        try await session.login(AuthenticationCredentials(email: "p@example.com", password: "p"))
        let context = try await session.appleLinkSession()
        await session.logout()
        await #expect(throws: CancellationError.self) {
            try await session.linkApple(artifact("B"), session: context, operationID: UUID())
        }
        #expect(await service.linkCalls.isEmpty)
    }

    @Test(arguments: [0, 401])
    func sessionItselfDiscardsLateLinkResult(_ status: Int) async throws {
        let fixture = try await offeredModel()
        let context = try await fixture.session.appleLinkSession()
        await fixture.service.setHoldLink(true)
        let linking = Task {
            try await fixture.session.linkApple(artifact("B"), session: context, operationID: UUID())
        }
        await fixture.service.linkStarted.wait()
        #expect(await fixture.service.bearers == ["password-access"])
        try await fixture.session.login(AuthenticationCredentials(email: "replacement@example.com", password: "p"))
        let mutations = await fixture.store.mutations
        await fixture.service.releaseLink(status == 0 ? .success(()) : .failure(AuthenticationError.request(.unauthorized(messages: []))))
        await #expect(throws: CancellationError.self) { try await linking.value }
        #expect(await fixture.store.mutations == mutations)
        #expect(try await fixture.session.accessToken() == "replacement-access")
    }

    @Test
    func retryAfter401UsesNewNativeAuthorizationAndNonce() async throws {
        let service = LinkService()
        let store = LinkStore()
        let provider = NativeLinkProvider()
        let session = AuthenticationSession(service: service, credentialStore: store)
        let model = AuthenticationViewModel(session: session, appleProvider: provider)
        await model.restore()
        try provider.configure(ASAuthorizationAppleIDProvider().createRequest())
        provider.resolve(identity: "A", code: "code-A")
        await model.signInWithApple()
        model.email = "p@example.com"
        model.password = "p"
        await model.login()
        await service.setLinkResult(.failure(AuthenticationError.request(.unauthorized(messages: []))))
        let requestB = ASAuthorizationAppleIDProvider().createRequest()
        try provider.configure(requestB)
        provider.resolve(identity: "B", code: "code-B")
        await model.signInWithApple()
        #expect(model.state == .authenticated)
        #expect(await service.linkCalls.count == 1)
        await service.setLinkResult(.success(()))
        let requestC = ASAuthorizationAppleIDProvider().createRequest()
        try provider.configure(requestC)
        provider.resolve(identity: "C", code: "code-C")
        await model.signInWithApple()
        let linked = await service.linkCalls
        #expect(linked.map(\.authorizationCode) == ["code-B", "code-C"])
        #expect(linked.map(\.identityToken) == ["B", "C"])
        #expect(linked.map(\.nonce) == [requestB.nonce, requestC.nonce])
        #expect(requestB.nonce != requestC.nonce)
        #expect(await service.bearers == ["password-access", "password-access"])
        #expect(await store.mutations == ["save"])
    }

    @Test
    func abandoningConfiguredNativeRequestDiscardsNonceBeforeWaiting() throws {
        let provider = AppleAuthorizationProvider()
        let requestA = ASAuthorizationAppleIDProvider().createRequest()
        let oldID = provider.operationID
        try provider.configure(requestA)
        provider.cancel(operationID: oldID)
        #expect(provider.operationID != oldID)
        let requestB = ASAuthorizationAppleIDProvider().createRequest()
        try provider.configure(requestB)
        #expect(requestA.nonce != requestB.nonce)
    }

    private func offeredModel() async throws -> LinkFixture {
        let service = LinkService()
        let provider = LinkProvider()
        let store = LinkStore()
        let session = AuthenticationSession(service: service, credentialStore: store)
        let model = AuthenticationViewModel(session: session, appleProvider: provider)
        await model.restore()
        await model.signInWithApple()
        model.email = "p@example.com"
        model.password = "p"
        await model.login()
        try #require(model.linkingState.session != nil)
        return LinkFixture(model: model, session: session, service: service, provider: provider, store: store)
    }
    private func urlSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: config)
    }
    private func rawClient() -> APIClient { APIClient(baseURL: baseURL, session: urlSession()) }
}

@MainActor
private struct LinkFixture {
    let model: AuthenticationViewModel
    let session: AuthenticationSession
    let service: LinkService
    let provider: LinkProvider
    let store: LinkStore
}

private nonisolated func artifact(_ label: String) -> AppleAuthorizationResult {
    AppleAuthorizationResult(identityToken: "token-\(label)", authorizationCode: "code-\(label)", nonce: "nonce-\(label)")
}
private nonisolated var passwordTokens: AuthTokens {
    AuthTokens(accessToken: "password-access", refreshToken: "password-refresh", tokenType: "Bearer", expiresIn: 900)
}

private actor LinkStore: CredentialStoring {
    private var tokens: AuthTokens?
    private(set) var mutations: [String] = []
    init(tokens: AuthTokens? = nil) { self.tokens = tokens }
    func load() async throws -> AuthTokens? { tokens }
    func save(_ tokens: AuthTokens) async throws { mutations.append("save"); self.tokens = tokens }
    func delete() async throws { mutations.append("delete"); tokens = nil }
}

private actor LinkBarrier {
    private var signaled = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if signaled { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func signal() { signaled = true; continuation?.resume(); continuation = nil }
}

private actor LinkService: AuthenticationServicing {
    private(set) var appleCalls: [AppleAuthorizationResult] = []
    private(set) var linkCalls: [AppleAuthorizationResult] = []
    private(set) var bearers: [String] = []
    private(set) var loginCalls = 0
    private(set) var registerCalls = 0
    private(set) var refreshCalls = 0
    private var loginFailure = false
    private var holdLogin = false
    private var loginContinuation: CheckedContinuation<AuthTokens, Error>?
    private var holdLink = false
    private var result: Result<Void, Error> = .success(())
    private var continuation: CheckedContinuation<Void, Error>?
    let linkStarted = LinkBarrier()
    let loginStarted = LinkBarrier()
    func setHoldLogin(_ hold: Bool) { holdLogin = hold }
    func releaseLogin(_ result: Result<AuthTokens, Error>) {
        loginContinuation?.resume(with: result)
        loginContinuation = nil
    }
    func setLoginFailure(_ fail: Bool) { loginFailure = fail }
    func setHoldLink(_ hold: Bool) { holdLink = hold }
    func setLinkResult(_ result: Result<Void, Error>) { self.result = result }
    func login(_ credentials: AuthenticationCredentials) async throws -> AuthTokens {
        loginCalls += 1
        if holdLogin {
            return try await withCheckedThrowingContinuation { continuation in
                loginContinuation = continuation
                Task { await loginStarted.signal() }
            }
        }
        if loginFailure { throw AuthenticationError.request(.unauthorized(messages: [])) }
        if credentials.email == "replacement@example.com" {
            return AuthTokens(accessToken: "replacement-access", refreshToken: "replacement-refresh", tokenType: "Bearer", expiresIn: 900)
        }
        return passwordTokens
    }
    func register(_ credentials: AuthenticationCredentials) async throws -> AuthTokens { registerCalls += 1; return passwordTokens }
    func refresh(refreshToken: String) async throws -> AuthTokens { refreshCalls += 1; return passwordTokens }
    func logout(refreshToken: String) async throws {}
    func signInWithApple(_ authorization: AppleAuthorizationResult) async throws -> AuthTokens {
        appleCalls.append(authorization)
        throw AuthenticationError.accountLinkRequired
    }
    func linkApple(_ authorization: AppleAuthorizationResult, accessToken: String) async throws {
        linkCalls.append(authorization)
        bearers.append(accessToken)
        if holdLink {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                Task { await linkStarted.signal() }
            }
        } else { try result.get() }
    }
    func releaseLink(_ result: Result<Void, Error>) { continuation?.resume(with: result); continuation = nil }
}

@MainActor
private final class LinkProvider: AppleAuthorizationProviding {
    private(set) var operationID = UUID()
    private(set) var calls = 0
    var nextResult: Result<AppleAuthorizationResult, Error> = .success(artifact("B"))
    var hold = false
    let waiting = LinkBarrier()
    private var continuation: CheckedContinuation<AppleAuthorizationResult, Error>?
    func configure(_ request: ASAuthorizationAppleIDRequest) throws {}
    func complete(_ result: Result<ASAuthorization, Error>, operationID: UUID) {}
    func authorization() async throws -> AppleAuthorizationResult {
        calls += 1
        defer { operationID = UUID() }
        if hold {
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                Task { await waiting.signal() }
            }
        }
        return try nextResult.get()
    }
    func release(_ result: Result<AppleAuthorizationResult, Error>) { continuation?.resume(with: result); continuation = nil }
    // Intentionally does not resume: tests explicitly release late authorization.
    func cancel(operationID: UUID) { self.operationID = UUID() }
}

@MainActor
private final class NativeLinkProvider: AppleAuthorizationProviding {
    let provider = AppleAuthorizationProvider()
    var operationID: UUID { provider.operationID }
    private(set) var calls = 0
    func configure(_ request: ASAuthorizationAppleIDRequest) throws { try provider.configure(request) }
    func complete(_ result: Result<ASAuthorization, Error>, operationID: UUID) { provider.complete(result, operationID: operationID) }
    func authorization() async throws -> AppleAuthorizationResult { calls += 1; return try await provider.authorization() }
    func resolve(identity: String, code: String) { provider.complete(identityToken: identity, authorizationCode: code, operationID: operationID) }
    func cancel(operationID: UUID) { provider.cancel(operationID: operationID) }
}
