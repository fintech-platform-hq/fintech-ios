import Foundation

nonisolated struct MvpAccountSummary: Decodable, Sendable {
    enum Status: String, Decodable, Sendable {
        case noAccount = "no_account"
        case baseRequired = "base_required"
        case unavailable, available
    }

    struct Account: Decodable, Identifiable, Sendable {
        let id: UUID
        let name: String
    }

    struct Base: Decodable, Sendable {
        let baseMinor: String
        let coverageStart: Date
        let referenceZone: String
    }

    let principalId: UUID
    let account: Account?
    let legacyAccounts: [Account]
    let status: Status
    let base: Base?
    let balanceMinor: String?
    let revision: String?
    let asOf: Date
}

nonisolated struct MvpOpening: Codable, Sendable {
    let baseMinor: String
    let coverageStart: Date
    let referenceZone: String
}

nonisolated struct MvpHistoryPage: Decodable, Sendable {
    let summary: MvpAccountSummary
    let entries: [MvpHistoryEntry]
    let nextCursor: String?
}

nonisolated struct MvpHistoryEntry: Decodable, Identifiable, Sendable {
    enum Coverage: String, Decodable, Sendable {
        case covered
        case beforeBase = "before_base"
        case afterCut = "after_cut"
        case noBase = "no_base"
    }

    let id: UUID
    let type: TransactionType
    let amountMinor: String
    let description: String?
    let occurredAt: Date
    let coverage: Coverage
}

nonisolated struct MvpTransactionReceipt: Decodable, Sendable {
    let id: UUID
    let accountId: UUID
    let type: TransactionType
    let amountMinor: String
    let currency: String
    let description: String?
    let occurredAt: Date
    let createdAt: Date

    var transaction: TransactionResponse? {
        guard let amount = Int(amountMinor), amount > 0 else { return nil }
        return TransactionResponse(
            id: id, accountId: accountId, categoryId: nil, type: type,
            amountMinor: amount, currency: currency, description: description,
            occurredAt: occurredAt, createdAt: createdAt
        )
    }
}

nonisolated struct MvpTransactionPayload: Encodable, Sendable {
    let request: TransactionRequest
    let expectedRevision: String

    func encode(to encoder: any Encoder) throws {
        try request.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(expectedRevision, forKey: .expectedRevision)
    }

    private enum CodingKeys: String, CodingKey {
        case expectedRevision
    }
}

nonisolated struct MvpAccountService: Sendable {
    let apiClient: APIClient
    var environmentID: String { apiClient.environmentID }

    func read(generation: Int, accountID: UUID? = nil) async throws -> MvpAccountSummary {
        let path = accountID.map { "/mvp/account/\($0.uuidString)" } ?? "/mvp/account"
        return try await apiClient.get(path: path, expectedGeneration: generation)
    }

    func preview(_ opening: MvpOpening, generation: Int) async throws -> MvpOpening {
        try await apiClient.post(
            path: "/mvp/account-previews", body: opening, headers: [:],
            expectedStatusCode: 200, expectedGeneration: generation
        )
    }

    func history(accountID: UUID, cursor: String? = nil, generation: Int) async throws -> MvpHistoryPage {
        try await apiClient.get(
            path: "/mvp/account/\(accountID.uuidString)/history",
            expectedGeneration: generation,
            queryItems: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? []
        )
    }

    func send<Response: Decodable & Sendable>(
        _ intent: MvpIntent, generation: Int, canSend: @escaping @MainActor @Sendable () -> Bool
    ) async throws -> Response {
        try await apiClient.post(
            path: intent.operation.rawValue, frozenBody: intent.body,
            headers: ["Idempotency-Key": intent.key.uuidString],
            expectedStatusCode: 201, expectedGeneration: generation, canSend: canSend
        )
    }
}
