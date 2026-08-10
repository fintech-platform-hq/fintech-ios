import SwiftUI
import UIKit

struct CreateTransactionView: View {
    let viewModel: CreateTransactionViewModel

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
                }

                if let transactionFeedback {
                    Section {
                        TransactionFeedbackView(feedback: transactionFeedback)
                    }
                }
            }
            .navigationTitle("Create Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .background {
                KeyboardDismissalTapObserver(action: dismissKeyboard)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                CreateTransactionActionButton(
                    state: viewModel.state,
                    action: performPrimaryAction
                )
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
        }
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
