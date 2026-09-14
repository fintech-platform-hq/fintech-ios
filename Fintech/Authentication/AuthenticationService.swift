import Foundation

nonisolated protocol AuthenticationServicing: Sendable {
    func login(_ credentials: AuthenticationCredentials) async throws -> AuthTokens
    func register(_ credentials: AuthenticationCredentials) async throws -> AuthTokens
    func refresh(refreshToken: String) async throws -> AuthTokens
    func signInWithApple(_ authorization: AppleAuthorizationResult) async throws -> AuthTokens
    func linkApple(_ authorization: AppleAuthorizationResult, accessToken: String) async throws
    func logout(refreshToken: String) async throws
}

nonisolated struct AuthenticationService: AuthenticationServicing {
    private let apiClient: APIClient

    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    func register(_ credentials: AuthenticationCredentials) async throws -> AuthTokens {
        try await authenticate(
            path: "/auth/register",
            credentials: credentials,
            expectedStatusCode: 201
        )
    }

    func login(_ credentials: AuthenticationCredentials) async throws -> AuthTokens {
        try await authenticate(
            path: "/auth/login",
            credentials: credentials,
            expectedStatusCode: 200
        )
    }

    func refresh(refreshToken: String) async throws -> AuthTokens {
        try await perform {
            try await apiClient.post(
                path: "/auth/refresh",
                body: RefreshTokenRequest(refreshToken: refreshToken),
                headers: [:],
                expectedStatusCode: 200
            ) as AuthTokens
        }
    }

    func signInWithApple(_ authorization: AppleAuthorizationResult) async throws -> AuthTokens {
        do {
            return try await perform {
                try await apiClient.post(
                    path: "/auth/apple",
                    body: AppleAuthenticationRequest(
                        identityToken: authorization.identityToken,
                        authorizationCode: authorization.authorizationCode,
                        nonce: authorization.nonce
                    ),
                    headers: [:],
                    expectedStatusCode: 200
                ) as AuthTokens
            }
        } catch AuthenticationError.request(.accountLinkRequired) {
            throw AuthenticationError.accountLinkRequired
        }
    }

    func linkApple(_ authorization: AppleAuthorizationResult, accessToken: String) async throws {
        do {
            try await apiClient.postWithoutResponse(
                path: "/auth/apple/link",
                body: AppleAuthenticationRequest(
                    identityToken: authorization.identityToken,
                    authorizationCode: authorization.authorizationCode,
                    nonce: authorization.nonce
                ),
                headers: ["Authorization": "Bearer \(accessToken)"],
                expectedStatusCode: 204
            )
        } catch let error as APIError {
            throw AuthenticationError.request(error)
        }
    }

    func logout(refreshToken: String) async throws {
        try await perform {
            try await apiClient.postWithoutResponse(
                path: "/auth/logout",
                body: RefreshTokenRequest(refreshToken: refreshToken),
                headers: [:],
                expectedStatusCode: 204
            )
        }
    }

    private func authenticate(
        path: String,
        credentials: AuthenticationCredentials,
        expectedStatusCode: Int
    ) async throws -> AuthTokens {
        try await perform {
            try await apiClient.post(
                path: path,
                body: credentials,
                headers: [:],
                expectedStatusCode: expectedStatusCode
            ) as AuthTokens
        }
    }

    private func perform<T: Sendable>(
        _ operation: () async throws -> T
    ) async throws -> T {
        do {
            let result = try await operation()
            if let tokens = result as? AuthTokens, !tokens.isValid {
                throw AuthenticationError.invalidTokenResponse
            }
            return result
        } catch let error as AuthenticationError {
            throw error
        } catch let error as APIError {
            throw AuthenticationError.request(error)
        }
    }
}
