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
        let baseURL: URL
        let session: URLSession
        let credentialStore: any CredentialStoring

#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-authenticated") {
            baseURL = URL(string: "http://127.0.0.1:1")!
            session = URLSession(configuration: .ephemeral)
            credentialStore = UITestCredentialStore()
        } else {
            baseURL = APIClient.productionBaseURL
            session = .shared
            credentialStore = KeychainCredentialStore()
        }
#else
        baseURL = APIClient.productionBaseURL
        session = .shared
        credentialStore = KeychainCredentialStore()
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
            initialValue: AuthenticationViewModel(session: authenticationSession)
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
