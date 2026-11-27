import Foundation

nonisolated struct AppleAuthenticationRequest: Encodable, Sendable {
    let identityToken: String
    let authorizationCode: String
    let nonce: String
}

nonisolated struct AppleAuthorizationResult: Sendable {
    let identityToken: String
    let authorizationCode: String
    let nonce: String
}
