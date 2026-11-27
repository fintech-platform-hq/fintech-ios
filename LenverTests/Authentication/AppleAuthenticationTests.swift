import Foundation
import AuthenticationServices
import Synchronization
import Testing
@testable import Lenver

@Suite(.serialized, .timeLimit(.minutes(1)))
struct AppleAuthenticationTests {
    private let baseURL = URL(string: "https://apple-auth.unit.test/api")!

    @Test
    func nonceUses32RandomBytesAndUnpaddedBase64URL() throws {
        let nonce = try AppleNonce.make()
        let decoded = try #require(Data(base64URLEncoded: nonce))
        #expect(decoded.count == 32)
        #expect(!nonce.contains("="))
        #expect(nonce.allSatisfy { $0.isNumber || $0.isLetter || $0 == "-" || $0 == "_" })
    }

    @Test
    func signInWithApplePostsOneExactPayloadAndDecodesLenverTokens() async throws {
        let requests = Mutex<[URLRequest]>([])
        URLProtocolStub.install(for: baseURL) { request in
            requests.withLock { $0.append(request) }
            return .response(
                HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"accessToken":"a","refreshToken":"r","tokenType":"Bearer","expiresIn":900}"#.utf8)
            )
        }
        defer { URLProtocolStub.reset(for: baseURL) }

        let authorization = AppleAuthorizationResult(
            identityToken: "identity", authorizationCode: "code", nonce: String(repeating: "n", count: 43)
        )
        let service = AuthenticationService(
            apiClient: APIClient(baseURL: baseURL, session: appleURLSession())
        )
        let tokens = try await service.signInWithApple(authorization)

        let captured = try #require(requests.withLock { $0.first })
        #expect(requests.withLock { $0.count } == 1)
        #expect(captured.url?.path == "/api/auth/apple")
        let body = try #require(captured.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["identityToken"] == "identity")
        #expect(json["authorizationCode"] == "code")
        #expect(json["nonce"] == authorization.nonce)
        #expect(tokens.accessToken == "a")
        #expect(tokens.refreshToken == "r")
    }

    @Test
    func fakeProviderCanDriveOneAppleSessionWithoutPersistingAppleArtifacts() async throws {
        let store = AppleTestStore()
        let result = AppleAuthorizationResult(
            identityToken: "identity", authorizationCode: "code", nonce: String(repeating: "n", count: 43)
        )
        let provider = await MainActor.run { FakeAppleProvider(result: result) }
        let service = AuthenticationService(
            apiClient: APIClient(baseURL: baseURL, session: appleURLSession())
        )
        URLProtocolStub.install(for: baseURL) { request in
            .response(
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!,
                Data(#"{"accessToken":"a","refreshToken":"r","tokenType":"Bearer","expiresIn":900}"#.utf8)
            )
        }
        defer { URLProtocolStub.reset(for: baseURL) }

        let session = AuthenticationSession(service: service, credentialStore: store)
        try await session.signInWithApple(using: provider)
        #expect(try await store.load()?.accessToken == "a")
        #expect(await provider.calls() == 1)
    }

    @MainActor
    @Test
    func concreteProviderUsesConfiguredNonceAndConsumesEarlyCompletionOnce() async throws {
        let provider = AppleAuthorizationProvider()
        let operationID = provider.operationID
        let request = ASAuthorizationAppleIDProvider().createRequest()
        try provider.configure(request)
        provider.complete(identityToken: "identity", authorizationCode: "code", operationID: operationID)
        provider.complete(.failure(ASAuthorizationError(.canceled)), operationID: operationID)
        let result = try await provider.authorization()
        #expect(result.nonce == request.nonce)
        #expect(result.identityToken == "identity")
        await #expect(throws: AuthenticationError.invalidTokenResponse) { try await provider.authorization() }
        provider.complete(identityToken: "duplicate", authorizationCode: "duplicate", operationID: operationID)

        let capturedNonce = Mutex<String?>(nil)
        URLProtocolStub.install(for: baseURL) { request in
            let data = try #require(request.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
            capturedNonce.withLock { $0 = json["nonce"] }
            return .response(
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"accessToken":"a","refreshToken":"r","tokenType":"Bearer","expiresIn":900}"#.utf8)
            )
        }
        defer { URLProtocolStub.reset(for: baseURL) }
        let service = AuthenticationService(apiClient: APIClient(baseURL: baseURL, session: appleURLSession()))
        _ = try await service.signInWithApple(result)
        #expect(capturedNonce.withLock { $0 } == request.nonce)
    }

    @MainActor
    @Test
    func providerRejectsSecondOperationAndHandlesCompletionAfterWaiting() async throws {
        let provider = AppleAuthorizationProvider()
        let operationID = provider.operationID
        try provider.configure(ASAuthorizationAppleIDProvider().createRequest())
        #expect(throws: AuthenticationError.operationInProgress) {
            try provider.configure(ASAuthorizationAppleIDProvider().createRequest())
        }
        let waiting = AppleWaitBarrier()
        let first = Task { try await provider.authorization(onWait: { waiting.signal() }) }
        await waiting.wait()
        await #expect(throws: AuthenticationError.operationInProgress) { try await provider.authorization() }
        provider.complete(identityToken: "identity", authorizationCode: "code", operationID: operationID)
        provider.complete(identityToken: "duplicate", authorizationCode: "duplicate", operationID: operationID)
        #expect(try await first.value.identityToken == "identity")
        try provider.configure(ASAuthorizationAppleIDProvider().createRequest())
        provider.complete(.failure(ASAuthorizationError(.canceled)), operationID: provider.operationID)
        await #expect(throws: ASAuthorizationError(.canceled)) { try await provider.authorization() }
    }

    @MainActor
    @Test
    func providerCancellationResumesWaitAndAllowsNextOperation() async throws {
        let provider = AppleAuthorizationProvider()
        try provider.configure(ASAuthorizationAppleIDProvider().createRequest())
        let waiting = AppleWaitBarrier()
        let first = Task { try await provider.authorization(onWait: { waiting.signal() }) }
        await waiting.wait()
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        try provider.configure(ASAuthorizationAppleIDProvider().createRequest())
        provider.complete(identityToken: "next", authorizationCode: "next-code", operationID: provider.operationID)
        #expect(try await provider.authorization().identityToken == "next")
    }

    @MainActor
    @Test
    func cancellationBeforeWaitRegistrationCannotLeaveContinuationSuspended() async throws {
        let provider = AppleAuthorizationProvider()
        try provider.configure(ASAuthorizationAppleIDProvider().createRequest())
        let first = Task { try await provider.authorization() }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        try provider.configure(ASAuthorizationAppleIDProvider().createRequest())
        provider.complete(identityToken: "next", authorizationCode: "code", operationID: provider.operationID)
        #expect(try await provider.authorization().identityToken == "next")
    }

    @MainActor
    @Test(arguments: [false, true])
    func lateCallbackCannotCompleteNextOperation(_ cancelFirst: Bool) async throws {
        let provider = AppleAuthorizationProvider()
        let operationA = provider.operationID
        try provider.configure(ASAuthorizationAppleIDProvider().createRequest())
        let waitingA = AppleWaitBarrier()
        let first = Task { try await provider.authorization(onWait: { waitingA.signal() }) }
        await waitingA.wait()
        if cancelFirst {
            first.cancel()
            await #expect(throws: CancellationError.self) { try await first.value }
        } else {
            provider.complete(identityToken: "A", authorizationCode: "code-A", operationID: operationA)
            #expect(try await first.value.identityToken == "A")
        }

        let operationB = provider.operationID
        #expect(operationB != operationA)
        let requestB = ASAuthorizationAppleIDProvider().createRequest()
        try provider.configure(requestB)
        let waitingB = AppleWaitBarrier()
        var completedB = false
        let second = Task {
            let result = try await provider.authorization(onWait: { waitingB.signal() })
            completedB = true
            return result
        }
        await waitingB.wait()
        provider.complete(.failure(ASAuthorizationError(.canceled)), operationID: operationA)
        provider.complete(identityToken: "late-A", authorizationCode: "code-A", operationID: operationA)
        provider.complete(identityToken: "duplicate-A", authorizationCode: "code-A", operationID: operationA)
        // A second waiter is rejected only while B's original continuation remains installed.
        await #expect(throws: AuthenticationError.operationInProgress) { try await provider.authorization() }
        #expect(!completedB)
        provider.complete(identityToken: "B", authorizationCode: "code-B", operationID: operationB)
        let resultB = try await second.value
        #expect(completedB)
        #expect(resultB.identityToken == "B")
        #expect(resultB.authorizationCode == "code-B")
        #expect(resultB.nonce == requestB.nonce)
    }

    @Test(arguments: [URLError.Code.timedOut, .networkConnectionLost])
    func ambiguousApplePOSTIsSentOnlyOnce(_ code: URLError.Code) async throws {
        let requests = Mutex(0)
        URLProtocolStub.install(for: baseURL) { _ in
            requests.withLock { $0 += 1 }
            return .failure(URLError(code))
        }
        defer { URLProtocolStub.reset(for: baseURL) }
        let store = AppleTestStore()
        let provider = await MainActor.run {
            FakeAppleProvider(result: AppleAuthorizationResult(identityToken: "identity", authorizationCode: "code", nonce: "nonce"))
        }
        let session = AuthenticationSession(
            service: AuthenticationService(apiClient: APIClient(baseURL: baseURL, session: appleURLSession())),
            credentialStore: store
        )
        await #expect(throws: AuthenticationError.request(.transport(code: code))) {
            try await session.signInWithApple(using: provider)
        }
        #expect(requests.withLock { $0 } == 1)
        #expect(await provider.calls() == 1)
        #expect(try await store.load() == nil)
    }

    @MainActor
    @Test
    func appleSignInDoesNotRequireEmailOrPassword() async throws {
        let service = ControlledAuthenticationService()
        let store = ControlledCredentialStore()
        let provider = FakeAppleProvider(result: AppleAuthorizationResult(identityToken: "identity", authorizationCode: "code", nonce: "nonce"))
        let model = AuthenticationViewModel(session: AuthenticationSession(service: service, credentialStore: store), appleProvider: provider)
        #expect(model.email.isEmpty && model.password.isEmpty)
        await model.signInWithApple()
        #expect(model.state == .authenticated)
        #expect(await service.appleCalls == 1)
        #expect(try await store.load()?.refreshToken == "replacement-refresh")
    }

    @MainActor
    @Test(arguments: [true, false])
    func authorizationCancellationReturnsToNormalState(_ appleCancellation: Bool) async {
        let service = ControlledAuthenticationService()
        let provider = CancelledAppleProvider(appleCancellation: appleCancellation)
        let model = AuthenticationViewModel(session: AuthenticationSession(service: service, credentialStore: ControlledCredentialStore()), appleProvider: provider)
        await model.signInWithApple()
        #expect(model.state == .unauthenticated)
        #expect(await service.appleCalls == 0)
    }

    @MainActor
    @Test
    func transportFailureAfterApplePOSTRemainsAnError() async {
        let service = ControlledAuthenticationService()
        await service.setAppleFailure(.request(.transport(code: .cancelled)))
        let provider = FakeAppleProvider(result: AppleAuthorizationResult(identityToken: "identity", authorizationCode: "code", nonce: "nonce"))
        let model = AuthenticationViewModel(session: AuthenticationSession(service: service, credentialStore: ControlledCredentialStore()), appleProvider: provider)
        await model.signInWithApple()
        #expect(model.state == .failure(.signInUnavailable))
        #expect(await service.appleCalls == 1)
    }

    private func appleURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }
}

@MainActor
private final class AppleWaitBarrier {
    private var signaled = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if signaled { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func signal() {
        signaled = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class CancelledAppleProvider: AppleAuthorizationProviding {
    let operationID = UUID()
    let appleCancellation: Bool
    init(appleCancellation: Bool) { self.appleCancellation = appleCancellation }
    func configure(_ request: ASAuthorizationAppleIDRequest) throws {}
    func complete(_ result: Result<ASAuthorization, Error>, operationID: UUID) {}
    func authorization() async throws -> AppleAuthorizationResult {
        if appleCancellation { throw ASAuthorizationError(.canceled) }
        throw CancellationError()
    }
}

@MainActor
private final class FakeAppleProvider: AppleAuthorizationProviding {
    let operationID = UUID()
    let result: AppleAuthorizationResult
    private(set) var authorizationCalls = 0

    init(result: AppleAuthorizationResult) { self.result = result }
    func configure(_ request: ASAuthorizationAppleIDRequest) throws {}
    func authorization() async throws -> AppleAuthorizationResult {
        authorizationCalls += 1
        return result
    }
    func complete(_ result: Result<ASAuthorization, Error>, operationID: UUID) {}
    func calls() -> Int { authorizationCalls }
}

private actor AppleTestStore: CredentialStoring {
    private var tokens: AuthTokens?
    func load() async throws -> AuthTokens? { tokens }
    func save(_ tokens: AuthTokens) async throws { self.tokens = tokens }
    func delete() async throws { tokens = nil }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        let padded = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: padded + String(repeating: "=", count: (4 - padded.count % 4) % 4))
    }
}
