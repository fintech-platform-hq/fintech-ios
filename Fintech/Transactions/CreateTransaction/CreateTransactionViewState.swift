import Foundation

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
    case negativeAmount
    case idempotencyConflict(message: String?)
    case requestRejected(message: String)
    case networkUnavailable
    case submissionCancelled
    case unexpected(message: String)

    var message: String {
        switch self {
        case .invalidAmount:
            "Enter a valid BRL amount with no more than two decimal places."
        case .zeroAmount:
            "The amount must be greater than zero."
        case .negativeAmount:
            "The amount cannot be negative."
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
