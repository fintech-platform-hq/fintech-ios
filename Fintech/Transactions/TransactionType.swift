import Foundation

nonisolated enum TransactionType: String, Codable, Equatable, Sendable {
    case debit
    case credit
}
