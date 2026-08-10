import SwiftUI

struct CreateTransactionFormSections: View {
    @Binding var amountDigits: String
    @Binding var transactionType: TransactionType
    @Binding var descriptionText: String

    let amountValidationError: CreateTransactionDisplayError?
    let replaceAmountDigits: (Range<Int>, String) -> Void
    let isDisabled: Bool

    @ScaledMetric(relativeTo: .body)
    private var descriptionLineHeight = LimitedTextEditor.baseLineHeight

    var body: some View {
        Section {
            LabeledContent {
                CurrencyAmountTextField(
                    digits: $amountDigits,
                    transactionType: transactionType,
                    replaceDigits: replaceAmountDigits
                )
                .frame(maxWidth: .infinity)
            } label: {
                Text("Amount")
            }

            Picker("Transaction type", selection: $transactionType) {
                Text("Expense").tag(TransactionType.expense)
                Text("Income").tag(TransactionType.income)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Transaction type")
            .accessibilityValue("\(transactionType.displayName) selected")
            .accessibilityHint("Choose whether this transaction is money spent or money received.")
            .accessibilityIdentifier("createTransaction.type")
        } footer: {
            if let amountValidationError {
                Label(
                    amountValidationError.message,
                    systemImage: "exclamationmark.circle.fill"
                )
                .foregroundStyle(.red)
                .accessibilityIdentifier("createTransaction.status")
            }
        }
        .disabled(isDisabled)

        Section {
            ZStack(alignment: .topLeading) {
                LimitedTextEditor(
                    text: $descriptionText,
                    characterLimit: CreateTransactionViewModel
                        .descriptionCharacterLimit
                )
                .frame(maxWidth: .infinity)
                .frame(
                    minHeight: LimitedTextEditor.boundedHeight(
                        for: descriptionLineHeight
                    ),
                    maxHeight: LimitedTextEditor.boundedHeight(
                        for: descriptionLineHeight
                    )
                )

                if descriptionText.isEmpty {
                    Text("Description (optional)")
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(
                "createTransaction.descriptionSurface"
            )
        } footer: {
            HStack {
                Spacer()

                Text(
                    "\(descriptionText.count)/\(CreateTransactionViewModel.descriptionCharacterLimit)"
                )
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    "\(descriptionText.count) of "
                        + "\(CreateTransactionViewModel.descriptionCharacterLimit) characters"
                )
                .accessibilityIdentifier(
                    "createTransaction.descriptionCount"
                )
            }
        }
        .disabled(isDisabled)
    }
}

enum TransactionFeedback {
    case failure(title: String, message: String)
}

struct TransactionFeedbackView: View {
    let feedback: TransactionFeedback

    var body: some View {
        switch feedback {
        case let .failure(title, message):
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)

                Text(message)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("createTransaction.status")
        }
    }
}

struct TransactionSuccessSummaryView: View {
    let snapshot: CreateTransactionSuccessSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                "Transaction created",
                systemImage: "checkmark.circle.fill"
            )
            .font(.headline)
            .foregroundStyle(.green)

            LabeledContent("Amount") {
                Text(
                    CreateTransactionInputNormalizer.formattedBRLAmount(
                        from: String(snapshot.amountMinor)
                    )
                )
            }

            LabeledContent("Type") {
                Text(snapshot.type.displayName)
            }

            if let description = snapshot.description {
                Text("Description")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(description)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier(
                        "createTransaction.successDescription"
                    )
            }

            Text("Transaction ID")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(snapshot.transactionID.uuidString)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("createTransaction.status")
    }
}

struct CreateTransactionActionButton: View {
    let state: CreateTransactionViewState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if state.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                } else if state.isSuccess {
                    Image(systemName: "plus")
                        .accessibilityHidden(true)
                }

                Text(state.primaryActionTitle)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(state.isPrimaryActionDisabled)
        .accessibilityLabel(state.primaryActionAccessibilityLabel)
        .accessibilityHint(state.primaryActionAccessibilityHint)
        .accessibilityIdentifier("createTransaction.submit")
    }
}

extension CreateTransactionViewState {
    var isPrimaryActionDisabled: Bool {
        isBusy
    }

    var primaryActionTitle: String {
        switch self {
        case .validating, .submitting:
            "Creating…"
        case .success:
            "Create Another"
        case .idle, .failure:
            "Create Transaction"
        }
    }

    var primaryActionAccessibilityLabel: String {
        switch self {
        case .validating, .submitting:
            "Creating transaction"
        case .success:
            "Create Another Transaction"
        case .idle, .failure:
            "Create Transaction"
        }
    }

    var primaryActionAccessibilityHint: String {
        switch self {
        case .success:
            "Clears the completed transaction and starts a new entry."
        case .idle, .validating, .submitting, .failure:
            "Submits this transaction once."
        }
    }
}

extension CreateTransactionDisplayError {
    var isAmountValidationError: Bool {
        switch self {
        case .invalidAmount,
             .zeroAmount:
            true
        case .idempotencyConflict,
             .requestRejected,
             .networkUnavailable,
             .submissionCancelled,
             .unexpected:
            false
        }
    }

    var feedbackTitle: String {
        switch self {
        case .idempotencyConflict:
            "Transaction conflict"
        case .requestRejected:
            "Transaction not accepted"
        case .networkUnavailable:
            "Connection problem"
        case .submissionCancelled:
            "Submission cancelled"
        case .unexpected:
            "Transaction not created"
        case .invalidAmount,
             .zeroAmount:
            "Check the amount"
        }
    }
}
