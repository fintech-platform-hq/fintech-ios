import SwiftUI
import UIKit

struct CreateTransactionView: View {
    let viewModel: CreateTransactionViewModel
    let onSignOut: () -> Void
    let occurrenceRange: ClosedRange<Date>?
    let occurrenceZone: TimeZone?
    let onClose: (() -> Void)?

    init(
        viewModel: CreateTransactionViewModel,
        onSignOut: @escaping () -> Void = {},
        occurrenceRange: ClosedRange<Date>? = nil,
        occurrenceZone: TimeZone? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onSignOut = onSignOut
        self.occurrenceRange = occurrenceRange
        self.occurrenceZone = occurrenceZone
        self.onClose = onClose
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static let contentMaxWidth: CGFloat = 640

    private var usesScrollablePrimaryAction: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private var primaryActionButton: some View {
        CreateTransactionActionButton(
            state: viewModel.state,
            action: performPrimaryAction
        )
    }

    private var amountValidationError: CreateTransactionDisplayError? {
        guard case let .failure(error) = viewModel.state,
              error.isAmountValidationError else {
            return nil
        }

        return error
    }

    private var transactionFeedback: TransactionFeedback? {
        switch viewModel.state {
        case let .failure(error) where !error.isAmountValidationError:
            .failure(title: error.feedbackTitle, message: error.message)
        case .idle, .validating, .submitting, .success, .failure:
            nil
        }
    }

    private var amountDigits: Binding<String> {
        Binding(
            get: { viewModel.amountDigits },
            set: viewModel.updateAmountDigits
        )
    }

    private var descriptionText: Binding<String> {
        Binding(
            get: { viewModel.descriptionText },
            set: viewModel.updateDescriptionText
        )
    }

    private var isFormDisabled: Bool {
        viewModel.state.isBusy || viewModel.state.isSuccess
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        NavigationStack {
            Form {
                if let successSnapshot = viewModel.successSnapshot {
                    Section {
                        TransactionSuccessSummaryView(snapshot: successSnapshot)
                    }
                } else {
                    CreateTransactionFormSections(
                        amountDigits: amountDigits,
                        transactionType: $viewModel.transactionType,
                        descriptionText: descriptionText,
                        amountValidationError: amountValidationError,
                        replaceAmountDigits: viewModel.replaceAmountDigits,
                        isDisabled: isFormDisabled
                    )
                    if let occurrenceRange {
                        DatePicker(
                            "Data e hora do lançamento",
                            selection: Binding(
                                get: { viewModel.occurrence ?? occurrenceRange.upperBound },
                                set: { viewModel.occurrence = $0 }
                            ),
                            in: occurrenceRange
                        )
                        .environment(\.timeZone, occurrenceZone ?? .current)
                        .environment(\.locale, Locale(identifier: "pt_BR"))
                        .disabled(isFormDisabled)
                    }
                }

                if let transactionFeedback {
                    Section {
                        TransactionFeedbackView(feedback: transactionFeedback)
                    }
                }

                if usesScrollablePrimaryAction {
                    Section {
                        primaryActionButton
                            .padding(.horizontal)
                            .padding(.vertical, 12)
                    }
                }
            }
            .frame(maxWidth: Self.contentMaxWidth)
            .frame(maxWidth: .infinity)
            .navigationTitle("Create Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let onClose {
                        Button("Fechar", action: onClose).disabled(isFormDisabled)
                    } else {
                        Button("Sign Out", action: onSignOut)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background {
                KeyboardDismissalTapObserver(action: dismissKeyboard)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !usesScrollablePrimaryAction {
                    primaryActionButton
                        .frame(maxWidth: Self.contentMaxWidth)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal)
                        .padding(.vertical, 12)
                }
            }
            .onChange(of: viewModel.state) { _, state in
                announceStatus(for: state)
            }
            .interactiveDismissDisabled(viewModel.state.isBusy)
        }
    }

    private func announceStatus(for state: CreateTransactionViewState) {
        let announcement: String

        switch state {
        case .success:
            announcement = "Transaction created"
        case let .failure(error):
            announcement = error.message
        case .idle, .validating, .submitting:
            return
        }

        UIAccessibility.post(
            notification: .announcement,
            argument: announcement
        )
    }

    private func performPrimaryAction() {
        if viewModel.state.isSuccess {
            viewModel.startAnotherTransaction()
            return
        }

        submit()
    }

    private func submit() {
        dismissKeyboard()

        Task {
            await viewModel.submit()
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}
