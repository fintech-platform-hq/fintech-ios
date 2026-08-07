import Foundation
import XCTest
@testable import Fintech

final class ProductionTransactionSmokeTests: XCTestCase {
    /// WARNING: This test creates one real record in the production database.
    /// It is skipped unless explicitly enabled with a disposable production account.
    func testCreatesAndReplaysProductionTransaction() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["RUN_LIVE_API_TESTS"] == "1",
            "Set RUN_LIVE_API_TESTS=1 to enable the mutating production smoke test."
        )

        guard let rawAccountId = environment["LIVE_API_ACCOUNT_ID"],
              let accountId = UUID(uuidString: rawAccountId) else {
            throw XCTSkip(
                "Set LIVE_API_ACCOUNT_ID to a disposable production account UUID."
            )
        }

        let session = URLSession(configuration: .ephemeral)
        let service = TransactionService(
            apiClient: APIClient(
                baseURL: APIClient.productionBaseURL,
                session: session
            )
        )
        let request = try TransactionRequest(
            accountId: accountId,
            categoryId: nil,
            type: .income,
            amountMinor: 1,
            currency: "BRL",
            description: "Opt-in iOS transaction networking smoke test",
            occurredAt: Date(),
            clientMutationId: UUID()
        )
        let idempotencyKey = UUID()

        let initial = try await service.createTransaction(
            request,
            idempotencyKey: idempotencyKey
        )
        let replay = try await service.createTransaction(
            request,
            idempotencyKey: idempotencyKey
        )

        XCTAssertEqual(initial.id, replay.id)
        XCTAssertEqual(initial.accountId, accountId)
        XCTAssertEqual(initial.amountMinor, 1)
        XCTAssertEqual(initial.currency, "BRL")
    }
}
