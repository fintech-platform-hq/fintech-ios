import SwiftUI

struct MvpAccountView: View {
    @State private var viewModel: MvpAccountViewModel
    @State private var amount = ""
    @State private var start = Date.now
    @State private var isOpening = false
    @FocusState private var amountFocused: Bool

    private let zone = TimeZone.current
    private let locale = Locale(identifier: "pt_BR")
    let onSignOut: () -> Void

    init(service: MvpAccountService, session: AuthenticationSession, onSignOut: @escaping () -> Void) {
        _viewModel = State(initialValue: MvpAccountViewModel(service: service, session: session))
        self.onSignOut = onSignOut
    }

    var body: some View {
        NavigationStack {
            Form {
                switch viewModel.state {
                case .loading:
                    ProgressView("Consultando conta…")
                case .failed:
                    Section {
                        Text("Não foi possível consultar sua conta.")
                        Button("Tentar novamente") { Task { await viewModel.load() } }
                    }
                case let .loaded(summary):
                    accountContent(summary)
                }

                if let message = viewModel.message {
                    Text(message)
                        .accessibilityIdentifier("mvp.account.message")
                }
            }
            .navigationTitle("Conta pessoal")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sair", action: onSignOut)
                }
            }
            .refreshable { await viewModel.load() }
        }
        .task { await viewModel.load() }
    }

    @ViewBuilder
    private func accountContent(_ summary: MvpAccountSummary) -> some View {
        switch summary.status {
        case .noAccount:
            if isOpening {
                openingForm
            } else {
                Section {
                    Text("Você ainda não tem uma conta pessoal ativa.")
                    Button("Abrir conta pessoal em reais") { isOpening = true }
                }
                if !summary.legacyAccounts.isEmpty {
                    Section("Contas existentes") {
                        ForEach(summary.legacyAccounts) { account in
                            Button(account.name) {
                                Task { await viewModel.load(accountID: account.id) }
                            }
                        }
                    }
                }
            }
        case .baseRequired:
            Section("Saldo") {
                Text(summary.account?.name ?? "Conta existente")
                Text("Saldo indisponível. Esta conta ainda não tem uma base confirmada.")
                Button("Voltar à conta pessoal") { Task { await viewModel.load() } }
            }
        case .unavailable:
            Section("Saldo") {
                Text("Saldo indisponível para este horário.")
            }
        case .available:
            Section("Saldo atual") {
                if let balance = summary.balanceMinor {
                    Text(MvpAccountViewModel.money(balance))
                        .font(.title2.monospacedDigit())
                        .accessibilityIdentifier("mvp.account.balance")
                }
                Text("Consultado em \(dateLabel(summary.asOf, in: zone))")
            }
            if let base = summary.base {
                Section("Base confirmada") {
                    LabeledContent("Saldo inicial", value: MvpAccountViewModel.money(base.baseMinor))
                    LabeledContent("Início da cobertura", value: coverageLabel(base.coverageStart, in: base.referenceZone))
                }
            }
        }
    }

    @ViewBuilder
    private var openingForm: some View {
        if let preview = viewModel.preview {
            Section("Revise a base inicial") {
                LabeledContent("Saldo inicial", value: MvpAccountViewModel.money(preview.baseMinor))
                LabeledContent("Início da cobertura", value: coverageLabel(preview.coverageStart, in: preview.referenceZone))
                Text("O saldo inicial deve refletir o momento imediatamente anterior ao início da cobertura.")
                if viewModel.busy {
                    ProgressView("Confirmando abertura…")
                } else if viewModel.hasPendingOpening {
                    Button("Tentar confirmar novamente") { Task { await viewModel.confirm() } }
                    Button("Consultar conta") { Task { await viewModel.checkPendingAccount() } }
                } else {
                    Button("Confirmar abertura") { Task { await viewModel.confirm() } }
                    Button("Editar base") { viewModel.edit() }
                }
            }
        } else {
            Section("Base inicial") {
                TextField("Saldo inicial em reais", text: $amount)
                    .keyboardType(.numbersAndPunctuation)
                    .focused($amountFocused)
                    .accessibilityIdentifier("mvp.account.openingAmount")
                DatePicker("Início da cobertura", selection: $start, in: ...Date.now)
                    .environment(\.timeZone, zone)
                    .environment(\.locale, locale)
                Text("Informe o saldo imediatamente anterior à data e hora escolhidas. Zero e valores negativos são válidos.")
                if viewModel.busy {
                    ProgressView("Revisando base…")
                } else {
                    Button("Revisar abertura") {
                        amountFocused = false
                        let minute = Date(timeIntervalSince1970: floor(start.timeIntervalSince1970 / 60) * 60)
                        Task { await viewModel.review(amount: amount, start: minute, zone: zone) }
                    }
                    Button("Cancelar", role: .cancel) { isOpening = false }
                }
            }
            .disabled(viewModel.busy)
        }
    }

    private func coverageLabel(_ date: Date, in identifier: String) -> String {
        let referenceZone = TimeZone(identifier: identifier) ?? zone
        return "\(dateLabel(date, in: referenceZone)) (\(identifier))"
    }

    private func dateLabel(_ date: Date, in timeZone: TimeZone) -> String {
        let format = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, timeZone: timeZone)
        return date.formatted(format)
    }
}
