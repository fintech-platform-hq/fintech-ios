import SwiftUI

struct CreateTransactionView: View {
    let viewModel: CreateTransactionViewModel

    var body: some View {
        @Bindable var viewModel = viewModel

        NavigationStack {
            Form {
                Section("Transaction") {
                    HStack {
                        TextField("Amount", text: $viewModel.amountText)
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("createTransaction.amount")

                        Text("BRL")
                            .foregroundStyle(.secondary)
                    }

                    Picker("Type", selection: $viewModel.transactionType) {
                        Text("Debit").tag(TransactionType.debit)
                        Text("Credit").tag(TransactionType.credit)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("createTransaction.type")
                }
                .disabled(viewModel.state.isBusy)

                Section("Details") {
                    TextField(
                        "Description (optional)",
                        text: $viewModel.descriptionText,
                        axis: .vertical
                    )
                    .lineLimit(2...4)
                    .accessibilityIdentifier("createTransaction.description")
                }
                .disabled(viewModel.state.isBusy)

                if viewModel.state != .idle {
                    Section("Status") {
                        statusContent
                    }
                }

                Section {
                    Button {
                        Task {
                            await viewModel.submit()
                        }
                    } label: {
                        HStack {
                            Spacer()

                            if viewModel.state.isBusy {
                                ProgressView()
                                    .controlSize(.small)
                            }

                            Text(submitButtonTitle)
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.state.isBusy || viewModel.state.isSuccess)
                    .accessibilityIdentifier("createTransaction.submit")
                }
            }
            .navigationTitle("Create Transaction")
            .scrollDismissesKeyboard(.interactively)
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch viewModel.state {
        case .idle:
            EmptyView()
        case .validating:
            Label("Validating amount…", systemImage: "checkmark.circle")
                .accessibilityIdentifier("createTransaction.status")
        case .submitting:
            Label("Submitting transaction…", systemImage: "arrow.up.circle")
                .accessibilityIdentifier("createTransaction.status")
        case let .success(transactionID):
            VStack(alignment: .leading, spacing: 6) {
                Label("Transaction created", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("ID: \(transactionID.uuidString)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("createTransaction.status")
        case let .failure(error):
            Label(error.message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityIdentifier("createTransaction.status")
        }
    }

    private var submitButtonTitle: String {
        switch viewModel.state {
        case .validating:
            "Validating"
        case .submitting:
            "Submitting"
        case .success:
            "Created"
        case .idle, .failure:
            "Create Transaction"
        }
    }
}

#Preview("Idle") {
    CreateTransactionView(
        viewModel: previewViewModel()
    )
}

#Preview("Loading") {
    CreateTransactionView(
        viewModel: previewViewModel(
            amountText: "150,00",
            state: .submitting
        )
    )
}

#Preview("Success") {
    CreateTransactionView(
        viewModel: previewViewModel(
            amountText: "150,00",
            state: .success(
                transactionID: UUID(
                    uuidString: "6Aef7EC3-58FB-4AC7-8FF2-920E90CE0B4C"
                )!
            )
        )
    )
}

#Preview("Error") {
    CreateTransactionView(
        viewModel: previewViewModel(
            amountText: "invalid",
            state: .failure(.invalidAmount)
        )
    )
}

@MainActor
private func previewViewModel(
    amountText: String = "",
    state: CreateTransactionViewState = .idle
) -> CreateTransactionViewModel {
    CreateTransactionViewModel(
        service: PreviewTransactionService(),
        disposableDemoAccountID: UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"
        )!,
        amountText: amountText,
        initialState: state
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
