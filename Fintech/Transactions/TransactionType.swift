import Foundation

nonisolated enum TransactionType: String, CaseIterable, Codable, Equatable, Sendable {
    case expense
    case income

    var displayName: String {
        switch self {
        case .expense:
            "Expense"
        case .income:
            "Income"
        }
    }

    var amountPresentationSign: String {
        switch self {
        case .expense:
            "-"
        case .income:
            "+"
        }
    }
}
