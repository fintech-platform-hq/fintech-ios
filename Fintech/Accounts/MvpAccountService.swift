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

nonisolated struct MvpAccountService: Sendable {
    let apiClient: APIClient

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

    func open(_ opening: MvpOpening, key: UUID, generation: Int) async throws -> MvpAccountSummary {
        try await apiClient.post(
            path: "/mvp/account", body: opening,
            headers: ["Idempotency-Key": key.uuidString],
            expectedStatusCode: 201, expectedGeneration: generation
        )
    }
}
