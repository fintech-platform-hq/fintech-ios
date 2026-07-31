import Foundation

nonisolated struct TransactionResponse: Decodable, Equatable, Identifiable, Sendable {
    let id: UUID
    let accountId: UUID
    let categoryId: UUID?
    let type: TransactionType
    let amountMinor: Int
    let currency: String
    let description: String?
    let occurredAt: Date
    let createdAt: Date
}
