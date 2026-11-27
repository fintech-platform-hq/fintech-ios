import Foundation

nonisolated struct AuthTokens: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let tokenType: String
    let expiresIn: Int

    var isValid: Bool {
        !accessToken.isEmpty && !refreshToken.isEmpty
            && tokenType == "Bearer" && expiresIn > 0
    }
}

nonisolated struct RefreshTokenRequest: Encodable, Sendable {
    let refreshToken: String
}
