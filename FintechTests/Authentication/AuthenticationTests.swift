import Foundation
import Synchronization
import Testing
@testable import Fintech

@Suite(.serialized)
struct AuthenticationTests {
    private let baseURL = URL(string: "https://authentication.unit.test/api")!

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
        let store = InMemoryCredentialStore(tokens: oldTokens)
        let transactionCalls = Mutex(0)
        let refreshCalls = Mutex(0)

        URLProtocolStub.install(for: baseURL) { request in
            switch request.url?.path {
            case "/api/auth/refresh":
                refreshCalls.withLock { $0 += 1 }
                return .response(
                    try response(for: request, statusCode: 200),
                    tokenData(accessToken: "new-access", refreshToken: "new-refresh")
                )
            case "/api/transactions":
                let call = transactionCalls.withLock { count in
                    count += 1
                    return count
                }
                let status = call <= 3 ? 401 : 201
                return .response(
                    try response(for: request, statusCode: status),
                    status == 201 ? Data(#"{"value":"ok"}"#.utf8) : Data()
                )
            default:
                throw URLError(.badURL)
            }
        }
        defer { URLProtocolStub.reset(for: baseURL) }

        let client = makeAuthenticatedClient(store: store)
        let results = try await withThrowingTaskGroup(of: ProbeResponse.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    try await client.post(
                        path: "/transactions",
                        body: ProbeRequest(value: "stable"),
                        headers: [:],
                        expectedStatusCode: 201
                    )
                }
            }

            var values: [ProbeResponse] = []
            for try await result in group {
                values.append(result)
            }
            return values
        }

        #expect(results.count == 3)
        #expect(transactionCalls.withLock { $0 } == 6)
        #expect(refreshCalls.withLock { $0 } == 1)
        #expect(try await store.load()?.accessToken == "new-access")
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

        await #expect(throws: APIError.unauthorized(messages: [])) {
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

    private func tokenData(accessToken: String, refreshToken: String) -> Data {
        Data(
            "{\"accessToken\":\"\(accessToken)\",\"refreshToken\":\"\(refreshToken)\",\"tokenType\":\"Bearer\",\"expiresIn\":900}".utf8
        )
    }
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
