import Foundation
import Synchronization
import Testing
@testable import Fintech

@MainActor
struct MvpAccountTests {
    @Test
    func retryAfterTimeoutKeepsTheConfirmedTermsAndKey() async throws {
        let baseURL = URL(string: "https://mvp-retry.unit.test")!
        let posts = Mutex<[URLRequest]>([])
        let completed = Mutex(false)
        URLProtocolStub.install(for: baseURL) { request in
            let isPreview = request.url?.path == "/mvp/account-previews"
            let isOpening = request.httpMethod == "POST" && !isPreview
            if isOpening {
                let count = posts.withLock {
                    $0.append(request)
                    return $0.count
                }
                if count == 1 { return .failure(URLError(.timedOut)) }
                completed.withLock { $0 = true }
            }
            let data = isPreview
                ? Data(#"{"baseMinor":"-5500","coverageStart":"2026-11-01T12:00:00.000000Z","referenceZone":"UTC"}"#.utf8)
                : Self.summary(available: completed.withLock { $0 })
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: isOpening ? 201 : 200,
                httpVersion: nil, headerFields: nil
            ))
            return .response(response, data)
        }
        defer { URLProtocolStub.reset(for: baseURL) }

        let (session, service) = makeService(baseURL)
        let model = MvpAccountViewModel(service: service, session: session)
        await model.load()
        await model.review(amount: "-55,00", start: Date(timeIntervalSince1970: 1_793_534_400), zone: .gmt)
        #expect(model.preview?.baseMinor == "-5500")

        await model.confirm()
        #expect(model.hasPendingOpening)
        await model.confirm()
        #expect(!model.hasPendingOpening)
        guard case let .loaded(summary) = model.state else {
            Issue.record("Expected the canonical account read.")
            return
        }
        #expect(summary.status == .available)
        #expect(summary.balanceMinor == "-5500")

        let requests = posts.withLock { $0 }
        try #require(requests.count == 2)
        let key = try #require(requests.first?.value(forHTTPHeaderField: "Idempotency-Key"))
        #expect(UUID(uuidString: key) != nil)
        #expect(requests.last?.value(forHTTPHeaderField: "Idempotency-Key") == key)
        #expect(requests.first?.httpBody == requests.last?.httpBody)
        #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer fictitious-access")
    }

    @Test
    func failedReadCanRetryWithoutDisplayingAZeroBalance() async throws {
        let baseURL = URL(string: "https://mvp-read.unit.test")!
        let requests = Mutex<[URLRequest]>([])
        URLProtocolStub.install(for: baseURL) { request in
            let count = requests.withLock {
                $0.append(request)
                return $0.count
            }
            if count == 1 { return .failure(URLError(.notConnectedToInternet)) }
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil
            ))
            return .response(response, Self.summary(available: false))
        }
        defer { URLProtocolStub.reset(for: baseURL) }

        let (session, service) = makeService(baseURL)
        let model = MvpAccountViewModel(service: service, session: session)
        await model.load()
        guard case .failed = model.state else {
            Issue.record("Expected a failed account read.")
            return
        }
        await model.load()
        guard case let .loaded(summary) = model.state else {
            Issue.record("Expected a successful retry.")
            return
        }
        #expect(summary.status == .noAccount)
        #expect(summary.balanceMinor == nil)
        let captured = requests.withLock { $0 }
        #expect(captured.count == 2)
        #expect(captured.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
    }

    @Test
    func previousGenerationCannotUseReplacedSession() async {
        let baseURL = URL(string: "https://mvp-generation.unit.test")!
        let observed = Mutex(false)
        URLProtocolStub.install(for: baseURL) { _ in
            observed.withLock { $0 = true }
            return .failure(URLError(.resourceUnavailable))
        }
        defer { URLProtocolStub.reset(for: baseURL) }

        let (session, service) = makeService(baseURL)
        let previous = await session.currentGeneration()
        await session.invalidate()
        await #expect(throws: CancellationError.self) {
            _ = try await service.read(generation: previous)
        }
        #expect(!observed.withLock { $0 })
    }

    @Test
    func amountsUseExactSignedCents() {
        #expect(MvpAccountViewModel.parseMinor("0") == 0)
        #expect(MvpAccountViewModel.parseMinor("900,25") == 90_025)
        #expect(MvpAccountViewModel.parseMinor("-0.5") == -50)
        #expect(MvpAccountViewModel.parseMinor("-92233720368547758,08") == Int64.min)
        #expect(MvpAccountViewModel.parseMinor("92233720368547758,08") == nil)
        #expect(MvpAccountViewModel.parseMinor("1,234") == nil)
        #expect(MvpAccountViewModel.money("-9223372036854775809") == "-R$ 92233720368547758,09")
    }

    private nonisolated static func summary(available: Bool) -> Data {
        if available {
            Data("""
                {"principalId":"7a6ac2d9-2904-4002-88e1-7a472365a584","account":null,
                "legacyAccounts":[],"status":"available","base":null,"balanceMinor":"-5500",
                "revision":"1","asOf":"2026-11-01T12:01:00.000000Z"}
                """.utf8)
        } else {
            Data("""
                {"principalId":"7a6ac2d9-2904-4002-88e1-7a472365a584","account":null,
                "legacyAccounts":[],"status":"no_account","base":null,"balanceMinor":null,
                "revision":null,"asOf":"2026-11-01T12:00:00.000000Z"}
                """.utf8)
        }
    }

    private func makeService(_ baseURL: URL) -> (AuthenticationSession, MvpAccountService) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let transport = URLSession(configuration: configuration)
        let session = AuthenticationSession(
            service: AuthenticationService(apiClient: APIClient(baseURL: baseURL, session: transport)),
            credentialStore: MvpTestCredentialStore()
        )
        let service = MvpAccountService(
            apiClient: APIClient(baseURL: baseURL, session: transport, authenticationSession: session)
        )
        return (session, service)
    }
}

private actor MvpTestCredentialStore: CredentialStoring {
    func load() async throws -> AuthTokens? {
        AuthTokens(
            accessToken: "fictitious-access", refreshToken: "fictitious-refresh",
            tokenType: "Bearer", expiresIn: 900
        )
    }
    func save(_ tokens: AuthTokens) async throws {}
    func delete() async throws {}
}
