//
//  FintechApp.swift
//  Fintech
//
//  Created by Gabriel Ferrari on 31/07/26.
//

import Foundation
import SwiftUI

@main
struct FintechApp: App {
    @State private var authenticationViewModel: AuthenticationViewModel
    @State private var createTransactionViewModel: CreateTransactionViewModel

    init() {
        let environment: AppEnvironment
        let baseURL: URL
        let session: URLSession
        let credentialStore: any CredentialStoring

        do {
            environment = try AppEnvironment.resolve(
                arguments: ProcessInfo.processInfo.arguments,
                environment: ProcessInfo.processInfo.environment
            )
        } catch {
            preconditionFailure("-staging requires a valid HTTPS FINTECH_STAGING_BASE_URL")
        }

        baseURL = environment.baseURL
#if DEBUG
        if environment == .uiTesting {
            session = URLSession(configuration: .ephemeral)
            credentialStore = UITestCredentialStore()
        } else if let keychainService = environment.keychainService {
            session = .shared
            credentialStore = KeychainCredentialStore(service: keychainService)
        } else {
            preconditionFailure("Invalid app environment")
        }
#else
        session = .shared
        credentialStore = KeychainCredentialStore(
            service: AppEnvironment.productionKeychainService
        )
#endif

        let unauthenticatedClient = APIClient(
            baseURL: baseURL,
            session: session
        )
        let authenticationService = AuthenticationService(
            apiClient: unauthenticatedClient
        )
        let authenticationSession = AuthenticationSession(
            service: authenticationService,
            credentialStore: credentialStore
        )
        let authenticatedClient = APIClient(
            baseURL: baseURL,
            session: session,
            authenticationSession: authenticationSession
        )
        let transactionService = TransactionService(apiClient: authenticatedClient)

        _authenticationViewModel = State(
            initialValue: AuthenticationViewModel(
                session: authenticationSession,
                appleProvider: AppleAuthorizationProvider()
            )
        )
        _createTransactionViewModel = State(
            initialValue: CreateTransactionViewModel(
                service: transactionService,
                disposableDemoAccountID: DemoConfiguration
                    .disposableTransactionAccountID
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                authenticationViewModel: authenticationViewModel,
                createTransactionViewModel: createTransactionViewModel
            )
        }
    }
}

#if DEBUG
private actor UITestCredentialStore: CredentialStoring {
    private var tokens: AuthTokens? = AuthTokens(
        accessToken: "ui-test-access",
        refreshToken: "ui-test-refresh",
        tokenType: "Bearer",
        expiresIn: 900
    )

    func load() async throws -> AuthTokens? { tokens }

    func save(_ tokens: AuthTokens) async throws {
        self.tokens = tokens
    }

    func delete() async throws {
        tokens = nil
    }
}
#endif
