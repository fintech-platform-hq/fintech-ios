//
//  LenverApp.swift
//  Lenver
//
//  Created by Gabriel Ferrari on 31/07/26.
//

import Foundation
import SwiftUI

@main
struct LenverApp: App {
    @State private var authenticationViewModel: AuthenticationViewModel
    private let transactionService: TransactionService?
    private let identityService: IdentityService?
    private let mvpAccountService: MvpAccountService?
    private let mvpIntentStore = MvpIntentStore()
    private let authenticationSession: AuthenticationSession

    init() {
        let environment: AppEnvironment
        let baseURL: URL
        let session: URLSession
        let credentialStore: any CredentialStoring

        do {
            environment = try AppEnvironment.resolve(
                arguments: ProcessInfo.processInfo.arguments,
                environment: ProcessInfo.processInfo.environment,
                releaseConfiguration: Bundle.main.infoDictionary ?? [:]
            )
        } catch {
            preconditionFailure("Invalid build or API configuration for the selected environment")
        }

        baseURL = environment.baseURL
        let useLegacyTransactions: Bool
#if DEBUG
        let useMvpAccount: Bool
        if case .staging = environment {
            useMvpAccount = ProcessInfo.processInfo.arguments.contains("-mvp-account") ||
                ProcessInfo.processInfo.arguments.contains("-local-identity")
        } else {
            useMvpAccount = false
        }
        useLegacyTransactions = !useMvpAccount
        if environment == .uiTesting {
            session = URLSession(configuration: .ephemeral)
            credentialStore = UITestCredentialStore()
        } else if baseURL.scheme == "http", baseURL.host == "127.0.0.1",
                  ProcessInfo.processInfo.arguments.contains("-local-identity"),
                  ProcessInfo.processInfo.environment["LENVER_IDENTITY_UI_TEST_CREDENTIALS"] == "1" {
            session = URLSession(configuration: .ephemeral)
            credentialStore = LocalIdentityTestCredentialStore(endpoint: baseURL)
        } else if let keychainService = environment.keychainService {
            session = .shared
            credentialStore = KeychainCredentialStore(
                service: useMvpAccount ? "\(keychainService).mvp.\(baseURL.absoluteString)" : keychainService
            )
        } else {
            preconditionFailure("Invalid app environment")
        }
#else
        useLegacyTransactions = environment == .production
        session = .shared
        credentialStore = KeychainCredentialStore(
            service: environment.keychainService ?? AppEnvironment.productionKeychainService
        )
#endif

        let unauthenticatedClient = APIClient(
            baseURL: baseURL,
            session: session
        )
        let useIdentityV1: Bool
        if case .staging = environment {
#if DEBUG
            let args = ProcessInfo.processInfo.arguments
            useIdentityV1 = args.contains("-local-identity") || args.contains("-identity-v1")
#else
            useIdentityV1 = true
#endif
        } else {
            useIdentityV1 = false
        }
        let authenticationService = AuthenticationService(
            apiClient: unauthenticatedClient, identityV1: useIdentityV1
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
#if DEBUG
        mvpAccountService = useMvpAccount ? MvpAccountService(apiClient: authenticatedClient) : nil
#else
        mvpAccountService = nil
#endif

        identityService = useIdentityV1 ? IdentityService(
            publicClient: unauthenticatedClient, sessionClient: authenticatedClient
        ) : nil
        _authenticationViewModel = State(
            initialValue: AuthenticationViewModel(
                session: authenticationSession,
                appleProvider: AppleAuthorizationProvider(
                    isEnabled: environment.allowsAppleAuthorization(bundleIdentifier: Bundle.main.bundleIdentifier)
                ),
                identityService: identityService,
                methodIntentStore: useIdentityV1 ? IdentityMethodIntentStore(environment: baseURL.absoluteString) : nil
            )
        )
        transactionService = useLegacyTransactions ? TransactionService(apiClient: authenticatedClient) : nil
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                authenticationViewModel: authenticationViewModel,
                transactionService: transactionService,
                identityService: identityService,
                mvpAccountService: mvpAccountService,
                authenticationSession: authenticationSession,
                mvpIntentStore: mvpIntentStore
            )
            .environment(\.locale, LenverLocale.selected)
        }
    }
}

#if DEBUG
private actor LocalIdentityTestCredentialStore: CredentialStoring {
    private let endpoint: URL

    init(endpoint: URL) { self.endpoint = endpoint }

    private func file() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return directory.appending(path: "synthetic-loopback-session-\(endpoint.port ?? 0)")
    }

    func load() async throws -> AuthTokens? {
        do {
            return try JSONDecoder().decode(AuthTokens.self, from: Data(contentsOf: file()))
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    func save(_ tokens: AuthTokens) async throws {
        try JSONEncoder().encode(tokens).write(to: file(), options: [.atomic, .completeFileProtection])
    }

    func delete() async throws {
        do { try FileManager.default.removeItem(at: file()) }
        catch CocoaError.fileNoSuchFile {}
    }
}

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
