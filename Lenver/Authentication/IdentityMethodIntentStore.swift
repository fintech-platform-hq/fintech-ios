import CryptoKit
import Foundation

actor IdentityMethodIntentStore {
    private let path: URL

    init(environment: String, root: URL = .applicationSupportDirectory) {
        let key = SHA256.hash(data: Data(environment.utf8)).map { String(format: "%02x", $0) }.joined()
        path = root.appending(path: "IdentityMethodIntents", directoryHint: .isDirectory)
            .appending(path: key, directoryHint: .notDirectory)
    }

    func load(family: UUID) throws -> IdentityMethodIntent? {
        do {
            let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: path))
            return record.family == family ? record.intent : nil
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    func save(_ intent: IdentityMethodIntent, family: UUID) throws {
        if let current = try load(family: family), current != intent {
            throw CocoaError(.fileWriteFileExists)
        }
        var directory = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try JSONEncoder().encode(Record(family: family, intent: intent))
            .write(to: path, options: [.atomic, .completeFileProtection])
    }

    func remove(_ intent: IdentityMethodIntent, family: UUID) throws {
        guard try load(family: family) == intent else { return }
        try FileManager.default.removeItem(at: path)
    }

    private struct Record: Codable {
        let family: UUID
        let intent: IdentityMethodIntent
    }
}
