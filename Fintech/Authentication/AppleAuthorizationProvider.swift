import AuthenticationServices
import Foundation

@MainActor
protocol AppleAuthorizationProviding: Sendable {
    var operationID: UUID { get }
    func configure(_ request: ASAuthorizationAppleIDRequest) throws
    func authorization() async throws -> AppleAuthorizationResult
    func complete(_ result: Result<ASAuthorization, Error>, operationID: UUID)
}

@MainActor
final class AppleAuthorizationProvider: NSObject, AppleAuthorizationProviding {
    private var nonce: String?
    private var continuation: CheckedContinuation<AppleAuthorizationResult, Error>?
    private(set) var operationID = UUID()
    private var pendingResult: Result<AppleAuthorizationResult, Error>?
    private var waiting = false

    func configure(_ request: ASAuthorizationAppleIDRequest) throws {
        guard nonce == nil else { throw AuthenticationError.operationInProgress }
        let nonce = try AppleNonce.make()
        self.nonce = nonce
        request.requestedScopes = [.email]
        request.nonce = nonce
    }

    func authorization() async throws -> AppleAuthorizationResult {
        try await authorization(onWait: {})
    }

    func authorization(onWait: () -> Void) async throws -> AppleAuthorizationResult {
        guard nonce != nil else { throw AuthenticationError.invalidTokenResponse }
        let operationID = self.operationID
        guard !waiting else { throw AuthenticationError.operationInProgress }
        waiting = true
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    reset()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let pendingResult {
                    reset()
                    continuation.resume(with: pendingResult)
                    return
                }
                self.continuation = continuation
                onWait()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.operationID == operationID else { return }
                self?.resolve(.failure(CancellationError()))
            }
        }
    }

    func complete(_ result: Result<ASAuthorization, Error>, operationID: UUID) {
        guard self.operationID == operationID, nonce != nil, pendingResult == nil else { return }
        switch result {
        case let .failure(error):
            resolve(.failure(error))
        case let .success(authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let identityToken = credential.identityToken,
                  let authorizationCode = credential.authorizationCode,
                  let identityTokenString = String(data: identityToken, encoding: .utf8),
                  let authorizationCodeString = String(data: authorizationCode, encoding: .utf8) else {
                resolve(.failure(AuthenticationError.invalidTokenResponse))
                return
            }
            complete(identityToken: identityTokenString, authorizationCode: authorizationCodeString, operationID: operationID)
        }
    }

    func complete(identityToken: String, authorizationCode: String, operationID: UUID) {
        guard self.operationID == operationID, let nonce else { return }
        resolve(.success(AppleAuthorizationResult(
            identityToken: identityToken,
            authorizationCode: authorizationCode,
            nonce: nonce
        )))
    }

    private func resolve(_ result: Result<AppleAuthorizationResult, Error>) {
        guard nonce != nil, pendingResult == nil else { return }
        guard let continuation else {
            pendingResult = result
            return
        }
        reset()
        continuation.resume(with: result)
    }

    private func reset() {
        self.continuation = nil
        nonce = nil
        operationID = UUID()
        pendingResult = nil
        waiting = false
    }
}
