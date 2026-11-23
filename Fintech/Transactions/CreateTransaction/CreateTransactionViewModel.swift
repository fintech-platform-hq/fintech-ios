import Foundation
import Observation

@MainActor
@Observable
final class CreateTransactionViewModel {
    static let descriptionCharacterLimit = 255
    static let amountDigitLimit = CreateTransactionInputNormalizer
        .amountDigitLimit

    private(set) var amountDigits: String

    var transactionType: TransactionType {
        didSet { formDidChange() }
    }

    private(set) var descriptionText: String

    private(set) var state: CreateTransactionViewState
    private(set) var successSnapshot: CreateTransactionSuccessSnapshot?

    var formattedAmountText: String {
        CreateTransactionInputNormalizer.formattedSignedBRLAmount(
            from: amountDigits,
            transactionType: transactionType
        )
    }

    private let service: any TransactionCreating
    private let disposableDemoAccountID: UUID
    private let makeUUID: () -> UUID
    private let now: () -> Date
    private var pendingOperation: PendingOperation?

    init(
        service: any TransactionCreating,
        disposableDemoAccountID: UUID,
        amountDigits: String = "",
        transactionType: TransactionType = .expense,
        descriptionText: String = "",
        initialState: CreateTransactionViewState = .idle,
        initialSuccessSnapshot: CreateTransactionSuccessSnapshot? = nil,
        makeUUID: @escaping () -> UUID = UUID.init,
        now: @escaping () -> Date = Date.init
    ) {
        self.service = service
        self.disposableDemoAccountID = disposableDemoAccountID
        self.amountDigits = CreateTransactionInputNormalizer
            .limitedAmountDigits(from: amountDigits, preserving: "")
        self.transactionType = transactionType
        self.descriptionText = Self.normalizedDescriptionInput(
            descriptionText,
            previousValue: ""
        )
        self.state = initialState
        self.successSnapshot = initialSuccessSnapshot
        self.makeUUID = makeUUID
        self.now = now
    }

    func updateAmountDigits(_ proposedValue: String) {
        let previousValue = amountDigits
        let sanitizedValue = CreateTransactionInputNormalizer
            .limitedAmountDigits(
                from: proposedValue,
                preserving: previousValue
            )

        amountDigits = sanitizedValue

        guard sanitizedValue != previousValue else {
            return
        }

        formDidChange()
    }

    func replaceAmountDigits(
        in range: Range<Int>,
        with replacement: String
    ) {
        let previousValue = amountDigits
        let updatedValue = CreateTransactionInputNormalizer
            .replacingAmountDigits(
                previousValue,
                in: range,
                with: replacement
            )

        amountDigits = updatedValue

        guard updatedValue != previousValue else {
            return
        }

        formDidChange()
    }

    func updateDescriptionText(_ proposedValue: String) {
        let previousValue = descriptionText
        let normalizedValue = Self.normalizedDescriptionInput(
            proposedValue,
            previousValue: previousValue
        )

        descriptionText = normalizedValue

        guard normalizedValue != previousValue else {
            return
        }

        formDidChange()
    }

    func startAnotherTransaction() {
        guard state.isSuccess else {
            return
        }

        amountDigits = ""
        descriptionText = ""
        pendingOperation = nil
        successSnapshot = nil
        state = .idle
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
            successSnapshot = CreateTransactionSuccessSnapshot(
                transactionID: response.id,
                amountMinor: operation.request.amountMinor,
                type: operation.request.type,
                description: operation.request.description
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
        let amountMinor = try Self.amountMinor(from: amountDigits)
        let idempotencyKey = makeUUID()
        let clientMutationID = makeUUID()
        let request = try TransactionRequest(
            accountId: disposableDemoAccountID,
            categoryId: nil,
            type: transactionType,
            amountMinor: amountMinor,
            currency: "BRL",
            description: Self.normalizedDescriptionForSubmit(
                from: descriptionText
            ),
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
        guard !input.isEmpty,
              input.count <= amountDigitLimit,
              input.utf8.allSatisfy({ (48...57).contains($0) }),
              let amountMinor = Int(input) else {
            throw CreateTransactionDisplayError.invalidAmount
        }

        guard amountMinor > 0 else {
            throw CreateTransactionDisplayError.zeroAmount
        }

        return amountMinor
    }

    private static func normalizedDescriptionInput(
        _ proposedValue: String,
        previousValue: String
    ) -> String {
        let limitedValue = String(
            proposedValue.prefix(descriptionCharacterLimit)
        )
        let trimmedValue = limitedValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !trimmedValue.isEmpty else {
            return ""
        }

        return previousValue.isEmpty ? trimmedValue : limitedValue
    }

    private static func normalizedDescriptionForSubmit(
        from description: String
    ) -> String? {
        let trimmedValue = description.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        return trimmedValue.isEmpty ? nil : trimmedValue
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
