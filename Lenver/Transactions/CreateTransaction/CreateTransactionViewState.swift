import Foundation

nonisolated struct CreateTransactionSuccessSnapshot: Equatable, Sendable {
    let transactionID: UUID
    let amountMinor: Int
    let type: TransactionType
    let description: String?
}

nonisolated enum CreateTransactionViewState: Equatable, Sendable {
    case idle
    case validating
    case submitting
    case success(transactionID: UUID)
    case failure(CreateTransactionDisplayError)

    var isBusy: Bool {
        switch self {
        case .validating, .submitting:
            true
        case .idle, .success, .failure:
            false
        }
    }

    var isSuccess: Bool {
        if case .success = self {
            true
        } else {
            false
        }
    }
}

nonisolated enum CreateTransactionDisplayError: Error, Equatable, Sendable {
    case invalidAmount
    case zeroAmount
    case idempotencyConflict(message: String?)
    case requestRejected(message: String)
    case networkUnavailable
    case submissionCancelled
    case unexpected(message: String)

    var message: String {
        switch self {
        case .invalidAmount:
            "Enter an amount."
        case .zeroAmount:
            "The amount must be greater than zero."
        case let .idempotencyConflict(message):
            message ?? "This submission conflicts with an earlier transaction request."
        case let .requestRejected(message):
            message
        case .networkUnavailable:
            "The transaction could not be submitted because of a network error."
        case .submissionCancelled:
            "The transaction submission was cancelled."
        case let .unexpected(message):
            message
        }
    }
}
