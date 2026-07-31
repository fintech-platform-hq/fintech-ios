import Foundation
import Observation

@MainActor
@Observable
final class CreateTransactionViewModel {
    var amountText: String {
        didSet { formDidChange() }
    }

    var transactionType: TransactionType {
        didSet { formDidChange() }
    }

    var descriptionText: String {
        didSet { formDidChange() }
    }

    private(set) var state: CreateTransactionViewState

    private let service: any TransactionCreating
    private let disposableDemoAccountID: UUID
    private let makeUUID: () -> UUID
    private let now: () -> Date
    private var pendingOperation: PendingOperation?

    init(
        service: any TransactionCreating,
        disposableDemoAccountID: UUID,
        amountText: String = "",
        transactionType: TransactionType = .debit,
        descriptionText: String = "",
        initialState: CreateTransactionViewState = .idle,
        makeUUID: @escaping () -> UUID = UUID.init,
        now: @escaping () -> Date = Date.init
    ) {
        self.service = service
        self.disposableDemoAccountID = disposableDemoAccountID
        self.amountText = amountText
        self.transactionType = transactionType
        self.descriptionText = descriptionText
        self.state = initialState
        self.makeUUID = makeUUID
        self.now = now
    }

    func submit() async {
        guard !state.isBusy, !state.isSuccess else {
            return
        }

        state = .validating
        await Task.yield()

        let operation: PendingOperation

        do {
            operation = try pendingOperation ?? makeOperation()
            pendingOperation = operation
        } catch let error as CreateTransactionDisplayError {
            state = .failure(error)
            return
        } catch {
            state = .failure(.unexpected(message: "The transaction could not be prepared."))
            return
        }

        guard !Task.isCancelled else {
            state = .failure(.submissionCancelled)
            return
        }

        state = .submitting

        do {
            let response = try await service.createTransaction(
                operation.request,
                idempotencyKey: operation.idempotencyKey
            )
            state = .success(transactionID: response.id)
        } catch is CancellationError {
            state = .failure(.submissionCancelled)
        } catch let error as APIError {
            state = .failure(Self.displayError(for: error))
        } catch {
            state = .failure(
                .unexpected(message: "The transaction could not be submitted.")
            )
        }
    }

    private func makeOperation() throws -> PendingOperation {
        let amountMinor = try Self.amountMinor(from: amountText)
        let trimmedDescription = descriptionText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let idempotencyKey = makeUUID()
        let clientMutationID = makeUUID()
        let request = try TransactionRequest(
            accountId: disposableDemoAccountID,
            categoryId: nil,
            type: transactionType,
            amountMinor: amountMinor,
            currency: "BRL",
            description: trimmedDescription.isEmpty ? nil : trimmedDescription,
            occurredAt: now(),
            clientMutationId: clientMutationID
        )

        return PendingOperation(
            request: request,
            idempotencyKey: idempotencyKey
        )
    }

    private func formDidChange() {
        guard !state.isBusy else {
            return
        }

        pendingOperation = nil
        state = .idle
    }

    private static func amountMinor(from input: String) throws -> Int {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("-") {
            throw CreateTransactionDisplayError.negativeAmount
        }

        guard !trimmed.isEmpty, !trimmed.hasPrefix("+") else {
            throw CreateTransactionDisplayError.invalidAmount
        }

        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        let components = normalized.split(
            separator: ".",
            omittingEmptySubsequences: false
        )

        guard components.count <= 2,
              let wholeComponent = components.first,
              !wholeComponent.isEmpty,
              isASCIIDigits(wholeComponent),
              let wholeUnits = Int(wholeComponent) else {
            throw CreateTransactionDisplayError.invalidAmount
        }

        let fractionalComponent = components.count == 2 ? components[1] : ""

        guard fractionalComponent.count <= 2,
              isASCIIDigits(fractionalComponent) else {
            throw CreateTransactionDisplayError.invalidAmount
        }

        let fractionalDigits: Int

        switch fractionalComponent.count {
        case 0:
            fractionalDigits = 0
        case 1:
            fractionalDigits = Int(fractionalComponent)! * 10
        case 2:
            fractionalDigits = Int(fractionalComponent)!
        default:
            throw CreateTransactionDisplayError.invalidAmount
        }

        let (majorMinorUnits, multiplicationOverflow) = wholeUnits
            .multipliedReportingOverflow(by: 100)
        let (amountMinor, additionOverflow) = majorMinorUnits
            .addingReportingOverflow(fractionalDigits)

        guard !multiplicationOverflow, !additionOverflow else {
            throw CreateTransactionDisplayError.invalidAmount
        }

        guard amountMinor > 0 else {
            throw CreateTransactionDisplayError.zeroAmount
        }

        return amountMinor
    }

    private static func isASCIIDigits(_ value: Substring) -> Bool {
        value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func displayError(for error: APIError) -> CreateTransactionDisplayError {
        switch error {
        case let .idempotencyConflict(message):
            .idempotencyConflict(message: message)
        case let .badRequest(messages):
            .requestRejected(
                message: messages.first ?? "The transaction request was rejected."
            )
        case .transport:
            .networkUnavailable
        default:
            .unexpected(
                message: error.errorDescription
                    ?? "The transaction could not be submitted."
            )
        }
    }
}

private extension CreateTransactionViewModel {
    struct PendingOperation {
        let request: TransactionRequest
        let idempotencyKey: UUID
    }
}
