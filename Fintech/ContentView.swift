//
//  ContentView.swift
//  Fintech
//
//  Created by Gabriel Ferrari on 31/07/26.
//

import SwiftUI

struct ContentView: View {
    let createTransactionViewModel: CreateTransactionViewModel

    var body: some View {
        CreateTransactionView(viewModel: createTransactionViewModel)
    }
}
