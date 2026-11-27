//
//  ContentView.swift
//  Lenver
//
//  Created by Gabriel Ferrari on 31/07/26.
//

import SwiftUI

struct ContentView: View {
    let authenticationViewModel: AuthenticationViewModel
    let transactionService: TransactionService?
    let identityService: IdentityService?
    let mvpAccountService: MvpAccountService?
    let authenticationSession: AuthenticationSession
    let mvpIntentStore: MvpIntentStore

    @Environment(\.scenePhase) private var scenePhase
    @State private var showsIdentity = false

    var body: some View {
        Group {
            switch authenticationViewModel.state {
            case .restoring:
                ProgressView("Restoring session…")
            case .authenticated:
                if let identityService, authenticationViewModel.identityStatus?.financialAccess != true {
                    IdentityVerificationView(
                        service: identityService, session: authenticationSession, model: authenticationViewModel
                    )
                } else {
                    authenticatedContent
                }
            case .unauthenticated, .authenticating, .failure:
                AuthenticationView(viewModel: authenticationViewModel, identityService: identityService)
            }
        }
        .concealWhenInactive()
        .task { await authenticationViewModel.restore() }
        .task { await authenticationViewModel.observeSession() }
        .task(id: scenePhase) {
            if scenePhase == .active, authenticationViewModel.state == .authenticated {
                await authenticationViewModel.reloadIdentity()
            }
        }
        .onChange(of: authenticationViewModel.state) { _, state in
            if state != .authenticated { showsIdentity = false }
        }
    }

    private var authenticatedContent: some View {
        Group {
            if let mvpAccountService {
                MvpAccountView(
                    service: mvpAccountService, session: authenticationSession,
                    store: mvpIntentStore, onSignOut: signOut,
                    onOpenIdentity: identityService == nil ? nil : { showsIdentity = true }
                )
            } else if let transactionService {
                LegacyTransactionSessionView(service: transactionService, signOut: signOut)
            } else {
                identityNavigation(canClose: false)
            }
        }
        .sheet(isPresented: $showsIdentity) { identityNavigation(canClose: true) }
        .sheet(isPresented: Binding(
            get: { authenticationViewModel.shouldOfferAppleLink && !authenticationViewModel.linkFromSecurity && !showsIdentity },
            set: { if !$0 { authenticationViewModel.dismissAppleLinkOffer() } }
        )) {
            AuthenticationView(viewModel: authenticationViewModel)
        }
    }

    @ViewBuilder
    private func identityNavigation(canClose: Bool) -> some View {
        if let identityService {
            NavigationStack {
                UserIdentityView(service: identityService, session: authenticationSession, model: authenticationViewModel)
                    .toolbar {
                        if canClose {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Close") { showsIdentity = false }
                            }
                        }
                    }
            }
            .concealWhenInactive()
        }
    }

    private func signOut() {
        Task { await authenticationViewModel.logout() }
    }
}

private struct LegacyTransactionSessionView: View {
    @State private var model: CreateTransactionViewModel
    let signOut: () -> Void

    init(service: TransactionService, signOut: @escaping () -> Void) {
        _model = State(initialValue: CreateTransactionViewModel(
            service: service, disposableDemoAccountID: DemoConfiguration.disposableTransactionAccountID
        ))
        self.signOut = signOut
    }

    var body: some View {
        CreateTransactionView(viewModel: model, onSignOut: signOut)
    }
}


extension View {
    func concealWhenInactive() -> some View {
        modifier(InactiveSceneCover())
    }
}

private struct InactiveSceneCover: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.overlay {
            if scenePhase != .active {
                Rectangle()
                    .fill(Color(.systemBackground))
                    .ignoresSafeArea()
                    .overlay { Text("Lenver").font(.headline) }
                    .accessibilityHidden(true)
            }
        }
    }
}
