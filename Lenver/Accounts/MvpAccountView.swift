import SwiftUI
import UIKit

struct MvpAccountView: View {
    @State private var viewModel: MvpAccountViewModel
    @State private var amount = ""
    @State private var start = Date.now
    @State private var isOpening = false
    @State private var checkBase: MvpAccountSummary.Base?
    @FocusState private var amountFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    private let zone = TimeZone.current
    @Environment(\.locale) private var locale
    let onSignOut: () -> Void
    let onOpenIdentity: (() -> Void)?

    init(
        service: MvpAccountService, session: AuthenticationSession, store: MvpIntentStore,
        onSignOut: @escaping () -> Void, onOpenIdentity: (() -> Void)? = nil
    ) {
        _viewModel = State(initialValue: MvpAccountViewModel(
            service: service, session: session, store: store,
            canSend: {
                UIApplication.shared.applicationState == .active && UIApplication.shared.isProtectedDataAvailable
            }
        ))
        self.onOpenIdentity = onOpenIdentity
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
                        reloadButton
                    }
                case .unavailable:
                    Section {
                        Text("Saldo e histórico temporariamente indisponíveis.")
                        reloadButton
                    }
                case let .loaded(summary):
                    accountContent(summary)
                    if let base = summary.base, let accountID = summary.account?.id {
                        baseTools(base, accountID: accountID, suspended: summary.baseSuspended == true)
                    }
                }

                submissionStatus
                if case let .loaded(summary) = viewModel.state, summary.account != nil {
                    history(summary: summary, zone: summary.base.flatMap { TimeZone(identifier: $0.referenceZone) } ?? zone)
                }
            }
            .navigationTitle("Conta pessoal")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let onOpenIdentity {
                        Button("User Account", systemImage: "person.crop.circle", action: onOpenIdentity)
                            .labelStyle(.iconOnly)
                            .accessibilityShowsLargeContentViewer()
                            .accessibilityIdentifier("identity.open")
                    } else if dynamicTypeSize.isAccessibilitySize {
                        Button("Sair", systemImage: "rectangle.portrait.and.arrow.right", action: onSignOut)
                            .labelStyle(.iconOnly)
                            .accessibilityShowsLargeContentViewer()
                    } else {
                        Button("Sair", action: onSignOut)
                    }
                }
            }
            .refreshable { await viewModel.load(recover: onOpenIdentity == nil, keepSelection: true) }
            .sheet(isPresented: Binding(
                get: { checkBase != nil },
                set: { if !$0 { checkBase = nil } }
            )) {
                if let checkBase {
                    MvpCheckView(model: viewModel, base: checkBase).concealWhenInactive()
                }
            }
            .sheet(isPresented: Binding(
                get: { viewModel.transactionForm != nil },
                set: { if !$0 { viewModel.transactionForm = nil } }
            )) {
                if let form = viewModel.transactionForm,
                   case let .loaded(summary) = viewModel.state, let base = summary.base {
                    CreateTransactionView(
                        viewModel: form,
                        occurrenceRange: base.coverageStart...max(base.coverageStart, Date.now),
                        occurrenceZone: TimeZone(identifier: base.referenceZone),
                        onClose: { viewModel.transactionForm = nil }
                    )
                    .concealWhenInactive()
                }
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active, viewModel.transactionForm == nil, checkBase == nil else { return }
            await viewModel.load(recover: onOpenIdentity == nil, keepSelection: true)
        }
        .onChange(of: viewModel.message) { _, message in
            if let message { UIAccessibility.post(notification: .announcement, argument: message) }
        }
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
                        .disabled(!viewModel.canWrite)
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
                Text(summary.baseSuspended == true
                     ? "Saldo e recálculos suspensos até a revisão da base."
                     : "Saldo indisponível para este horário.")
                    .accessibilityIdentifier("mvp.base.suspended")
            }
        case .available:
            Section("Saldo atual") {
                if viewModel.hasPendingBaseChange {
                    Text("Saldo indisponível enquanto o envio aguarda confirmação.")
                } else if let balance = summary.balanceMinor {
                    Text(MvpAccountViewModel.money(balance))
                        .font(.title2.monospacedDigit())
                        .accessibilityIdentifier("mvp.account.balance")
                }
                Text("Consultado em \(dateLabel(summary.asOf, in: zone))")
            }
            if let check = viewModel.checkReceipt, let base = summary.base {
                Section("Conferência confirmada") {
                    MvpCheckValues(
                        reference: check.referenceAt, zone: TimeZone(identifier: base.referenceZone) ?? zone,
                        observed: check.observedMinor, calculated: check.originalCalculatedMinor,
                        difference: check.originalDifferenceMinor
                    )
                    Button("Registrar lançamento") { viewModel.startTransaction() }
                        .disabled(!viewModel.canWrite)
                }
            }
            Section {
                if viewModel.checkReceipt == nil {
                    Button("Registrar lançamento") { viewModel.startTransaction() }
                        .disabled(!viewModel.canWrite)
                }
                if let base = summary.base {
                    Button("Conferir saldo") {
                        viewModel.editCheck()
                        checkBase = base
                    }
                    .disabled(!viewModel.canWrite)
                }
                if let accountID = summary.account?.id {
                    NavigationLink("Conferências e pendências") {
                        MvpChecksView(model: viewModel, accountID: accountID)
                    }
                    .accessibilityIdentifier("mvp.checks.open")
                }
            }
        }
    }

    private func baseTools(_ base: MvpAccountSummary.Base, accountID: UUID, suspended: Bool) -> some View {
        let referenceZone = TimeZone(identifier: base.referenceZone) ?? zone
        return Section(suspended ? "Base em revisão" : "Base confirmada") {
            if !suspended && !viewModel.hasPendingBaseChange {
                LabeledContent("Saldo inicial", value: MvpAccountViewModel.money(base.baseMinor))
                LabeledContent("Início da cobertura", value: coverageLabel(base.coverageStart, in: base.referenceZone))
            }
            if suspended {
                NavigationLink("Conferências e pendências") {
                    MvpChecksView(model: viewModel, accountID: accountID)
                }
                .accessibilityIdentifier("mvp.checks.open")
            }
            NavigationLink("Histórico da base") {
                MvpBaseVersionsView(model: viewModel, accountID: accountID)
            }
            .accessibilityIdentifier("mvp.base.versions")
            baseAction(.correctBase, accountID: accountID, base: base, zone: referenceZone)
            if !suspended {
                baseAction(.suspendBase, accountID: accountID, base: base, zone: referenceZone)
            }
        }
    }

    private func baseAction(_ action: MvpAuditInput.Action, accountID: UUID,
                            base: MvpAccountSummary.Base, zone: TimeZone) -> some View {
        NavigationLink {
            MvpAuditView(model: viewModel, accountID: accountID, action: action, base: base,
                         coverageStart: base.coverageStart, zone: zone)
        } label: {
            Text(action.title)
        }
        .accessibilityIdentifier("mvp.audit.open.\(action.rawValue)")
        .disabled(!viewModel.canWrite)
    }

    private var reloadButton: some View {
        Button("Tentar novamente") { Task { await viewModel.load(recover: onOpenIdentity == nil, keepSelection: true) } }
    }

    @ViewBuilder
    private var submissionStatus: some View {
        let isPending = viewModel.hasPendingOpening || viewModel.hasPendingTransaction || viewModel.hasPendingCheck || viewModel.hasPendingRecovery || viewModel.hasPendingAudit
        if isPending || viewModel.message != nil || viewModel.confirmedID != nil {
            Section("Envio") {
                if isPending {
                    if viewModel.busy {
                        ProgressView("Consultando confirmação do envio…")
                    } else {
                        Text(viewModel.message ?? "Envio pendente de confirmação.")
                            .accessibilityIdentifier("mvp.intent.pending")
                        Button("Recuperar envio") { Task { await viewModel.retry() } }
                            .accessibilityIdentifier("mvp.intent.retry")
                    }
                } else if let message = viewModel.message {
                    Text(LocalizedStringKey(message)).accessibilityIdentifier("mvp.account.message")
                }
                if let id = viewModel.confirmedID {
                    VStack(alignment: .leading) {
                        Text("Identificador do lançamento")
                        Text(id.uuidString)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .accessibilityIdentifier("mvp.transaction.confirmedID")
                    }
                }
            }
        }
    }

    private func history(summary: MvpAccountSummary, zone: TimeZone) -> some View {
        Section("Histórico") {
            if viewModel.entries.isEmpty {
                Text("Nenhum lançamento confirmado.")
            }
            ForEach(viewModel.entries) { entry in
                if let base = summary.base, let accountID = summary.account?.id {
                    NavigationLink {
                        MvpMovementAuditView(model: viewModel, entry: entry, accountID: accountID,
                                             coverageStart: base.coverageStart, zone: zone)
                    } label: { historyRow(entry, zone: zone) }
                        .accessibilityIdentifier("mvp.history.entry")
                } else {
                    historyRow(entry, zone: zone).accessibilityIdentifier("mvp.history.entry")
                }
            }
            if viewModel.nextCursor != nil {
                Button("Carregar mais lançamentos") { Task { await viewModel.loadMore() } }
                    .disabled(viewModel.busy)
            }
        }
    }

    private func historyRow(_ entry: MvpHistoryEntry, zone: TimeZone) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let income = entry.type == .income
            Text(income ? "Receita" : "Despesa")
            Text(income
                ? "+\(MvpAccountViewModel.money(entry.amountMinor))"
                : MvpAccountViewModel.money("-\(entry.amountMinor)"))
                .monospacedDigit()
            if let day = entry.occurrenceDay {
                Text("Dia \(day), sem hora informada")
            } else {
                Text(dateLabel(entry.occurredAt, in: zone))
            }
            if let description = entry.description { Text(description) }
            if entry.auditAction == "invalidate" { Text("Invalidado, sem efeito no saldo") }
            if entry.auditAction == "correct" { Text("Corrigido") }
            switch entry.coverage {
            case .covered: EmptyView()
            case .beforeBase: Text("Anterior ao início da cobertura")
            case .afterCut: Text("Posterior ao horário consultado")
            case .noBase: Text("Conta sem base confirmada")
            }
        }
        .accessibilityElement(children: .combine)
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
                } else {
                    Button("Confirmar abertura") { Task { await viewModel.confirm() } }
                        .disabled(!viewModel.canWrite)
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
                    .disabled(!viewModel.canWrite)
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
