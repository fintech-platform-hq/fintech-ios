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
    @State private var createTransactionViewModel: CreateTransactionViewModel

    init() {
        let apiClient = APIClient(
            baseURL: APIClient.productionBaseURL,
            session: .shared
        )
        let transactionService = TransactionService(apiClient: apiClient)

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
                createTransactionViewModel: createTransactionViewModel
            )
        }
    }
}
