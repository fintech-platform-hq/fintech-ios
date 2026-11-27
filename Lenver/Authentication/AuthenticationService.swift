import Foundation

nonisolated protocol AuthenticationServicing: Sendable {
    func login(_ credentials: AuthenticationCredentials) async throws -> AuthTokens
    func register(_ credentials: AuthenticationCredentials) async throws -> AuthTokens
    func refresh(refreshToken: String) async throws -> AuthTokens
    func signInWithApple(_ authorization: AppleAuthorizationResult) async throws -> AuthTokens
    func linkApple(_ authorization: AppleAuthorizationResult, accessToken: String) async throws
    func linkApple(_ authorization: AppleAuthorizationResult, accessToken: String, password: String, operationID: UUID) async throws
    func logout(refreshToken: String) async throws
}

extension AuthenticationServicing {
    func linkApple(_ authorization: AppleAuthorizationResult, accessToken: String, password: String, operationID: UUID) async throws {
        try await linkApple(authorization, accessToken: accessToken)
    }
}

nonisolated struct AuthenticationService: AuthenticationServicing {
    private let apiClient: APIClient
    private let authPath: String

    init(apiClient: APIClient, identityV1: Bool = false) {
        self.apiClient = apiClient
        authPath = identityV1 ? "/v1/auth" : "/auth"
    }

    func register(_ credentials: AuthenticationCredentials) async throws -> AuthTokens {
        try await authenticate(
            path: "\(authPath)/register",
            credentials: credentials,
            expectedStatusCode: 201
        )
    }

    func login(_ credentials: AuthenticationCredentials) async throws -> AuthTokens {
        try await authenticate(
            path: "\(authPath)/login",
            credentials: credentials,
            expectedStatusCode: 200
        )
    }

    func refresh(refreshToken: String) async throws -> AuthTokens {
        try await perform {
            try await apiClient.post(
                path: "\(authPath)/refresh",
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
                    path: "\(authPath)/apple",
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
                path: "\(authPath)/apple/link",
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

    func linkApple(_ authorization: AppleAuthorizationResult, accessToken: String, password: String, operationID: UUID) async throws {
        try await perform {
            try await apiClient.postWithoutResponse(
                path: "\(authPath)/apple/link",
                body: AppleLinkProofRequest(
                    identityToken: authorization.identityToken,
                    authorizationCode: authorization.authorizationCode,
                    nonce: authorization.nonce,
                    password: password
                ),
                headers: ["Authorization": "Bearer \(accessToken)", "Idempotency-Key": operationID.uuidString],
                expectedStatusCode: 204
            )
        }
    }

    func logout(refreshToken: String) async throws {
        try await perform {
            try await apiClient.postWithoutResponse(
                path: "\(authPath)/logout",
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


private nonisolated struct AppleLinkProofRequest: Encodable, Sendable {
    let identityToken: String
    let authorizationCode: String
    let nonce: String
    let password: String
    var consent = true
}
