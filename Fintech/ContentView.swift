//
//  ContentView.swift
//  Fintech
//
//  Created by Gabriel Ferrari on 31/07/26.
//

import SwiftUI

struct ContentView: View {
    let authenticationViewModel: AuthenticationViewModel
    let createTransactionViewModel: CreateTransactionViewModel

    var body: some View {
        Group {
            switch authenticationViewModel.state {
            case .restoring:
                ProgressView("Restoring session…")
            case .authenticated:
                CreateTransactionView(viewModel: createTransactionViewModel)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Sign Out") {
                                Task { await authenticationViewModel.logout() }
                            }
                        }
                    }
            case .unauthenticated, .authenticating, .failure:
                AuthenticationView(viewModel: authenticationViewModel)
            }
        }
        .task {
            await authenticationViewModel.restore()
        }
    }
}
