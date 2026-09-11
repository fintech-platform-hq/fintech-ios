import Foundation
import Synchronization
import Testing
@testable import Fintech

@Suite(.serialized)
struct APIClientTests {
    private let baseURL = URL(string: "https://unit.test/api")!
    private let accountId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let categoryId = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private let clientMutationId = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let transactionId = UUID(uuidString: "6aef7ec3-58fb-4ac7-8ff2-920e90ce0b4c")!
    private let idempotencyKey = UUID(uuidString: "c58adfa4-c6e0-47d9-9a37-90b07c65fcf8")!

    @Test
    func successfulRequestEncodesAndDecodesVerifiedContract() async throws {
        let capturedRequests = Mutex<[URLRequest]>([])
        URLProtocolStub.install(for: baseURL) { request in
            capturedRequests.withLock { $0.append(request) }
            return .response(
                try httpResponse(for: request, statusCode: 201),
                successResponseData(
                    categoryId: categoryId,
                    description: "Salary"
                )
            )
        }
        defer { URLProtocolStub.reset(for: baseURL) }

        let response = try await makeService().createTransaction(
            makeRequest(categoryId: categoryId, description: "Salary"),
            idempotencyKey: idempotencyKey
        )

        let capturedRequest = try #require(capturedRequests.withLock { $0.first })
        let body = try #require(capturedRequest.httpBody)
        let json = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )

        #expect(capturedRequest.httpMethod == "POST")
        #expect(capturedRequest.url == URL(string: "https://unit.test/api/transactions"))
        #expect(capturedRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(capturedRequest.value(forHTTPHeaderField: "Idempotency-Key") == idempotencyKey.uuidString)
        #expect(
            Set(json.keys) == Set([
                "accountId",
                "categoryId",
                "type",
                "amountMinor",
                "currency",
                "description",
                "occurredAt",
                "clientMutationId",
            ])
        )
        #expect(json["accountId"] as? String == accountId.uuidString)
        #expect(json["categoryId"] as? String == categoryId.uuidString)
        #expect(json["type"] as? String == "income")
        #expect(json["amountMinor"] as? Int == 15_000)
        #expect(json["currency"] as? String == "BRL")
        #expect(json["description"] as? String == "Salary")
        #expect(json["occurredAt"] as? String == "2026-07-30T18:00:00.000Z")
        #expect(json["clientMutationId"] as? String == clientMutationId.uuidString)

        #expect(response.id == transactionId)
        #expect(response.accountId == accountId)
        #expect(response.categoryId == categoryId)
        #expect(response.type == .income)
        #expect(response.amountMinor == 15_000)
        #expect(response.currency == "BRL")
        #expect(response.description == "Salary")
        #expect(response.occurredAt == date("2026-07-30T18:00:00.000Z"))
        #expect(response.createdAt == date("2026-07-30T18:00:01.421Z"))
    }

    @Test
    func expenseRequestEncodesAndDecodesUpdatedContract() async throws {
        let capturedRequests = Mutex<[URLRequest]>([])
        URLProtocolStub.install(for: baseURL) { request in
            capturedRequests.withLock { $0.append(request) }
            return .response(
                try httpResponse(for: request, statusCode: 201),
                successResponseData(type: .expense)
            )
        }
        defer { URLProtocolStub.reset(for: baseURL) }

        let response = try await makeService().createTransaction(
            makeRequest(type: .expense),
            idempotencyKey: idempotencyKey
        )

        let request = try #require(capturedRequests.withLock { $0.first })
        let body = try #require(request.httpBody)
        let json = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )

        #expect(json["type"] as? String == "expense")
        #expect(response.type == .expense)
    }

    @Test
    func callerDirectedReplayKeepsHeaderAndPayloadStable() async throws {
        let capturedRequests = Mutex<[URLRequest]>([])
        URLProtocolStub.install(for: baseURL) { request in
            capturedRequests.withLock { $0.append(request) }
            return .response(
                try httpResponse(for: request, statusCode: 201),
                successResponseData()
            )
        }
        defer { URLProtocolStub.reset(for: baseURL) }

        let service = makeService()
        let request = try makeRequest(categoryId: nil, description: nil)

        let initial = try await service.createTransaction(
            request,
            idempotencyKey: idempotencyKey
        )
        let replay = try await service.createTransaction(
            request,
            idempotencyKey: idempotencyKey
        )

        let requests = capturedRequests.withLock { $0 }
        #expect(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "Idempotency-Key") == idempotencyKey.uuidString)
        #expect(requests[1].value(forHTTPHeaderField: "Idempotency-Key") == idempotencyKey.uuidString)
        #expect(requests[0].httpBody == requests[1].httpBody)
        #expect(initial.id == replay.id)

        let body = try #require(requests[0].httpBody)
        let json = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(json["categoryId"] == nil)
        #expect(json["description"] == nil)
    }

    @Test
    func responseDecodingAcceptsRFC3339WithoutFractionalSeconds() async throws {
        URLProtocolStub.install(for: baseURL) { request in
            .response(
                try httpResponse(for: request, statusCode: 201),
                successResponseData(
                    occurredAt: "2026-07-30T18:00:00Z",
                    createdAt: "2026-07-30T18:00:01Z"
                )
            )
        }
        defer { URLProtocolStub.reset(for: baseURL) }

        let response = try await makeService().createTransaction(
            makeRequest(),
            idempotencyKey: idempotencyKey
        )

        #expect(response.occurredAt == date("2026-07-30T18:00:00Z"))
        #expect(response.createdAt == date("2026-07-30T18:00:01Z"))
    }

    @Test
    func backendValidationArrayMapsToBadRequest() async throws {
        URLProtocolStub.install(for: baseURL) { request in
            .response(
                try httpResponse(for: request, statusCode: 400),
                Data(
                    """
                    {
                      "statusCode": 400,
                      "message": ["clientMutationId must be a UUID"],
                      "error": "Bad Request"
                    }
                    """.utf8
                )
            )
        }
        defer { URLProtocolStub.reset(for: baseURL) }

        await expectAPIError(
            .badRequest(messages: ["clientMutationId must be a UUID"])
        ) {
            try await makeService().createTransaction(
                makeRequest(),
                idempotencyKey: idempotencyKey
            )
        }
    }

    @Test
    func backendValidationStringMapsToBadRequest() async throws {
        URLProtocolStub.install(for: baseURL) { request in
            .response(
                try httpResponse(for: request, statusCode: 400),
                Data(
                    """
                    {
                      "statusCode": 400,
                      "message": "Idempotency key required",
                      "error": "Bad Request"
                    }
                    """.utf8
                )
            )
        }
        defer { URLProtocolStub.reset(for: baseURL) }

        await expectAPIError(
            .badRequest(messages: ["Idempotency key required"])
        ) {
            try await makeService().createTransaction(
                makeRequest(),
                idempotencyKey: idempotencyKey
            )
        }
    }

    @Test
    func idempotencyConflictMapsToFocusedError() async throws {
        let message = "Idempotency key was already used with a different request"
        URLProtocolStub.install(for: baseURL) { request in
            .response(
                try httpResponse(for: request, statusCode: 409),
                Data(
                    """
                    {
                      "statusCode": 409,
                      "message": "\(message)",
                      "error": "Conflict"
                    }
                    """.utf8
                )
            )
        }
        defer { URLProtocolStub.reset(for: baseURL) }

        await expectAPIError(.idempotencyConflict(message: message)) {
            try await makeService().createTransaction(
                makeRequest(),
                idempotencyKey: idempotencyKey
            )
        }
    }

    @Test
    func serverFailureMapsWithoutRawBody() async throws {
        URLProtocolStub.install(for: baseURL) { request in
            .response(
                try httpResponse(for: request, statusCode: 503),
                Data(
                    """
                    {
                      "statusCode": 503,
                      "message": "Service unavailable",
                      "error": "Service Unavailable",
                      "internalDetail": "must not be surfaced"
                    }
                    """.utf8
                )
            )
        }
        defer { URLProtocolStub.reset(for: baseURL) }

        await expectAPIError(
            .server(statusCode: 503, message: "Service unavailable")
        ) {
            try await makeService().createTransaction(
                makeRequest(),
                idempotencyKey: idempotencyKey
            )
        }
    }

    @Test
    func unexpectedStatusMapsToHTTPError() async throws {
        URLProtocolStub.install(for: baseURL) { request in
            .response(
                try httpResponse(for: request, statusCode: 418),
                Data(
                    """
                    {"statusCode": 418, "message": "Unexpected", "error": "Teapot"}
                    """.utf8
                )
            )
        }
        defer { URLProtocolStub.reset(for: baseURL) }

        await expectAPIError(.http(statusCode: 418, message: "Unexpected")) {
            try await makeService().createTransaction(
                makeRequest(),
                idempotencyKey: idempotencyKey
            )
        }
    }

    @Test
    func malformedSuccessResponseMapsToDecodingError() async throws {
        URLProtocolStub.install(for: baseURL) { request in
            .response(
                try httpResponse(for: request, statusCode: 201),
                Data(#"{"id":"not-a-uuid"}"#.utf8)
            )
        }
        defer { URLProtocolStub.reset(for: baseURL) }

        await expectAPIError(.decoding) {
            try await makeService().createTransaction(
                makeRequest(),
                idempotencyKey: idempotencyKey
            )
        }
    }

    @Test
    func nonHTTPResponseMapsToInvalidResponse() async throws {
        URLProtocolStub.install(for: baseURL) { request in
            .response(
                URLResponse(
                    url: try #require(request.url),
                    mimeType: "application/json",
                    expectedContentLength: 0,
                    textEncodingName: nil
                ),
                Data()
            )
        }
        defer { URLProtocolStub.reset(for: baseURL) }

        await expectAPIError(.invalidResponse) {
            try await makeService().createTransaction(
                makeRequest(),
                idempotencyKey: idempotencyKey
            )
        }
    }

    @Test
    func URLSessionFailureMapsToTransportError() async throws {
        URLProtocolStub.install(for: baseURL) { _ in
            .failure(URLError(.notConnectedToInternet))
        }
        defer { URLProtocolStub.reset(for: baseURL) }

        await expectAPIError(.transport(code: .notConnectedToInternet)) {
            try await makeService().createTransaction(
                makeRequest(),
                idempotencyKey: idempotencyKey
            )
        }
    }

    @Test
    func taskCancellationPropagates() async throws {
        URLProtocolStub.install(for: baseURL) { _ in .pending }
        defer { URLProtocolStub.reset(for: baseURL) }

        let service = makeService()
        let request = try makeRequest()
        let key = idempotencyKey
        let task = Task {
            try await service.createTransaction(request, idempotencyKey: key)
        }

        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation.")
        } catch is CancellationError {
            // Expected: cancellation remains cancellation rather than becoming APIError.
        } catch {
            Issue.record("Expected CancellationError, received \(error).")
        }
    }

    private func makeService() -> TransactionService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        return TransactionService(
            apiClient: APIClient(baseURL: baseURL, session: session)
        )
    }

    private func makeRequest(
        categoryId: UUID? = nil,
        description: String? = nil,
        type: TransactionType = .income
    ) throws -> TransactionRequest {
        try TransactionRequest(
            accountId: accountId,
            categoryId: categoryId,
            type: type,
            amountMinor: 15_000,
            currency: "BRL",
            description: description,
            occurredAt: date("2026-07-30T18:00:00.000Z"),
            clientMutationId: clientMutationId
        )
    }

    private func successResponseData(
        occurredAt: String = "2026-07-30T18:00:00.000Z",
        createdAt: String = "2026-07-30T18:00:01.421Z",
        categoryId: UUID? = nil,
        description: String? = nil,
        type: TransactionType = .income
    ) -> Data {
        let categoryIdJSON = categoryId.map { "\"\($0.uuidString)\"" } ?? "null"
        let descriptionJSON = description.map { "\"\($0)\"" } ?? "null"

        return Data(
            """
            {
              "id": "\(transactionId.uuidString)",
              "accountId": "\(accountId.uuidString)",
              "categoryId": \(categoryIdJSON),
              "type": "\(type.rawValue)",
              "amountMinor": 15000,
              "currency": "BRL",
              "description": \(descriptionJSON),
              "occurredAt": "\(occurredAt)",
              "createdAt": "\(createdAt)"
            }
            """.utf8
        )
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.date(from: value)!
    }

    private func expectAPIError(
        _ expectedError: APIError,
        operation: () async throws -> TransactionResponse
    ) async {
        do {
            _ = try await operation()
            Issue.record("Expected \(expectedError).")
        } catch let error as APIError {
            #expect(error == expectedError)
        } catch {
            Issue.record("Expected APIError, received \(error).")
        }
    }
}

private func httpResponse(
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
