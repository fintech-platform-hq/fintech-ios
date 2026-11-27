import SwiftUI

#Preview("Idle — Light") {
    CreateTransactionView(viewModel: previewViewModel())
        .preferredColorScheme(.light)
}

#Preview("Idle — Dark") {
    CreateTransactionView(viewModel: previewViewModel())
        .preferredColorScheme(.dark)
}

#Preview("Submitting — Dark") {
    CreateTransactionView(
        viewModel: previewViewModel(
            amountDigits: "15000",
            state: .submitting
        )
    )
    .preferredColorScheme(.dark)
}

#Preview("Validation Error") {
    CreateTransactionView(
        viewModel: previewViewModel(
            state: .failure(.invalidAmount)
        )
    )
}

#Preview("Network Error — Dark") {
    CreateTransactionView(
        viewModel: previewViewModel(
            amountDigits: "15000",
            state: .failure(.networkUnavailable)
        )
    )
    .preferredColorScheme(.dark)
}

#Preview("Conflict Error") {
    CreateTransactionView(
        viewModel: previewViewModel(
            amountDigits: "15000",
            state: .failure(
                .idempotencyConflict(
                    message: "This transaction conflicts with an earlier request."
                )
            )
        )
    )
}

#Preview("Success") {
    CreateTransactionView(
        viewModel: previewViewModel(
            amountDigits: "15000",
            state: .success(
                transactionID: UUID(
                    uuidString: "6AEF7EC3-58FB-4AC7-8FF2-920E90CE0B4C"
                )!
            ),
            successSnapshot: CreateTransactionSuccessSnapshot(
                transactionID: UUID(
                    uuidString: "6AEF7EC3-58FB-4AC7-8FF2-920E90CE0B4C"
                )!,
                amountMinor: 15_000,
                type: .expense,
                description: "Mercado\nCompra semanal"
            )
        )
    )
}

#Preview("Accessibility Type") {
    CreateTransactionView(
        viewModel: previewViewModel(amountDigits: "15000")
    )
    .environment(\.dynamicTypeSize, .accessibility3)
}

@MainActor
private func previewViewModel(
    amountDigits: String = "",
    state: CreateTransactionViewState = .idle,
    successSnapshot: CreateTransactionSuccessSnapshot? = nil
) -> CreateTransactionViewModel {
    CreateTransactionViewModel(
        service: PreviewTransactionService(),
        disposableDemoAccountID: DemoConfiguration
            .disposableTransactionAccountID,
        amountDigits: amountDigits,
        initialState: state,
        initialSuccessSnapshot: successSnapshot
    )
}

private nonisolated struct PreviewTransactionService: TransactionCreating {
    func createTransaction(
        _ request: TransactionRequest,
        idempotencyKey: UUID
    ) async throws -> TransactionResponse {
        throw CancellationError()
    }
}
