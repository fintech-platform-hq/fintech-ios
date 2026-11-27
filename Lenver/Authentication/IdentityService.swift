import Foundation

nonisolated struct IdentityStatus: Decodable, Sendable {
    let email: String?
    let passwordVerified: Bool
    let hasPassword: Bool
    let hasApple: Bool
    let financialAccess: Bool
    let authMethod: String
}

nonisolated struct IdentityMethodIntent: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable {
        case linkApple = "apple_link"
        case unlinkApple = "apple_unlink"
        case linkPassword = "password_link"
        case unlinkPassword = "password_unlink"
    }

    let id: UUID
    let action: Action
}

nonisolated struct IdentityService: Sendable {
    let publicClient: APIClient
    let sessionClient: APIClient

    func status(generation: Int) async throws -> IdentityStatus {
        try await sessionClient.get(path: "/v1/auth/session", expectedGeneration: generation)
    }

    func sendVerification(generation: Int) async throws {
        try await write("verification", body: Empty(), status: 202, generation: generation)
    }

    func verify(code: String, generation: Int) async throws {
        try await write("verification/confirm", body: Code(code: code), generation: generation)
    }

    func requestRecovery(email: String) async throws {
        try await write("recovery", body: Email(email: email), status: 202)
    }

    func recover(email: String, code: String, password: String) async throws {
        try await write("recovery/confirm", body: Recovery(email: email, code: code, newPassword: password))
    }

    func changePendingEmail(email: String, password: String, generation: Int) async throws {
        try await write("verification/email", body: AuthenticationCredentials(email: email, password: password), generation: generation)
    }

    func requestPasswordLink(email: String, authorization: AppleAuthorizationResult, generation: Int) async throws {
        try await write("password/link", body: PasswordLink(
            email: email, identityToken: authorization.identityToken,
            authorizationCode: authorization.authorizationCode, nonce: authorization.nonce
        ), status: 202, generation: generation)
    }

    func linkPassword(email: String, code: String, password: String, operationID: UUID, generation: Int) async throws {
        try await write("password/link/confirm", body: Recovery(email: email, code: code, newPassword: password), generation: generation, operationID: operationID)
    }

    func unlinkPassword(authorization: AppleAuthorizationResult, operationID: UUID, generation: Int) async throws {
        try await write("password/unlink", body: AppleAuthenticationRequest(
            identityToken: authorization.identityToken, authorizationCode: authorization.authorizationCode,
            nonce: authorization.nonce
        ), generation: generation, operationID: operationID)
    }

    func unlinkApple(password: String, operationID: UUID, generation: Int) async throws {
        try await write("apple/unlink", body: Password(password: password), generation: generation, operationID: operationID)
    }

    func methodCommitted(_ intent: IdentityMethodIntent, generation: Int) async throws -> Bool {
        let response: MethodOutcome = try await sessionClient.get(
            path: "/v1/auth/method-operations/\(intent.id.uuidString)", expectedGeneration: generation
        )
        return response.status == "committed" && response.action == intent.action
    }

    func prepareChange(id: UUID, password: String, generation: Int) async throws -> String {
        let response: Proof = try await sessionClient.post(
            path: "/v1/auth/password/change/proof",
            body: PrepareChange(operationId: id, password: password), headers: [:],
            expectedStatusCode: 200, expectedGeneration: generation
        )
        return response.proof
    }

    func changePassword(id: UUID, proof: String, password: String, generation: Int) async throws {
        try await write("password/change", body: CommitChange(operationId: id, proof: proof, newPassword: password), generation: generation)
    }

    func changeCommitted(id: UUID, generation: Int) async throws -> Bool {
        let response: Outcome = try await sessionClient.get(
            path: "/v1/auth/password/change/\(id.uuidString)", expectedGeneration: generation
        )
        return response.status == "committed"
    }

    private func write(
        _ path: String,
        body: some Encodable & Sendable,
        status: Int = 204,
        generation: Int? = nil,
        operationID: UUID? = nil
    ) async throws {
        let client = generation == nil ? publicClient : sessionClient
        let headers = operationID.map { ["Idempotency-Key": $0.uuidString] } ?? [:]
        try await client.postWithoutResponse(
            path: "/v1/auth/\(path)", body: body, headers: headers,
            expectedStatusCode: status, expectedGeneration: generation
        )
    }

    private struct PasswordLink: Encodable, Sendable {
        let email: String
        let identityToken: String
        let authorizationCode: String
        let nonce: String
        var consent = true
    }
    private struct Empty: Encodable, Sendable {}
    private struct Code: Encodable, Sendable { let code: String }
    private struct Email: Encodable, Sendable { let email: String }
    private struct Password: Encodable, Sendable { let password: String }
    private struct Recovery: Encodable, Sendable { let email: String; let code: String; let newPassword: String }
    private struct PrepareChange: Encodable, Sendable { let operationId: UUID; let password: String }
    private struct CommitChange: Encodable, Sendable { let operationId: UUID; let proof: String; let newPassword: String }
    private struct Proof: Decodable, Sendable { let proof: String }
    private struct MethodOutcome: Decodable, Sendable {
        let status: String
        let action: IdentityMethodIntent.Action?
    }
    private struct Outcome: Decodable, Sendable { let status: String }
}
