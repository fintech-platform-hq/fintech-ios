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
    @State private var createTransactionViewModel: CreateTransactionViewModel?
    private let mvpAccountService: MvpAccountService?
    private let authenticationSession: AuthenticationSession

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
        let useMvpAccount: Bool
#if DEBUG
        if case .staging = environment {
            useMvpAccount = ProcessInfo.processInfo.arguments.contains("-mvp-account")
        } else {
            useMvpAccount = false
        }
        if environment == .uiTesting {
            session = URLSession(configuration: .ephemeral)
            credentialStore = UITestCredentialStore()
        } else if let keychainService = environment.keychainService {
            session = .shared
            credentialStore = KeychainCredentialStore(
                service: useMvpAccount ? "\(keychainService).mvp.\(baseURL.absoluteString)" : keychainService
            )
        } else {
            preconditionFailure("Invalid app environment")
        }
#else
        useMvpAccount = false
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
        self.authenticationSession = authenticationSession
        mvpAccountService = useMvpAccount ? MvpAccountService(apiClient: authenticatedClient) : nil

        _authenticationViewModel = State(
            initialValue: AuthenticationViewModel(
                session: authenticationSession,
                appleProvider: AppleAuthorizationProvider()
            )
        )
        _createTransactionViewModel = State(
            initialValue: useMvpAccount ? nil : CreateTransactionViewModel(
                service: TransactionService(apiClient: authenticatedClient),
                disposableDemoAccountID: DemoConfiguration
                    .disposableTransactionAccountID
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                authenticationViewModel: authenticationViewModel,
                createTransactionViewModel: createTransactionViewModel,
                mvpAccountService: mvpAccountService,
                authenticationSession: authenticationSession
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
