import Foundation
import Observation

@MainActor
@Observable
final class MvpAccountViewModel {
    enum State {
        case loading
        case loaded(MvpAccountSummary)
        case failed
    }

    private let service: MvpAccountService
    private let session: AuthenticationSession
    private var generation: Int?
    private var principalID: UUID?
    private var pending: (opening: MvpOpening, key: UUID)?
    private(set) var state: State = .loading
    private(set) var preview: MvpOpening?
    private(set) var busy = false
    private(set) var message: String?

    var hasPendingOpening: Bool { pending != nil }

    init(service: MvpAccountService, session: AuthenticationSession) {
        self.service = service
        self.session = session
    }

    func load(accountID: UUID? = nil) async {
        guard !busy, pending == nil, !Task.isCancelled else { return }
        busy = true
        defer { busy = false }
        state = .loading
        preview = nil
        message = nil
        let expected = await session.currentGeneration()
        if generation == nil { generation = expected }
        guard generation == expected else { return }
        do {
            let summary = try await service.read(generation: expected, accountID: accountID)
            try await identify(summary, generation: expected)
            state = .loaded(summary)
        } catch is CancellationError {
            return
        } catch {
            state = .failed
        }
    }

    func review(amount: String, start: Date, zone: TimeZone) async {
        guard let generation, principalID != nil, !busy, pending == nil else { return }
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
            guard await session.hasActiveSession(generation: generation), !Task.isCancelled else { return }
            preview = result
        } catch is CancellationError {
            return
        } catch {
            message = "Não foi possível revisar a base. Confira o valor e a data de início ou tente novamente."
        }
    }

    func edit() {
        guard pending == nil, !busy else { return }
        preview = nil
        message = nil
    }

    func confirm() async {
        guard let generation, !busy else { return }
        if pending == nil, let preview { pending = (preview, UUID()) }
        guard let pending else { return }
        busy = true
        message = nil
        do {
            let summary = try await service.open(pending.opening, key: pending.key, generation: generation)
            try await identify(summary, generation: generation)
            self.pending = nil
            preview = nil
            state = .loaded(summary)
            busy = false
            await load()
        } catch is CancellationError {
            busy = false
        } catch APIError.badRequest {
            self.pending = nil
            preview = nil
            message = "A base foi rejeitada. Revise o valor e o início da cobertura."
            busy = false
        } catch APIError.idempotencyConflict {
            busy = false
            message = "A abertura entrou em conflito. Consulte a conta para verificar se ela já está ativa."
        } catch {
            busy = false
            message = "A confirmação ainda está pendente. Tente novamente para consultar o resultado da mesma abertura."
        }
    }

    func checkPendingAccount() async {
        guard let generation, pending != nil, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let summary = try await service.read(generation: generation)
            try await identify(summary, generation: generation)
            if summary.status == .available {
                pending = nil
                preview = nil
                message = nil
                state = .loaded(summary)
            }
        } catch is CancellationError {
            return
        } catch {
            message = "Não foi possível consultar a conta. Tente novamente."
        }
    }

    private func identify(_ summary: MvpAccountSummary, generation: Int) async throws {
        guard await session.hasActiveSession(generation: generation), !Task.isCancelled,
              principalID == nil || principalID == summary.principalId else {
            throw CancellationError()
        }
        principalID = summary.principalId
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

    static func money(_ minor: String) -> String {
        let negative = minor.hasPrefix("-")
        let magnitude = negative ? String(minor.dropFirst()) : minor
        let digits = String(repeating: "0", count: max(0, 3 - magnitude.count)) + magnitude
        return "\(negative ? "-" : "")R$ \(digits.dropLast(2)),\(digits.suffix(2))"
    }
}
