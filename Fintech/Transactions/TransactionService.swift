import Foundation

nonisolated struct TransactionService: Sendable {
    private let apiClient: APIClient

    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    func createTransaction(
        _ request: TransactionRequest,
        idempotencyKey: UUID
    ) async throws -> TransactionResponse {
        try await apiClient.post(
            path: "/transactions",
            body: request,
            headers: ["Idempotency-Key": idempotencyKey.uuidString],
            expectedStatusCode: 201
        )
    }
}
