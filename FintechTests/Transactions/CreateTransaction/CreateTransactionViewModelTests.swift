import Foundation
import Testing
import UIKit
@testable import Fintech

@MainActor
struct CreateTransactionViewModelTests {
    private let accountID = UUID(
        uuidString: "11111111-1111-4111-8111-111111111111"
    )!
    private let transactionID = UUID(
        uuidString: "6AEF7EC3-58FB-4AC7-8FF2-920E90CE0B4C"
    )!
    private let idempotencyKey = UUID(
        uuidString: "C58ADFA4-C6E0-47D9-9A37-90B07C65FCF8"
    )!
    private let clientMutationID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000002"
    )!
    private let secondIdempotencyKey = UUID(
        uuidString: "5ED75577-3D64-4E02-B1DB-56BBAA34C366"
    )!
    private let secondClientMutationID = UUID(
        uuidString: "AA0779C9-03A2-437B-8D71-01FD13717030"
    )!

    @Test
    func demoAccountUsesBackendCompatibleUUID() {
        #expect(
            DemoConfiguration.disposableTransactionAccountID.uuidString
                == "11111111-1111-4111-8111-111111111111"
        )
    }

    @Test
    func typingDigitsFormatsBRLProgressively() {
        let viewModel = makeViewModel()
        let expectations = [
            ("1", "-R$ 0,01"),
            ("12", "-R$ 0,12"),
            ("123", "-R$ 1,23"),
            ("1234", "-R$ 12,34"),
            ("123456", "-R$ 1.234,56"),
        ]

        for (digits, formattedAmount) in expectations {
            viewModel.updateAmountDigits(digits)

            #expect(viewModel.amountDigits == digits)
            #expect(viewModel.formattedAmountText == formattedAmount)
        }
    }

    @Test
    func expenseShowsNegativeSignAndKeepsPositiveMinorUnits() async throws {
        let service = TransactionServiceFake(
            behavior: .succeed(makeResponse(amountMinor: 10_000))
        )
        let viewModel = makeViewModel(service: service)
        viewModel.updateAmountDigits("10000")

        #expect(viewModel.formattedAmountText == "-R$ 100,00")

        await viewModel.submit()

        let invocation = try #require(await service.invocations.first)
        #expect(invocation.request.type == .expense)
        #expect(invocation.request.amountMinor == 10_000)
        #expect(invocation.request.amountMinor > 0)
    }

    @Test
    func incomeShowsPositiveSignAndKeepsPositiveMinorUnits() async throws {
        let service = TransactionServiceFake(
            behavior: .succeed(makeResponse(amountMinor: 10_000))
        )
        let viewModel = makeViewModel(service: service)
        viewModel.transactionType = .income
        viewModel.updateAmountDigits("10000")

        #expect(viewModel.formattedAmountText == "+R$ 100,00")

        await viewModel.submit()

        let invocation = try #require(await service.invocations.first)
        #expect(invocation.request.type == .income)
        #expect(invocation.request.amountMinor == 10_000)
        #expect(invocation.request.amountMinor > 0)
    }

    @Test
    func emptyExpenseShowsNegativeZero() {
        let viewModel = makeViewModel()

        #expect(viewModel.formattedAmountText == "-R$ 0,00")
    }

    @Test
    func emptyIncomeShowsPositiveZero() {
        let viewModel = makeViewModel()
        viewModel.transactionType = .income

        #expect(viewModel.formattedAmountText == "+R$ 0,00")
    }

    @Test
    func rawDigitsMapDirectlyToRequestMinorUnits() async throws {
        let expectations = [
            ("1", 1),
            ("12", 12),
            ("123", 123),
            ("123456", 123_456),
        ]

        for (digits, expectedAmountMinor) in expectations {
            let service = TransactionServiceFake(
                behavior: .succeed(
                    makeResponse(amountMinor: expectedAmountMinor)
                )
            )
            let viewModel = makeViewModel(service: service)
            viewModel.updateAmountDigits(digits)

            await viewModel.submit()

            let invocation = try #require(await service.invocations.first)
            #expect(invocation.request.amountMinor == expectedAmountMinor)
            #expect(invocation.request.currency == "BRL")
        }
    }

    @Test
    func selectedTransactionTypeIsUsedForTheLogicalOperation() async throws {
        let service = TransactionServiceFake(
            behavior: .succeed(makeResponse())
        )
        let viewModel = makeViewModel(service: service)
        viewModel.updateAmountDigits("1500")

        await viewModel.submit()
        let expenseInvocation = try #require(await service.invocations.first)
        #expect(expenseInvocation.request.type == .expense)

        viewModel.startAnotherTransaction()
        viewModel.transactionType = .income
        viewModel.updateAmountDigits("1500")
        await viewModel.submit()

        let invocations = await service.invocations
        #expect(invocations.count == 2)
        #expect(invocations[1].request.type == .income)
    }

    @Test
    func switchingExpenseToIncomePreservesAmountDigitsAndFlipsSign() {
        let viewModel = makeViewModel()
        viewModel.updateAmountDigits("15000")

        #expect(viewModel.amountDigits == "15000")
        #expect(viewModel.formattedAmountText == "-R$ 150,00")

        viewModel.transactionType = .income

        #expect(viewModel.amountDigits == "15000")
        #expect(viewModel.formattedAmountText == "+R$ 150,00")
    }

    @Test
    func switchingIncomeToExpensePreservesAmountDigitsAndFlipsSign() {
        let viewModel = makeViewModel()
        viewModel.transactionType = .income
        viewModel.updateAmountDigits("15000")

        #expect(viewModel.amountDigits == "15000")
        #expect(viewModel.formattedAmountText == "+R$ 150,00")

        viewModel.transactionType = .expense

        #expect(viewModel.amountDigits == "15000")
        #expect(viewModel.formattedAmountText == "-R$ 150,00")
    }

    @Test
    func rawAmountDigitsAreLimitedToNine() {
        let viewModel = makeViewModel()

        viewModel.updateAmountDigits("123456789")
        #expect(viewModel.amountDigits == "123456789")

        viewModel.updateAmountDigits("1234567890")
        #expect(viewModel.amountDigits == "123456789")
    }

    @Test
    func selectingAllAndDeletingClearsAmount() throws {
        let viewModel = makeViewModel()
        viewModel.updateAmountDigits("123456")
        let formattedAmount = viewModel.formattedAmountText
        let selectedRange = try #require(
            CreateTransactionInputNormalizer.rawDigitRange(
                in: formattedAmount,
                selectedUTF16Range: NSRange(
                    location: 0,
                    length: formattedAmount.utf16.count
                ),
                rawDigitCount: viewModel.amountDigits.count
            )
        )

        viewModel.replaceAmountDigits(in: selectedRange, with: "")

        #expect(viewModel.amountDigits.isEmpty)
        #expect(viewModel.formattedAmountText == "-R$ 0,00")
    }

    @Test
    func replacingSelectedRangeWithDigitsUpdatesRawAmount() throws {
        let viewModel = makeViewModel()
        viewModel.updateAmountDigits("123456")
        let formattedAmount = viewModel.formattedAmountText
        let selectedRange = try #require(
            CreateTransactionInputNormalizer.rawDigitRange(
                in: formattedAmount,
                selectedUTF16Range: (formattedAmount as NSString)
                    .range(of: "234"),
                rawDigitCount: viewModel.amountDigits.count
            )
        )

        viewModel.replaceAmountDigits(in: selectedRange, with: "9")

        #expect(viewModel.amountDigits == "1956")
        #expect(viewModel.formattedAmountText == "-R$ 19,56")
    }

    @Test
    func replacingSelectedRangeWithMixedPasteExtractsDigits() throws {
        let viewModel = makeViewModel()
        viewModel.updateAmountDigits("123456")
        let formattedAmount = viewModel.formattedAmountText
        let selectedRange = try #require(
            CreateTransactionInputNormalizer.rawDigitRange(
                in: formattedAmount,
                selectedUTF16Range: (formattedAmount as NSString)
                    .range(of: "234"),
                rawDigitCount: viewModel.amountDigits.count
            )
        )

        viewModel.replaceAmountDigits(
            in: selectedRange,
            with: "abc90,xyz"
        )

        #expect(viewModel.amountDigits == "19056")
        #expect(viewModel.formattedAmountText == "-R$ 190,56")
    }

    @Test
    func rangeReplacementPreservesNineDigitLimitAndRetainedSuffix() {
        let viewModel = makeViewModel()
        viewModel.updateAmountDigits("123456789")

        viewModel.replaceAmountDigits(in: 3..<4, with: "000")

        #expect(viewModel.amountDigits == "123056789")
        #expect(viewModel.amountDigits.count == 9)
    }

    @Test
    func editedAmountCreatesCorrectMinorUnitRequest() async throws {
        let service = TransactionServiceFake(
            behavior: .succeed(makeResponse(amountMinor: 1_956))
        )
        let viewModel = makeViewModel(service: service)
        viewModel.updateAmountDigits("123456")
        viewModel.replaceAmountDigits(in: 1..<4, with: "9")

        await viewModel.submit()

        let invocation = try #require(await service.invocations.first)
        #expect(invocation.request.amountMinor == 1_956)
    }

    @Test
    func mixedPasteExtractsDigitsAndCreatesExpectedAmount() async throws {
        let service = TransactionServiceFake(
            behavior: .succeed(makeResponse(amountMinor: 15_025))
        )
        let viewModel = makeViewModel(service: service)

        viewModel.updateAmountDigits("abc150,25xyz")

        #expect(viewModel.amountDigits == "15025")
        #expect(viewModel.formattedAmountText == "-R$ 150,25")

        await viewModel.submit()

        let invocation = try #require(await service.invocations.first)
        #expect(invocation.request.amountMinor == 15_025)
    }

    @Test
    func pasteWithoutDigitsPreservesPreviousAmount() {
        let viewModel = makeViewModel()
        viewModel.updateAmountDigits("123")

        viewModel.updateAmountDigits("abc,xyz")

        #expect(viewModel.amountDigits == "123")
        #expect(viewModel.formattedAmountText == "-R$ 1,23")
    }

    @Test
    func pasteBeyondLimitKeepsFirstNineDigits() {
        let viewModel = makeViewModel()

        viewModel.updateAmountDigits("abc1234567890123xyz")

        #expect(viewModel.amountDigits == "123456789")
        #expect(viewModel.formattedAmountText == "-R$ 1.234.567,89")
    }

    @Test
    func removingLastRawDigitSupportsBackspaceState() {
        let viewModel = makeViewModel()
        viewModel.updateAmountDigits("1234")

        viewModel.updateAmountDigits("123")

        #expect(viewModel.amountDigits == "123")
        #expect(viewModel.formattedAmountText == "-R$ 1,23")
    }

    @Test
    func descriptionBelowLimitRemainsUnchanged() {
        let viewModel = makeViewModel()
        let description = "Coffee with a client"

        viewModel.updateDescriptionText(description)

        #expect(viewModel.descriptionText == description)
    }

    @Test
    func descriptionPreservesLineBreaks() {
        let viewModel = makeViewModel()
        let description = "Coffee\nwith a client\nafter lunch"

        viewModel.updateDescriptionText(description)

        #expect(viewModel.descriptionText == description)
    }

    @Test
    func whitespaceOnlyNewlineInputIsIgnored() {
        let viewModel = makeViewModel()
        let description = String(repeating: "\n", count: 40)

        viewModel.updateDescriptionText(description)

        #expect(viewModel.descriptionText.isEmpty)
    }

    @Test
    func whitespaceOnlySpacesAreIgnored() {
        let viewModel = makeViewModel()

        viewModel.updateDescriptionText("          ")

        #expect(viewModel.descriptionText.isEmpty)
    }

    @Test
    func firstPasteWithContentTrimsWhitespaceBoundaries() {
        let viewModel = makeViewModel()

        viewModel.updateDescriptionText("   Pagamento mercado   ")

        #expect(viewModel.descriptionText == "Pagamento mercado")
    }

    @Test
    func normalSpacesAndMultilineContentArePreserved() {
        let viewModel = makeViewModel()
        let description = "Mercado\nCompra semanal"

        viewModel.updateDescriptionText("Pagamento mercado")
        #expect(viewModel.descriptionText == "Pagamento mercado")

        viewModel.updateDescriptionText(description)
        #expect(viewModel.descriptionText == description)
    }

    @Test
    func descriptionEditorUsesFixedBoundedHeightConfiguration() {
        #expect(LimitedTextEditor.minimumVisibleLineCount == 4)
        #expect(LimitedTextEditor.maximumVisibleLineCount == 4)
        #expect(LimitedTextEditor.visibleLineCount == 4)
        #expect(LimitedTextEditor.boundedHeight(for: 20) == 84)
    }

    @Test
    func descriptionEditorContainerHeightIgnoresNewlineContent() {
        let container = LimitedTextEditor.BoundedTextEditorContainer()
        container.boundedHeight = 84
        let initialIntrinsicHeight = container.intrinsicContentSize.height

        container.textView.text = String(repeating: "\n", count: 255)
        container.textView.layoutIfNeeded()

        #expect(initialIntrinsicHeight == 84)
        #expect(container.intrinsicContentSize.height == 84)
        #expect(
            container.sizeThatFits(
                CGSize(
                    width: 320,
                    height: CGFloat.greatestFiniteMagnitude
                )
            ).height == 84
        )
        #expect(container.textView.isScrollEnabled)
    }

    @Test
    func descriptionAcceptsExactly255Characters() {
        let viewModel = makeViewModel()
        let description = String(repeating: "a", count: 255)

        viewModel.updateDescriptionText(description)

        #expect(viewModel.descriptionText == description)
        #expect(viewModel.descriptionText.count == 255)
    }

    @Test
    func descriptionIsImmediatelyTruncatedTo255Characters() {
        let viewModel = makeViewModel()
        let overLimitDescription = String(repeating: "a", count: 256)

        viewModel.updateDescriptionText(overLimitDescription)

        #expect(viewModel.descriptionText.count == 255)
        #expect(viewModel.descriptionText == String(repeating: "a", count: 255))
    }

    @Test
    func pastedMultilineDescriptionIsLimitedWithoutRemovingLineBreaks() {
        let viewModel = makeViewModel()
        let line = "A line of pasted text\n"
        let pastedDescription = String(repeating: line, count: 20)

        viewModel.updateDescriptionText(pastedDescription)

        #expect(viewModel.descriptionText.count == 255)
        #expect(
            viewModel.descriptionText
                == String(pastedDescription.prefix(255))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
        )
        #expect(viewModel.descriptionText.contains("\n"))
    }

    @Test
    func submitTrimsDescriptionBoundaries() async throws {
        let service = TransactionServiceFake(
            behavior: .succeed(makeResponse())
        )
        let viewModel = makeViewModel(service: service)
        viewModel.updateAmountDigits("4200")
        viewModel.updateDescriptionText("Pagamento mercado")
        viewModel.updateDescriptionText("Pagamento mercado   \n")

        await viewModel.submit()

        let invocation = try #require(await service.invocations.first)
        #expect(invocation.request.description == "Pagamento mercado")
    }

    @Test
    func leadingWhitespaceIsTrimmedBeforeRequestCreation() async throws {
        let service = TransactionServiceFake(
            behavior: .succeed(makeResponse())
        )
        let viewModel = makeViewModel(service: service)
        viewModel.updateAmountDigits("4200")

        viewModel.updateDescriptionText("   Pagamento mercado")
        await viewModel.submit()

        let invocation = try #require(await service.invocations.first)
        #expect(invocation.request.description == "Pagamento mercado")
    }

    @Test
    func multilineDescriptionPreservesContentWhileTrimmingEdges() async throws {
        let service = TransactionServiceFake(
            behavior: .succeed(makeResponse())
        )
        let viewModel = makeViewModel(service: service)
        viewModel.updateAmountDigits("4200")

        viewModel.updateDescriptionText(
            "\n\nmercado\ncompra semanal\n\n"
        )
        await viewModel.submit()

        let invocation = try #require(await service.invocations.first)
        #expect(
            invocation.request.description == "mercado\ncompra semanal"
        )
    }

    @Test
    func emptyDescriptionRemainsOptionalAtSubmit() async throws {
        let service = TransactionServiceFake(
            behavior: .succeed(makeResponse())
        )
        let viewModel = makeViewModel(service: service)
        viewModel.updateAmountDigits("4200")
        viewModel.updateDescriptionText(" \n ")

        await viewModel.submit()

        let invocation = try #require(await service.invocations.first)
        #expect(invocation.request.description == nil)
    }

    @Test
    func zeroAmountIsRejectedLocally() async {
        let service = TransactionServiceFake(
            behavior: .succeed(makeResponse())
        )
        let viewModel = makeViewModel(service: service)
        viewModel.updateAmountDigits("0")

        await viewModel.submit()

        #expect(viewModel.state == .failure(.zeroAmount))
        #expect(await service.invocations.isEmpty)
    }

    @Test
    func emptyAmountDoesNotCallService() async {
        let service = TransactionServiceFake(
            behavior: .succeed(makeResponse())
        )
        let viewModel = makeViewModel(service: service)

        await viewModel.submit()

        #expect(viewModel.state == .failure(.invalidAmount))
        #expect(await service.invocations.isEmpty)
    }

    @Test
    func duplicateSubmitIsPreventedWhileRequestIsInFlight() async {
        let service = TransactionServiceFake(
            behavior: .suspendThenSucceed(makeResponse())
        )
        let viewModel = makeViewModel(service: service)
        viewModel.updateAmountDigits("1000")

        let firstSubmission = Task {
            await viewModel.submit()
        }
        await service.waitUntilCalled()

        await viewModel.submit()

        #expect(await service.invocations.count == 1)
        await service.resume()
        await firstSubmission.value
    }

    @Test
    func successfulServiceResponseExposesTransactionID() async {
        let service = TransactionServiceFake(
            behavior: .succeed(makeResponse())
        )
        let viewModel = makeViewModel(service: service)
        viewModel.updateAmountDigits("42")

        await viewModel.submit()

        #expect(viewModel.state == .success(transactionID: transactionID))
        #expect(viewModel.successSnapshot?.transactionID == transactionID)
        #expect(viewModel.state.primaryActionTitle == "Create Another")
        #expect(!viewModel.state.isPrimaryActionDisabled)
    }

    @Test
    func successSnapshotUsesTheNormalizedSubmittedDescription() async throws {
        let service = TransactionServiceFake(
            behavior: .succeed(makeResponse())
        )
        let viewModel = makeViewModel(service: service)
        viewModel.transactionType = .income
        viewModel.updateAmountDigits("1500")
        viewModel.updateDescriptionText("Mercado\nCompra semanal")
        viewModel.updateDescriptionText(
            "Mercado\nCompra semanal   \n"
        )

        await viewModel.submit()

        let snapshot = try #require(viewModel.successSnapshot)
        #expect(snapshot.transactionID == transactionID)
        #expect(snapshot.amountMinor == 1_500)
        #expect(snapshot.type == .income)
        #expect(snapshot.description == "Mercado\nCompra semanal")
    }

    @Test
    func createAnotherResetsEntryAndGeneratesFreshOperation() async {
        let service = TransactionServiceFake(
            behavior: .succeed(makeResponse())
        )
        let viewModel = makeViewModel(service: service)
        viewModel.transactionType = .income
        viewModel.updateAmountDigits("1500")
        viewModel.updateDescriptionText("First transaction")

        await viewModel.submit()
        #expect(viewModel.state.isSuccess)

        viewModel.startAnotherTransaction()

        #expect(viewModel.amountDigits.isEmpty)
        #expect(viewModel.descriptionText.isEmpty)
        #expect(viewModel.successSnapshot == nil)
        #expect(viewModel.transactionType == .income)
        #expect(viewModel.state == .idle)
        #expect(viewModel.state.primaryActionTitle == "Create Transaction")

        viewModel.updateAmountDigits("2500")
        await viewModel.submit()

        let invocations = await service.invocations
        #expect(invocations.count == 2)
        #expect(invocations[0].idempotencyKey == idempotencyKey)
        #expect(invocations[1].idempotencyKey == secondIdempotencyKey)
        #expect(invocations[0].request.clientMutationId == clientMutationID)
        #expect(
            invocations[1].request.clientMutationId
                == secondClientMutationID
        )
        #expect(invocations[1].request.amountMinor == 2_500)
        #expect(invocations[1].request.type == .income)
    }

    @Test
    func conflictExposesReadableTypedError() async {
        let backendMessage = "Idempotency key was already used"
        let service = TransactionServiceFake(
            behavior: .fail(
                .idempotencyConflict(message: backendMessage)
            )
        )
        let viewModel = makeViewModel(service: service)
        viewModel.updateAmountDigits("4200")

        await viewModel.submit()

        #expect(
            viewModel.state
                == .failure(.idempotencyConflict(message: backendMessage))
        )
        #expect(
            CreateTransactionDisplayError
                .idempotencyConflict(message: backendMessage)
                .message == backendMessage
        )
    }

    @Test
    func unchangedManualRetryReusesRequestAndIdempotencyKey() async throws {
        let service = TransactionServiceFake(
            behavior: .failThenSucceed(
                .transport(code: .timedOut),
                makeResponse()
            )
        )
        let viewModel = makeViewModel(service: service)
        viewModel.updateAmountDigits("1500")

        await viewModel.submit()
        await viewModel.submit()

        let invocations = await service.invocations
        #expect(invocations.count == 2)
        #expect(invocations[0].idempotencyKey == invocations[1].idempotencyKey)
        #expect(invocations[0].request == invocations[1].request)
    }

    @Test
    func editingAfterFailureCreatesNewLogicalOperation() async {
        let service = TransactionServiceFake(
            behavior: .failThenSucceed(
                .transport(code: .timedOut),
                makeResponse(amountMinor: 1_600)
            )
        )
        let viewModel = makeViewModel(service: service)
        viewModel.updateAmountDigits("1500")

        await viewModel.submit()
        viewModel.updateAmountDigits("1600")
        await viewModel.submit()

        let invocations = await service.invocations
        #expect(invocations.count == 2)
        #expect(invocations[0].idempotencyKey == idempotencyKey)
        #expect(invocations[1].idempotencyKey == secondIdempotencyKey)
        #expect(invocations[0].request.clientMutationId == clientMutationID)
        #expect(
            invocations[1].request.clientMutationId == secondClientMutationID
        )
        #expect(invocations[1].request.amountMinor == 1_600)
    }

    private func makeViewModel(
        service: TransactionServiceFake? = nil
    ) -> CreateTransactionViewModel {
        var generatedUUIDs = [
            idempotencyKey,
            clientMutationID,
            secondIdempotencyKey,
            secondClientMutationID,
        ]

        return CreateTransactionViewModel(
            service: service ?? TransactionServiceFake(
                behavior: .succeed(makeResponse())
            ),
            disposableDemoAccountID: accountID,
            makeUUID: { generatedUUIDs.removeFirst() },
            now: { Date(timeIntervalSince1970: 1_785_436_800) }
        )
    }

    private func makeResponse(
        amountMinor: Int = 4_200
    ) -> TransactionResponse {
        TransactionResponse(
            id: transactionID,
            accountId: accountID,
            categoryId: nil,
            type: .expense,
            amountMinor: amountMinor,
            currency: "BRL",
            description: nil,
            occurredAt: Date(timeIntervalSince1970: 1_785_436_800),
            createdAt: Date(timeIntervalSince1970: 1_785_436_801)
        )
    }
}

private actor TransactionServiceFake: TransactionCreating {
    struct Invocation: Sendable {
        let request: TransactionRequest
        let idempotencyKey: UUID
    }

    enum Behavior: Sendable {
        case succeed(TransactionResponse)
        case fail(APIError)
        case suspendThenSucceed(TransactionResponse)
        case failThenSucceed(APIError, TransactionResponse)
    }

    private(set) var invocations: [Invocation] = []
    private var behavior: Behavior
    private var suspension: CheckedContinuation<Void, Never>?
    private var callWaiters: [CheckedContinuation<Void, Never>] = []

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func createTransaction(
        _ request: TransactionRequest,
        idempotencyKey: UUID
    ) async throws -> TransactionResponse {
        invocations.append(
            Invocation(request: request, idempotencyKey: idempotencyKey)
        )
        callWaiters.forEach { $0.resume() }
        callWaiters.removeAll()

        switch behavior {
        case let .succeed(response):
            return response
        case let .fail(error):
            throw error
        case let .suspendThenSucceed(response):
            await withCheckedContinuation { continuation in
                suspension = continuation
            }
            return response
        case let .failThenSucceed(error, response):
            if invocations.count == 1 {
                throw error
            }
            return response
        }
    }

    func waitUntilCalled() async {
        guard invocations.isEmpty else {
            return
        }

        await withCheckedContinuation { continuation in
            callWaiters.append(continuation)
        }
    }

    func resume() {
        suspension?.resume()
        suspension = nil
    }
}
