import CryptoKit
import Foundation

nonisolated struct MvpIntent: Codable, Equatable, Sendable {
    enum Operation: String, Codable, Sendable {
        case opening = "/mvp/account"
        case transaction = "/mvp/transactions"
        case check = "/mvp/checks"
        case recovery = "/mvp/recoveries"
    }

    let environment: String
    let principalID: UUID
    let accountID: UUID?
    let operation: Operation
    let key: UUID
    let body: Data
}

actor MvpIntentStore {
    enum StorageError: Error {
        case invalidProtection
        case differentIntent
    }

    private let root: URL

    init(root: URL = URL.applicationSupportDirectory.appending(path: "MvpIntents", directoryHint: .isDirectory)) {
        self.root = root
    }

    func load(environment: String, principalID: UUID) throws -> MvpIntent? {
        let url = location(environment: environment, principalID: principalID)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        try verifyProtection(url)
        if try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup != true {
            // A process may have stopped after atomic rename. The parent was
            // excluded before the write, so finishing the file metadata is safe.
            try excludeFromBackup(root)
            try excludeFromBackup(url)
        }
        let intent = try JSONDecoder().decode(MvpIntent.self, from: data)
        guard intent.environment == environment, intent.principalID == principalID else {
            throw StorageError.differentIntent
        }
        return intent
    }

    func save(_ intent: MvpIntent) throws {
        let url = location(environment: intent.environment, principalID: intent.principalID)
        if let current = try load(environment: intent.environment, principalID: intent.principalID) {
            guard current == intent else { throw StorageError.differentIntent }
            return
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try excludeFromBackup(root)
        try JSONEncoder().encode(intent).write(to: url, options: [.atomic, .completeFileProtection])
        try excludeFromBackup(url)
        try verifyProtection(url)
    }

    func remove(_ intent: MvpIntent) throws {
        guard let current = try load(environment: intent.environment, principalID: intent.principalID) else { return }
        guard current == intent else { throw StorageError.differentIntent }
        try FileManager.default.removeItem(at: location(environment: intent.environment, principalID: intent.principalID))
    }

    private func location(environment: String, principalID: UUID) -> URL {
        let digest = SHA256.hash(data: Data("\(environment)\n\(principalID.uuidString)".utf8))
        return root.appending(path: digest.map { String(format: "%02x", $0) }.joined(), directoryHint: .notDirectory)
    }

    private func excludeFromBackup(_ location: URL) throws {
        var url = location
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        guard try location.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true else {
            throw StorageError.invalidProtection
        }
    }

    private func verifyProtection(_ url: URL) throws {
        // Simulator accepts the write option but does not report its protection
        // class. The device path verifies the class before any intent is sent.
#if !targetEnvironment(simulator)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let protection = attributes[.protectionKey]
        guard (protection as? FileProtectionType)?.rawValue == FileProtectionType.complete.rawValue ||
              (protection as? String) == FileProtectionType.complete.rawValue else {
            throw StorageError.invalidProtection
        }
#endif
    }
}
