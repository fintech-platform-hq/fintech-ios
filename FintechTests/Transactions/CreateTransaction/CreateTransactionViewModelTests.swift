import Foundation
import Testing
@testable import Fintech

@MainActor
struct CreateTransactionViewModelTests {
    private let accountID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000001"
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
    func validAmountConvertsToMinorUnits() async throws {
        let service = TransactionServiceFake(
            behavior: .succeed(makeResponse(amountMinor: 15_000))
        )
        let viewModel = makeViewModel(service: service)
        viewModel.amountText = "150.00"

        await viewModel.submit()

        let invocation = try #require(await service.invocations.first)
        #expect(invocation.request.amountMinor == 15_000)
        #expect(invocation.request.currency == "BRL")
    }

    @Test
    func commaDecimalConvertsToMinorUnits() async throws {
        let service = TransactionServiceFake(
            behavior: .succeed(makeResponse(amountMinor: 15_000))
        )
        let viewModel = makeViewModel(service: service)
        viewModel.amountText = "150,00"

        await viewModel.submit()

        let invocation = try #require(await service.invocations.first)
        #expect(invocation.request.amountMinor == 15_000)
    }

    @Test
    func invalidAmountShowsValidationErrorAndDoesNotCallService() async {
        let service = TransactionServiceFake(
            behavior: .succeed(makeResponse())
        )
        let viewModel = makeViewModel(service: service)
        viewModel.amountText = "12.345"

        await viewModel.submit()

        #expect(viewModel.state == .failure(.invalidAmount))
        #expect(
            CreateTransactionDisplayError.invalidAmount.message
                == "Enter a valid BRL amount with no more than two decimal places."
        )
        #expect(await service.invocations.isEmpty)
    }

    @Test
    func zeroAmountIsRejectedLocally() async {
        let service = TransactionServiceFake(
            behavior: .succeed(makeResponse())
        )
        let viewModel = makeViewModel(service: service)
        viewModel.amountText = "0,00"

        await viewModel.submit()

        #expect(viewModel.state == .failure(.zeroAmount))
        #expect(await service.invocations.isEmpty)
    }

    @Test
    func negativeAmountIsRejectedLocally() async {
        let service = TransactionServiceFake(
            behavior: .succeed(makeResponse())
        )
        let viewModel = makeViewModel(service: service)
        viewModel.amountText = "-1.00"

        await viewModel.submit()

        #expect(viewModel.state == .failure(.negativeAmount))
        #expect(await service.invocations.isEmpty)
    }

    @Test
    func duplicateSubmitIsPreventedWhileRequestIsInFlight() async {
        let service = TransactionServiceFake(
            behavior: .suspendThenSucceed(makeResponse())
        )
        let viewModel = makeViewModel(service: service)
        viewModel.amountText = "10.00"

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
        viewModel.amountText = "42"

        await viewModel.submit()

        #expect(viewModel.state == .success(transactionID: transactionID))
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
        viewModel.amountText = "42.00"

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
        viewModel.amountText = "15.00"

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
        viewModel.amountText = "15.00"

        await viewModel.submit()
        viewModel.amountText = "16.00"
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
        service: TransactionServiceFake
    ) -> CreateTransactionViewModel {
        var generatedUUIDs = [
            idempotencyKey,
            clientMutationID,
            secondIdempotencyKey,
            secondClientMutationID,
        ]

        return CreateTransactionViewModel(
            service: service,
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
            type: .debit,
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
