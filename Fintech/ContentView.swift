//
//  ContentView.swift
//  Fintech
//
//  Created by Gabriel Ferrari on 31/07/26.
//

import SwiftUI

struct ContentView: View {
    let authenticationViewModel: AuthenticationViewModel
    let createTransactionViewModel: CreateTransactionViewModel?
    let mvpAccountService: MvpAccountService?
    let authenticationSession: AuthenticationSession
    let mvpIntentStore: MvpIntentStore

    var body: some View {
        Group {
            switch authenticationViewModel.state {
            case .restoring:
                ProgressView("Restoring session…")
            case .authenticated:
                Group {
                    if let mvpAccountService {
                        MvpAccountView(
                            service: mvpAccountService, session: authenticationSession,
                            store: mvpIntentStore, onSignOut: signOut
                        )
                    } else if let createTransactionViewModel {
                        CreateTransactionView(viewModel: createTransactionViewModel, onSignOut: signOut)
                    }
                }
                .sheet(isPresented: Binding(get: { authenticationViewModel.shouldOfferAppleLink }, set: { if !$0 { authenticationViewModel.dismissAppleLinkOffer() } })) {
                    AuthenticationView(viewModel: authenticationViewModel)
                }
            case .unauthenticated, .authenticating, .failure:
                AuthenticationView(viewModel: authenticationViewModel)
            }
        }
        .task {
            await authenticationViewModel.restore()
        }
        .task {
            await authenticationViewModel.observeSession()
        }
    }
    private func signOut() {
        Task { await authenticationViewModel.logout() }
    }
}
