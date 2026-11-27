import Foundation

nonisolated protocol CredentialStoring: Sendable {
    func load() async throws -> AuthTokens?
    func save(_ tokens: AuthTokens) async throws
    func delete() async throws
}
