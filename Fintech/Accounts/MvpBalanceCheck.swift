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
    let originalCalculatedMinor: String
    let originalDifferenceMinor: String
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
    var id: UUID { receipt.id }
    var canRecover: Bool {
        status == .open || status == .partiallyExplained
            || (status == .coincident && receipt.originalDifferenceMinor != "0")
    }

    init(from decoder: any Decoder) throws {
        receipt = try MvpCheckReceipt(from: decoder)
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        calculatedAtReferenceMinor = try fields.decode(String.self, forKey: .calculatedAtReferenceMinor)
        remainingDifferenceMinor = try fields.decode(String.self, forKey: .remainingDifferenceMinor)
        status = try fields.decodeIfPresent(Status.self, forKey: .resolutionStatus)
            ?? fields.decode(Status.self, forKey: .status)
    }

    private enum CodingKeys: String, CodingKey {
        case calculatedAtReferenceMinor, remainingDifferenceMinor, status, resolutionStatus
    }
}

nonisolated struct MvpChecksPage: Decodable, Sendable {
    let summary: MvpAccountSummary
    let entries: [MvpCheckEntry]
    let nextAfter: UUID?
}
