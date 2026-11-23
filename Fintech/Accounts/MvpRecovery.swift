import Foundation

nonisolated struct MvpRecoveryInput: Encodable, Sendable {
    let accountId: UUID
    let checkId: UUID
    let amountMinor: String
    let day: String
    let occurredAt: Date?
    let description: String?
    let externalSource: String?
    let externalReference: String?
}

nonisolated struct MvpRecoveryConfirmation: Encodable, Sendable {
    enum Action: String, Encodable, Sendable {
        case link, create
    }

    let input: MvpRecoveryInput
    let expectedRevision: String
    let action: Action
    let transactionId: UUID?
    let evidence: String

    func encode(to encoder: any Encoder) throws {
        try input.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(expectedRevision, forKey: .expectedRevision)
        try container.encode(action, forKey: .action)
        try container.encodeIfPresent(transactionId, forKey: .transactionId)
        try container.encode(evidence, forKey: .evidence)
    }

    private enum CodingKeys: String, CodingKey {
        case expectedRevision, action, transactionId, evidence
    }
}

nonisolated struct MvpRecoveryPreview: Decodable, Sendable {
    enum DateStatus: String, Decodable, Sendable {
        case eligible
        case timeRequired = "time_required"
        case outsideCoverage = "outside_coverage"
        case afterCheck = "after_check"
    }

    struct Candidate: Decodable, Identifiable, Sendable {
        let id: UUID
        let amountMinor: String
        let description: String?
        let occurredAt: Date?
        let occurrenceDay: String?
        let alreadyLinked: Bool
    }

    let accountId: UUID
    let checkId: UUID
    let revision: String
    let dateStatus: DateStatus
    let balanceMinor: String
    let remainingDifferenceMinor: String
    let projectedBalanceMinor: String?
    let projectedRemainingDifferenceMinor: String?
    let candidates: [Candidate]
    let existingRecovery: MvpRecoveryReceipt?
}

nonisolated struct MvpRecoveryReceipt: Decodable, Sendable {
    let id: UUID
    let accountId: UUID
    let checkId: UUID
    let transactionId: UUID
}

nonisolated enum MvpRecoveryTime {
    static func day(_ date: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func offset(_ date: Date, in zone: TimeZone) -> String {
        let offset = zone.secondsFromGMT(for: date)
        let seconds = abs(offset)
        return String(format: "UTC%@%02d:%02d", offset < 0 ? "−" : "+", seconds / 3600, (seconds % 3600) / 60)
    }

    static func instants(for time: String, on date: Date, in zone: TimeZone) -> [Date] {
        let parts = time.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ $0.count == 2 }),
              let hour = Int(parts[0]), (0...23).contains(hour),
              let minute = Int(parts[1]), (0...59).contains(minute),
              let second = parts.count == 3 ? Int(parts[2]) : 0, (0...59).contains(second) else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let start = calendar.startOfDay(for: date)
        let clock = DateComponents(hour: hour, minute: minute, second: second)
        let matches = [Calendar.RepeatedTimePolicy.first, .last].compactMap { policy in
            calendar.nextDate(
                after: start.addingTimeInterval(-1), matching: clock,
                matchingPolicy: .strict, repeatedTimePolicy: policy
            )
        }
        return Set(matches.filter { calendar.isDate($0, inSameDayAs: date) }).sorted()
    }
}
