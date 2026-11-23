import Foundation

nonisolated struct MvpCheckInput: Encodable, Sendable {
    let accountId: UUID
    let observedMinor: String
    let referenceAt: Date
}

nonisolated struct MvpCheckPreview: Decodable, Sendable {
    let accountId: UUID
    let observedMinor: String
    let referenceAt: String
    let revision: String
    let calculatedMinor: String
    let differenceMinor: String
}

nonisolated struct MvpCheckConfirmation: Encodable, Sendable {
    let accountId: UUID
    let observedMinor: String
    let referenceAt: String
    let expectedRevision: String

    init(preview: MvpCheckPreview) {
        accountId = preview.accountId
        observedMinor = preview.observedMinor
        referenceAt = preview.referenceAt
        expectedRevision = preview.revision
    }
}

nonisolated struct MvpCheckReceipt: Decodable, Sendable {
    let id: UUID
    let accountId: UUID
    let observedMinor: String
    let referenceAt: Date
    let referenceInstant: String
    let authorId: UUID?
    let createdAt: Date?
    let originalCalculatedMinor: String
    let originalDifferenceMinor: String

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(UUID.self, forKey: .id)
        accountId = try fields.decode(UUID.self, forKey: .accountId)
        observedMinor = try fields.decode(String.self, forKey: .observedMinor)
        referenceAt = try fields.decode(Date.self, forKey: .referenceAt)
        referenceInstant = try fields.decode(String.self, forKey: .referenceAt)
        authorId = try fields.decodeIfPresent(UUID.self, forKey: .authorId)
        createdAt = try fields.decodeIfPresent(Date.self, forKey: .createdAt)
        originalCalculatedMinor = try fields.decode(String.self, forKey: .originalCalculatedMinor)
        originalDifferenceMinor = try fields.decode(String.self, forKey: .originalDifferenceMinor)
    }

    private enum CodingKeys: String, CodingKey {
        case id, accountId, observedMinor, referenceAt, authorId, createdAt, originalCalculatedMinor, originalDifferenceMinor
    }
}

nonisolated struct MvpCheckEntry: Decodable, Identifiable, Sendable {
    enum Status: String, Decodable, Sendable {
        case open, coincident, resolved
        case partiallyExplained = "partially_explained"

        var title: String {
            switch self {
            case .open: "Divergência em aberto"
            case .coincident: "Valores coincidentes no corte"
            case .partiallyExplained: "Divergência parcialmente explicada"
            case .resolved: "Resolvida por lançamentos identificados"
            }
        }

    }

    let receipt: MvpCheckReceipt
    let calculatedAtReferenceMinor: String
    let remainingDifferenceMinor: String
    let status: Status
    let supersededBy: UUID?
    let replacesCheckId: UUID?
    let replacementReason: String?
    var id: UUID { receipt.id }
    var canRecover: Bool {
        supersededBy == nil && (status == .open || status == .partiallyExplained
            || (status == .coincident && receipt.originalDifferenceMinor != "0"))
    }

    init(from decoder: any Decoder) throws {
        receipt = try MvpCheckReceipt(from: decoder)
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        calculatedAtReferenceMinor = try fields.decode(String.self, forKey: .calculatedAtReferenceMinor)
        remainingDifferenceMinor = try fields.decode(String.self, forKey: .remainingDifferenceMinor)
        supersededBy = try fields.decodeIfPresent(UUID.self, forKey: .supersededBy)
        replacesCheckId = try fields.decodeIfPresent(UUID.self, forKey: .replacesCheckId)
        replacementReason = try fields.decodeIfPresent(String.self, forKey: .replacementReason)
        status = try fields.decodeIfPresent(Status.self, forKey: .resolutionStatus)
            ?? fields.decode(Status.self, forKey: .status)
    }

    private enum CodingKeys: String, CodingKey {
        case calculatedAtReferenceMinor, remainingDifferenceMinor, status, resolutionStatus
        case supersededBy, replacesCheckId, replacementReason
    }
}

nonisolated struct MvpChecksPage: Decodable, Sendable {
    let summary: MvpAccountSummary
    let entries: [MvpCheckEntry]
    let nextAfter: UUID?
}
