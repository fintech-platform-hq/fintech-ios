import Foundation

nonisolated struct TransactionRequest: Encodable, Equatable, Sendable {
    enum ValidationError: Error, Equatable, Sendable {
        case nonPositiveAmount
        case invalidCurrency
    }

    let accountId: UUID
    let categoryId: UUID?
    let type: TransactionType
    let amountMinor: Int
    let currency: String
    let description: String?
    let occurredAt: Date
    let clientMutationId: UUID

    init(
        accountId: UUID,
        categoryId: UUID?,
        type: TransactionType,
        amountMinor: Int,
        currency: String,
        description: String?,
        occurredAt: Date,
        clientMutationId: UUID
    ) throws {
        guard amountMinor > 0 else {
            throw ValidationError.nonPositiveAmount
        }

        guard currency.utf8.count == 3,
              currency.utf8.allSatisfy({ (65...90).contains($0) }) else {
            throw ValidationError.invalidCurrency
        }

        self.accountId = accountId
        self.categoryId = categoryId
        self.type = type
        self.amountMinor = amountMinor
        self.currency = currency
        self.description = description
        self.occurredAt = occurredAt
        self.clientMutationId = clientMutationId
    }

    private enum CodingKeys: String, CodingKey {
        case accountId
        case categoryId
        case type
        case amountMinor
        case currency
        case description
        case occurredAt
        case clientMutationId
    }
}
