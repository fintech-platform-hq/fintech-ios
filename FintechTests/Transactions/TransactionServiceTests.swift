import Foundation
import Testing
@testable import Fintech

struct TransactionServiceTests {
    private let accountId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let clientMutationId = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    @Test(arguments: [0, -1])
    func requestRejectsNonPositiveMinorUnits(amountMinor: Int) {
        #expect(throws: TransactionRequest.ValidationError.nonPositiveAmount) {
            try makeRequest(amountMinor: amountMinor)
        }
    }

    @Test(arguments: ["brl", "BR", "BRL1", "ÉUR"])
    func requestRejectsInvalidCurrency(currency: String) {
        #expect(throws: TransactionRequest.ValidationError.invalidCurrency) {
            try makeRequest(currency: currency)
        }
    }

    @Test
    func requestAcceptsPositiveMinorUnitsAndUppercaseASCIICurrency() throws {
        let request = try makeRequest(amountMinor: 1, currency: "BRL")

        #expect(request.amountMinor == 1)
        #expect(request.currency == "BRL")
    }

    @Test
    func transactionTypesExposeOnlyExpenseAndIncomeWireValues() {
        #expect(
            Set(TransactionType.allCases.map(\.rawValue))
                == Set(["expense", "income"])
        )
    }

    private func makeRequest(
        amountMinor: Int = 1,
        currency: String = "BRL"
    ) throws -> TransactionRequest {
        try TransactionRequest(
            accountId: accountId,
            categoryId: nil,
            type: .expense,
            amountMinor: amountMinor,
            currency: currency,
            description: nil,
            occurredAt: Date(timeIntervalSince1970: 0),
            clientMutationId: clientMutationId
        )
    }
}
