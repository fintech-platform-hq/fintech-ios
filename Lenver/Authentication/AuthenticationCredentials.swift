import Foundation

nonisolated struct AuthenticationCredentials: Encodable, Equatable, Sendable {
    let email: String
    let password: String
}
