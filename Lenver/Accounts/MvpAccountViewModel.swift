import Foundation
import Observation

@MainActor
@Observable
final class MvpAccountViewModel {
    enum State {
        case loading
        case loaded(MvpAccountSummary)
        case unavailable
        case failed
    }

    private let service: MvpAccountService
    private let session: AuthenticationSession
    private let store: MvpIntentStore
    private let canSend: @MainActor @Sendable () -> Bool
    private var generation: Int?
    private var principalID: UUID?
    private var selectedAccountID: UUID?
    private var pending: MvpIntent?
    private var storageReady = false
    private(set) var state: State = .loading
    private(set) var preview: MvpOpening?
    private(set) var checkPreview: MvpCheckPreview?
    private(set) var recoveryReceipt: MvpRecoveryReceipt?
    private(set) var auditReceipt: MvpAuditReceipt?
    private(set) var checkReceipt: MvpCheckReceipt?
    private(set) var entries: [MvpHistoryEntry] = []
    private(set) var nextCursor: String?
    private(set) var confirmedID: UUID?
    private(set) var busy = false
    private(set) var message: String?
    var transactionForm: CreateTransactionViewModel?

    var hasPendingOpening: Bool { pending?.operation == .opening }
    func isCurrentPrincipal(_ id: UUID) -> Bool { principalID == id }
    var hasPendingTransaction: Bool { pending?.operation == .transaction }
    var hasPendingRecovery: Bool { pending?.operation == .recovery }
    var hasPendingAudit: Bool { pending?.operation == .audit }
    var hasPendingBaseChange: Bool {
        guard let pending, pending.operation == .audit,
              let input = try? JSONDecoder().decode(MvpAuditInput.self, from: pending.body) else { return false }
        return input.action.concernsBase
    }
    var hasPendingCheck: Bool { pending?.operation == .check }
    var canWrite: Bool { storageReady && pending == nil && !busy }

    init(
        service: MvpAccountService,
        session: AuthenticationSession,
        store: MvpIntentStore = MvpIntentStore(),
        canSend: @escaping @MainActor @Sendable () -> Bool = { true }
    ) {
        self.service = service
        self.session = session
        self.store = store
        self.canSend = canSend
    }

    func load(accountID: UUID? = nil, recover: Bool = false, keepSelection: Bool = false) async {
        guard !busy, !Task.isCancelled else { return }
        busy = true
        defer { busy = false }
        if !keepSelection { selectedAccountID = accountID }
        if pending == nil { message = nil }
        let expected = await session.currentGeneration()
        if generation == nil { generation = expected }
        guard generation == expected else { return }

        guard let summary = await read(generation: expected) else { return }
        do {
            try await checkSession(expected)
            pending = try await store.load(environment: service.environmentID, principalID: summary.principalId)
            try await checkSession(expected)
            storageReady = true
        } catch is CancellationError {
            return
        } catch {
            storageReady = false
            message = "Armazenamento protegido indisponível. Tente consultar novamente antes de enviar."
        }

        if recover, let pending {
            await resolve(pending, generation: expected)
        }
    }

    func loadMore() async {
        guard !busy, let generation, let nextCursor,
              case let .loaded(summary) = state, let accountID = summary.account?.id else { return }
        busy = true
        defer { busy = false }
        do {
            let page = try await service.history(accountID: accountID, cursor: nextCursor, generation: generation)
            try await identify(page.summary, generation: generation)
            entries += page.entries
            self.nextCursor = page.nextCursor
        } catch APIError.mvpConflict(code: "STALE_REVISION") {
            if await read(generation: generation) != nil {
                message = "O histórico mudou. Saldo e lançamentos foram atualizados."
            }
        } catch is CancellationError {
            return
        } catch {
            message = "Não foi possível carregar mais lançamentos. Tente novamente."
        }
    }

    func review(amount: String, start: Date, zone: TimeZone) async {
        guard let generation, principalID != nil, canWrite else { return }
        guard let baseMinor = Self.parseMinor(amount) else {
            message = "Informe um valor em reais com até duas casas decimais."
            return
        }
        busy = true
        defer { busy = false }
        message = nil
        do {
            let opening = MvpOpening(baseMinor: String(baseMinor), coverageStart: start, referenceZone: zone.identifier)
            let result = try await service.preview(opening, generation: generation)
            try await checkSession(generation)
            preview = result
        } catch is CancellationError {
            return
        } catch {
            message = "Não foi possível revisar a base. Confira o valor e a data de início ou tente novamente."
        }
    }

    func edit() {
        guard canWrite else { return }
        preview = nil
        message = nil
    }

    func confirm() async {
        guard let generation, let principalID, !busy else { return }
        if let pending, pending.operation == .opening {
            await retry()
            return
        }
        guard let preview, canWrite else { return }
        busy = true
        defer { busy = false }
        do {
            let intent = MvpIntent(
                environment: service.environmentID, principalID: principalID, accountID: nil,
                operation: .opening, key: UUID(), body: try APIClient.freeze(preview)
            )
            try await persist(intent, generation: generation)
            await resolve(intent, generation: generation)
        } catch is CancellationError {
            return
        } catch {
            message = "Não foi possível proteger a abertura no dispositivo. Nenhum envio foi iniciado."
        }
    }

    func editCheck() {
        guard canWrite else { return }
        checkPreview = nil
        checkReceipt = nil
        message = nil
    }

    func reviewCheck(amount: String, reference: Date) async {
        guard canWrite, let generation else { return }
        guard let observedMinor = Self.parseMinor(amount) else {
            message = "Informe um valor em reais com até duas casas decimais."
            return
        }
        busy = true
        defer { busy = false }
        message = nil
        do {
            switch state {
            case .loaded: break
            case .loading, .unavailable, .failed: _ = await read(generation: generation)
            }
            guard case let .loaded(summary) = state, summary.status == .available,
                  let accountID = summary.account?.id else {
                message = "Não foi possível consultar a conta. Seus dados continuam no formulário. Tente novamente."
                return
            }
            let input = MvpCheckInput(accountId: accountID, observedMinor: String(observedMinor), referenceAt: reference)
            let result = try await service.previewCheck(input, generation: generation)
            try await checkSession(generation)
            guard result.accountId == accountID else { throw APIError.invalidResponse }
            checkPreview = result
        } catch is CancellationError {
            return
        } catch APIError.mvpConflict(code: "OCCURRENCE_TIME_REQUIRED") {
            message = "Um lançamento informado só por dia torna esse horário ambíguo. Escolha outro corte."
        } catch APIError.badRequest {
            message = "Escolha uma data e hora entre o início da cobertura e agora."
        } catch {
            message = "Não foi possível consultar a conferência. Seus dados continuam no formulário. Tente novamente."
        }
    }

    func confirmCheck() async {
        guard canWrite, let generation, let principalID, let checkPreview else { return }
        busy = true
        defer { busy = false }
        do {
            let intent = MvpIntent(
                environment: service.environmentID, principalID: principalID, accountID: checkPreview.accountId,
                operation: .check, key: UUID(), body: try APIClient.freeze(MvpCheckConfirmation(preview: checkPreview))
            )
            try await persist(intent, generation: generation)
            await resolve(intent, generation: generation)
        } catch is CancellationError {
            return
        } catch {
            message = "Não foi possível proteger a conferência no dispositivo. Nenhum envio foi iniciado."
        }
    }

    func loadChecks(accountID: UUID, pendingOnly: Bool, after: UUID? = nil, revision: String? = nil) async throws -> MvpChecksPage {
        guard let generation else { throw CancellationError() }
        let page = try await service.checks(
            accountID: accountID, pendingOnly: pendingOnly, after: after, revision: revision, generation: generation
        )
        try await identify(page.summary, generation: generation)
        guard page.summary.account?.id == accountID else { throw APIError.invalidResponse }
        return page
    }

    func previewRecovery(_ input: MvpRecoveryInput) async throws -> MvpRecoveryPreview {
        guard let generation else { throw CancellationError() }
        let preview = try await service.previewRecovery(input, generation: generation)
        try await checkSession(generation)
        guard preview.accountId == input.accountId, preview.checkId == input.checkId else {
            throw APIError.invalidResponse
        }
        return preview
    }

    func loadRecoveryHistory(accountID: UUID, cursor: String?, revision: String) async throws -> MvpHistoryPage {
        guard let generation else { throw CancellationError() }
        let page = try await service.history(accountID: accountID, cursor: cursor, generation: generation)
        try await identify(page.summary, generation: generation)
        guard page.summary.account?.id == accountID else { throw APIError.invalidResponse }
        guard page.summary.revision == revision else { throw APIError.mvpConflict(code: "STALE_REVISION") }
        return page
    }

    func confirmRecovery(_ confirmation: MvpRecoveryConfirmation) async {
        guard canWrite, let generation, let principalID else { return }
        busy = true
        defer { busy = false }
        do {
            let intent = MvpIntent(
                environment: service.environmentID, principalID: principalID, accountID: confirmation.input.accountId,
                operation: .recovery, key: UUID(), body: try APIClient.freeze(confirmation)
            )
            try await persist(intent, generation: generation)
            await resolve(intent, generation: generation)
        } catch is CancellationError {
            return
        } catch {
            message = "Não foi possível proteger a recuperação no dispositivo. Nenhum envio foi iniciado."
        }
    }

    func previewAudit(_ input: MvpAuditInput) async throws -> MvpAuditPreview {
        guard let generation else { throw CancellationError() }
        let preview = try await service.previewAudit(input, generation: generation)
        try await checkSession(generation)
        guard preview.accountId == input.accountId, preview.targetId == input.targetId else {
            throw APIError.invalidResponse
        }
        return preview
    }

    func loadBaseVersions(accountID: UUID) async throws -> [MvpBaseVersion] {
        guard let generation else { throw CancellationError() }
        let versions = try await service.baseVersions(accountID: accountID, generation: generation)
        try await checkSession(generation)
        guard versions.allSatisfy({ $0.accountId == accountID && $0.authorId == principalID }) else {
            throw APIError.invalidResponse
        }
        return versions
    }

    func loadMovementVersions(accountID: UUID, movementID: UUID) async throws -> [MvpMovementVersion] {
        guard let generation else { throw CancellationError() }
        let versions = try await service.movementVersions(accountID: accountID, movementID: movementID, generation: generation)
        try await checkSession(generation)
        return versions
    }

    func confirmAudit(_ confirmation: MvpAuditConfirmation) async -> Bool {
        guard canWrite, confirmation.preview.previewToken != nil,
              let generation, let principalID else { return false }
        busy = true
        auditReceipt = nil
        defer { busy = false }
        do {
            let intent = MvpIntent(
                environment: service.environmentID, principalID: principalID, accountID: confirmation.input.accountId,
                operation: .audit, key: UUID(), body: try APIClient.freeze(confirmation)
            )
            try await persist(intent, generation: generation)
            await resolve(intent, generation: generation)
            return auditReceipt != nil
        } catch is CancellationError {
            return false
        } catch {
            message = "Não foi possível proteger a alteração no dispositivo. Nenhum envio foi iniciado."
            return false
        }
    }

    func startTransaction() {
        guard canWrite, case let .loaded(summary) = state, summary.status == .available,
              let accountID = summary.account?.id, let revision = summary.revision, let base = summary.base else { return }
        confirmedID = nil
        checkReceipt = nil
        transactionForm = CreateTransactionViewModel(
            service: MvpFormSubmission { [weak self] request, key in
                guard let self else { throw CancellationError() }
                return try await self.register(request, key: key, revision: revision)
            },
            disposableDemoAccountID: accountID,
            occurrence: max(.now, base.coverageStart)
        )
    }

    func retry() async {
        guard let generation, let pending, storageReady, !busy else { return }
        busy = true
        defer { busy = false }
        if pending.accountID != nil {
            selectedAccountID = nil
            guard await read(generation: generation) != nil else { return }
        }
        await resolve(pending, generation: generation)
    }

    private func register(_ request: TransactionRequest, key: UUID, revision: String) async throws -> TransactionResponse {
        guard let generation, let principalID, canWrite,
              case let .loaded(summary) = state, summary.account?.id == request.accountId,
              revision == summary.revision else { throw CancellationError() }
        busy = true
        defer { busy = false }

        do {
            let body = try APIClient.freeze(MvpTransactionPayload(request: request, expectedRevision: revision))
            let intent = MvpIntent(
                environment: service.environmentID, principalID: principalID, accountID: request.accountId,
                operation: .transaction, key: key, body: body
            )
            try await persist(intent, generation: generation)
            transactionForm = nil
            guard let transaction = await resolve(intent, generation: generation) else { throw CancellationError() }
            return transaction
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CreateTransactionDisplayError.requestRejected(
                message: "Não foi possível proteger o lançamento no dispositivo. Nenhum envio foi iniciado."
            )
        }
    }

    private func read(generation: Int) async -> MvpAccountSummary? {
        state = .loading
        entries = []
        nextCursor = nil
        do {
            var summary = try await service.read(generation: generation, accountID: selectedAccountID)
            try await identify(summary, generation: generation)
            if let accountID = summary.account?.id {
                let page = try await service.history(accountID: accountID, generation: generation)
                try await identify(page.summary, generation: generation)
                summary = page.summary
                entries = page.entries
                nextCursor = page.nextCursor
            }
            state = .loaded(summary)
            return summary
        } catch is CancellationError {
            return nil
        } catch APIError.transport {
            state = .unavailable
        } catch APIError.server, APIError.refreshUnavailable {
            state = .unavailable
        } catch {
            state = .failed
        }
        return nil
    }

    private func persist(_ intent: MvpIntent, generation: Int) async throws {
        try await checkSession(generation)
        guard canSend() else { throw CancellationError() }
        try await store.save(intent)
        try await checkSession(generation)
        pending = intent
    }

    @discardableResult
    private func resolve(_ intent: MvpIntent, generation: Int) async -> TransactionResponse? {
        do {
            try await checkSession(generation)
            guard canSend(), storageReady, intent.principalID == principalID,
                  intent.environment == service.environmentID else { return nil }
            message = nil

            if intent.operation != .opening {
                guard let target = intent.accountID, case let .loaded(summary) = state,
                      summary.status == .available || summary.baseSuspended == true,
                      summary.account?.id == target else {
                    message = "O envio pendente aguarda a consulta da conta vinculada."
                    return nil
                }
            }

            let transaction: TransactionResponse?
            let check: MvpCheckReceipt?
            var recovery: MvpRecoveryReceipt?
            var audit: MvpAuditReceipt?
            let confirmation: String
            switch intent.operation {
            case .opening:
                guard intent.accountID == nil else { return nil }
                let summary: MvpAccountSummary = try await service.send(intent, generation: generation, canSend: canSend)
                try await identify(summary, generation: generation)
                transaction = nil
                check = nil
                confirmation = "Conta confirmada."
            case .transaction:
                let receipt: MvpTransactionReceipt = try await service.send(intent, generation: generation, canSend: canSend)
                guard receipt.accountId == intent.accountID, let value = receipt.transaction else { throw APIError.invalidResponse }
                transaction = value
                check = nil
                confirmation = "Lançamento confirmado."
            case .check:
                let receipt: MvpCheckReceipt = try await service.send(intent, generation: generation, canSend: canSend)
                guard receipt.accountId == intent.accountID else { throw APIError.invalidResponse }
                transaction = nil
                check = receipt
                confirmation = "Conferência confirmada. Você já pode registrar um lançamento."
            case .recovery:
                let receipt: MvpRecoveryReceipt = try await service.send(intent, generation: generation, canSend: canSend)
                guard receipt.accountId == intent.accountID else { throw APIError.invalidResponse }
                transaction = nil
                check = nil
                recovery = receipt
                confirmation = "Recuperação confirmada. A conferência foi atualizada."
            case .audit:
                let receipt: MvpAuditReceipt = try await service.send(intent, generation: generation, canSend: canSend)
                guard receipt.accountId == intent.accountID, receipt.authorId == intent.principalID else {
                    throw APIError.invalidResponse
                }
                transaction = nil
                check = nil
                audit = receipt
                confirmation = "Alteração confirmada e registrada no histórico."
            }

            try await finish(intent, generation: generation)
            confirmedID = transaction?.id
            checkReceipt = check
            if let recovery { recoveryReceipt = recovery }
            if let audit { auditReceipt = audit }
            message = confirmation
            selectedAccountID = nil
            _ = await read(generation: generation)
            return transaction
        } catch is CancellationError {
            return nil
        } catch let failure as APIError where Self.isDefinitiveRejection(failure) {
            do {
                try await finish(intent, generation: generation)
                _ = await read(generation: generation)
                if intent.operation == .recovery {
                    switch failure {
                    case APIError.mvpConflict(code: "EXTERNAL_REFERENCE_CONFLICT"):
                        message = "A referência externa já está vinculada a outra recuperação. Revise os dados."
                    case APIError.mvpConflict(code: "OCCURRENCE_TIME_REQUIRED"):
                        message = "Informe a hora da despesa ou adie a recuperação."
                    case APIError.mvpConflict(code: "MOVEMENT_ALREADY_LINKED"):
                        message = "Esse lançamento já está vinculado a esta conferência."
                    case APIError.mvpConflict(code: "MOVEMENT_INELIGIBLE"):
                        message = "Esse lançamento não faz parte do saldo no corte da conferência."
                    default:
                        message = "A recuperação precisa de uma nova prévia. Revise os dados e tente novamente."
                    }
                } else if intent.operation == .audit {
                    message = "A alteração precisa de nova revisão. Atualize os dados antes de confirmar."
                } else if intent.operation == .check && failure == .mvpConflict(code: "OCCURRENCE_TIME_REQUIRED") {
                    message = "Um lançamento informado só por dia torna esse horário ambíguo. Escolha outro corte."
                } else if intent.operation == .check {
                    message = "A conferência não foi confirmada. Revise novamente o valor, a data e a hora."
                } else {
                    message = "O envio foi recusado. Confira a conta, a data e os dados antes de tentar novamente."
                }
            } catch is CancellationError {
                return nil
            } catch {
                message = "Não foi possível concluir a gravação local. Tente recuperar o envio."
            }
        } catch APIError.mvpConflict(code: "IDEMPOTENCY_CONFLICT") {
            message = "A chave do envio entrou em conflito. Este envio continua pendente para verificação."
        } catch {
            message = "A confirmação está pendente. Tente recuperar o mesmo envio."
        }
        return nil
    }

    private static func isDefinitiveRejection(_ failure: APIError) -> Bool {
        switch failure {
        case .badRequest, .http(statusCode: 404, message: _),
                .mvpConflict(code: "STALE_REVISION"), .mvpConflict(code: "BASE_REQUIRED"),
                .mvpConflict(code: "BASE_SUSPENDED"),
                .mvpConflict(code: "MVP_ACCOUNT_EXISTS"), .mvpConflict(code: "LEGACY_ADOPTION_BLOCKED"),
                .mvpConflict(code: "OCCURRENCE_TIME_REQUIRED"),
                .mvpConflict(code: "AUDIT_PREVIEW_REQUIRED"), .mvpConflict(code: "AUDIT_TARGET_INACTIVE"),
                .mvpConflict(code: "EXTERNAL_REFERENCE_CONFLICT"),
                .mvpConflict(code: "MOVEMENT_ALREADY_LINKED"), .mvpConflict(code: "MOVEMENT_INELIGIBLE"):
            true
        default:
            false
        }
    }

    private func finish(_ intent: MvpIntent, generation: Int) async throws {
        try await checkSession(generation)
        try await store.remove(intent)
        try await checkSession(generation)
        pending = nil
        preview = nil
        checkPreview = nil
    }

    private func identify(_ summary: MvpAccountSummary, generation: Int) async throws {
        try await checkSession(generation)
        guard principalID == nil || principalID == summary.principalId else { throw CancellationError() }
        principalID = summary.principalId
    }

    private func checkSession(_ generation: Int) async throws {
        guard await session.hasActiveSession(generation: generation) else { throw CancellationError() }
        try Task.checkCancellation()
    }

    static func parseMinor(_ input: String) -> Int64? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(omittingEmptySubsequences: false) { $0 == "," || $0 == "." }
        guard let integer = parts.first, parts.count <= 2 else { return nil }
        let negative = integer.first == "-"
        let whole = negative ? integer.dropFirst() : integer[...]
        let fraction = parts.count == 2 ? String(parts[1]) : "00"
        guard !whole.isEmpty, (1...2).contains(fraction.count),
              (whole + fraction).utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int64((negative ? "-" : "") + whole + fraction + (fraction.count == 1 ? "0" : ""))
    }

    static func money(_ minor: String, locale: Locale = LenverLocale.selected) -> String {
        guard let minorUnits = Decimal(string: minor, locale: Locale(identifier: "en_US_POSIX")) else { return "—" }
        return (minorUnits / 100).formatted(.currency(code: "BRL").locale(locale))
    }
}

private nonisolated struct MvpFormSubmission: TransactionCreating {
    let submit: @MainActor @Sendable (TransactionRequest, UUID) async throws -> TransactionResponse

    func createTransaction(_ request: TransactionRequest, idempotencyKey: UUID) async throws -> TransactionResponse {
        try await submit(request, idempotencyKey)
    }
}
