import Foundation

nonisolated struct MvpAuditInput: Codable, Sendable {
    enum Action: String, Codable, Sendable {
        case correct, invalidate
        case replaceCheck = "replace_check"

        var title: String {
            switch self {
            case .correct: "Corrigir lançamento"
            case .invalidate: "Invalidar lançamento"
            case .replaceCheck: "Substituir conferência"
            }
        }
    }

    let accountId: UUID
    let targetId: UUID
    let action: Action
    let reason: String
    var amountMinor: String?
    var description: String?
    var occurredAt: String?
    var observedMinor: String?
    var referenceAt: String?
}

nonisolated struct MvpAuditPreview: Decodable, Sendable {
    struct Impact: Decodable, Identifiable, Sendable {
        let id: UUID
        let referenceAt: Date
        let originalDifferenceMinor: String
        let beforeMinor: String
        let afterMinor: String
    }

    let accountId: UUID
    let targetId: UUID
    let revision: String
    let balanceMinor: String
    let projectedBalanceMinor: String
    let checks: [Impact]
    let previewToken: String
}

nonisolated struct MvpAuditConfirmation: Encodable, Sendable {
    let input: MvpAuditInput
    let preview: MvpAuditPreview

    func encode(to encoder: any Encoder) throws {
        try input.encode(to: encoder)
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(preview.revision, forKey: .expectedRevision)
        try fields.encode(preview.previewToken, forKey: .previewToken)
    }

    private enum CodingKeys: String, CodingKey {
        case expectedRevision, previewToken
    }
}

nonisolated struct MvpAuditReceipt: Decodable, Sendable {
    let id: UUID
    let accountId: UUID
    let authorId: UUID
    let action: MvpAuditInput.Action
    let reason: String
    let createdAt: Date
    let revision: String
}

nonisolated struct MvpMovementVersion: Decodable, Identifiable, Sendable {
    let id: UUID
    let action: String
    let authorId: UUID
    let reason: String?
    let amountMinor: String
    let description: String?
    let occurredAt: Date
    let occurrenceDay: String?
    let createdAt: Date

    var title: String {
        switch action {
        case "correct": "Correção"
        case "invalidate": "Invalidação"
        default: "Registro original"
        }
    }
}
