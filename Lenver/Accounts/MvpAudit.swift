import Foundation

nonisolated struct MvpAuditInput: Codable, Sendable {
    enum Action: String, Codable, Sendable {
        case correct, invalidate
        case replaceCheck = "replace_check"
        case suspendBase = "suspend_base"
        case correctBase = "correct_base"
        case refineOccurrence = "refine_occurrence"

        var concernsBase: Bool { self == .suspendBase || self == .correctBase }

        var title: String {
            switch self {
            case .correct: "Corrigir lançamento"
            case .invalidate: "Invalidar lançamento"
            case .replaceCheck: "Substituir conferência"
            case .suspendBase: "Suspender saldo e conferências"
            case .correctBase: "Corrigir base inicial"
            case .refineOccurrence: "Informar hora da despesa"
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
    var baseMinor: String?
    var coverageStart: String?
}

nonisolated struct MvpAuditPreview: Decodable, Sendable {
    struct Impact: Decodable, Identifiable, Sendable {
        let id: UUID
        let referenceAt: Date
        let originalDifferenceMinor: String
        let beforeMinor: String?
        let afterMinor: String?
    }

    struct CoverageChange: Decodable, Identifiable, Sendable {
        let id: UUID
        let description: String?
        let occurrenceDay: String?
        let occurredAt: Date?
        let before: String
        let after: String
    }

    let accountId: UUID
    let targetId: UUID
    let revision: String
    let balanceMinor: String?
    let projectedBalanceMinor: String?
    let checks: [Impact]
    let previewToken: String?
    let previousBaseMinor: String?
    let previousCoverageStart: Date?
    let proposedBaseMinor: String?
    let proposedCoverageStart: Date?
    let coverageChanges: [CoverageChange]?
}

nonisolated struct MvpAuditConfirmation: Encodable, Sendable {
    let input: MvpAuditInput
    let preview: MvpAuditPreview

    func encode(to encoder: any Encoder) throws {
        try input.encode(to: encoder)
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(preview.revision, forKey: .expectedRevision)
        try fields.encodeIfPresent(preview.previewToken, forKey: .previewToken)
        if input.action.concernsBase || input.action == .refineOccurrence {
            try fields.encode(true, forKey: .confirmed)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case expectedRevision, previewToken, confirmed
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
        case "refine_occurrence": "Hora registrada"
        case "invalidate": "Invalidação"
        default: "Registro original"
        }
    }
}
