import SwiftUI

struct MvpRecoveryView: View {
    let model: MvpAccountViewModel
    let entry: MvpCheckEntry
    let base: MvpAccountSummary.Base
    let zone: TimeZone

    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var day: Date
    @State private var time = ""
    @State private var repeatedInstant: Date?
    @State private var description = ""
    @State private var externalSource = ""
    @State private var externalReference = ""
    @State private var evidence = ""
    @State private var review: Review?
    @State private var selected: Movement?
    @State private var loading = false
    @State private var error: String?
    @State private var showingHistory = false
    @State private var confirmation: MvpRecoveryConfirmation.Action?

    private struct Review {
        let input: MvpRecoveryInput
        let preview: MvpRecoveryPreview
    }

    fileprivate struct Movement: Identifiable {
        let id: UUID
        let amount: String
        let description: String?
        let instant: Date?
        let day: String?

        var title: String { description ?? "Despesa sem descrição" }

        func occurrence(in zone: TimeZone) -> String {
            if let day { return "Dia \(day), sem hora informada" }
            guard let instant else { return "Data indisponível" }
            var format = Date.FormatStyle(date: .abbreviated, time: .standard, locale: Locale(identifier: "pt_BR"))
            format.timeZone = zone
            return "\(instant.formatted(format)) (\(MvpRecoveryTime.offset(instant, in: zone)))"
        }
    }

    init(model: MvpAccountViewModel, entry: MvpCheckEntry, base: MvpAccountSummary.Base, zone: TimeZone) {
        self.model = model
        self.entry = entry
        self.base = base
        self.zone = zone
        _day = State(initialValue: entry.receipt.referenceAt)
    }

    var body: some View {
        Form {
            Section {
                MvpCheckAmount(
                    model.hasPendingRecovery ? "Divergência na última consulta" : "Divergência restante no corte",
                    minor: review?.preview.remainingDifferenceMinor ?? entry.remainingDifferenceMinor, showSign: true
                )
            }
            if model.hasPendingRecovery {
                Section("Envio pendente") {
                    Text(model.message ?? "Aguardando confirmação do envio.")
                    Button("Recuperar envio") { Task { await retry() } }
                        .accessibilityIdentifier("mvp.recovery.retry")
                        .disabled(model.busy)
                }
            } else if let review {
                reviewSections(review)
            } else {
                inputSections
            }
            if let error { Text(error).accessibilityIdentifier("mvp.recovery.error") }
            if loading || model.busy { ProgressView("Consultando recuperação…") }
            if !model.hasPendingRecovery {
                Button("Adiar decisão") { dismiss() }
                    .accessibilityIdentifier("mvp.recovery.defer")
                    .disabled(model.busy)
            }
        }
        .navigationTitle("Investigar divergência")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.timeZone, zone)
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $showingHistory) {
            if let review {
                MvpRecoveryHistory(
                    model: model, accountID: entry.receipt.accountId, revision: review.preview.revision,
                    reference: entry.receipt.referenceAt, zone: zone
                ) { movement in
                    selected = movement
                    showingHistory = false
                }
            }
        }
        .confirmationDialog(
            confirmation == .link ? "Vincular lançamento existente?" : "Registrar despesa distinta?",
            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
            titleVisibility: .visible,
            presenting: confirmation
        ) { action in
            Button(action == .link ? "Confirmar vínculo" : "Confirmar despesa distinta") {
                Task { await confirm(action) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: { action in
            if action == .link, let selected {
                Text("\(selected.title), \(MvpAccountViewModel.money(selected.amount)). O saldo atual permanece igual.")
            } else if let review {
                Text("Uma nova despesa de \(MvpAccountViewModel.money(review.input.amountMinor)) será registrada na sua conta.")
            }
        }
        .onChange(of: error) { _, error in
            if let error { AccessibilityNotification.Announcement(error).post() }
        }
        .onChange(of: model.recoveryReceipt?.id) { _, _ in
            if model.recoveryReceipt?.checkId == entry.id { dismiss() }
        }
    }

    @ViewBuilder
    private var inputSections: some View {
        Section("Despesa a investigar") {
            TextField("Valor em reais", text: $amount)
                .keyboardType(.decimalPad)
                .accessibilityIdentifier("mvp.recovery.amount")
            DatePicker("Dia da despesa", selection: $day, in: base.coverageStart...entry.receipt.referenceAt, displayedComponents: .date)
                .accessibilityIdentifier("mvp.recovery.day")
            TextField("Hora, se conhecida (HH:mm:ss)", text: $time)
                .keyboardType(.numbersAndPunctuation)
                .accessibilityIdentifier("mvp.recovery.time")
                .onChange(of: time) { repeatedInstant = nil }
                .onChange(of: day) { repeatedInstant = nil }
            let instants = MvpRecoveryTime.instants(for: time, on: day, in: zone)
            if instants.count > 1 {
                Picker("A hora ocorreu duas vezes neste dia", selection: $repeatedInstant) {
                    Text("Escolha o fuso da hora").tag(nil as Date?)
                    ForEach(instants, id: \.self) { instant in
                        Text(MvpRecoveryTime.offset(instant, in: zone))
                            .tag(Optional(instant))
                    }
                }
                .pickerStyle(.inline)
            }
            TextField("Descrição, se conhecida", text: $description)
                .accessibilityIdentifier("mvp.recovery.description")
        }
        Section("Referência externa opcional") {
            TextField("Origem (ex. banco-a)", text: $externalSource)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Identificador fornecido pela origem", text: $externalReference)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        Button("Buscar possíveis lançamentos") { Task { await loadPreview() } }
            .disabled(loading)
            .accessibilityIdentifier("mvp.recovery.preview")
    }

    @ViewBuilder
    private func reviewSections(_ review: Review) -> some View {
        Section("Dados informados") {
            MvpCheckAmount("Valor da despesa", minor: review.input.amountMinor)
            if let instant = review.input.occurredAt {
                LabeledContent("Ocorrência", value: Movement(id: entry.id, amount: review.input.amountMinor,
                                                            description: nil, instant: instant, day: nil).occurrence(in: zone))
            } else {
                LabeledContent("Ocorrência", value: "Dia \(review.input.day), sem hora informada")
            }
            if let description = review.input.description {
                LabeledContent("Descrição", value: description)
            }
            if let source = review.input.externalSource, let reference = review.input.externalReference {
                LabeledContent("Referência externa", value: "\(source) · \(reference)")
            }
            if let dateError = dateMessage(review.preview.dateStatus) { Text(dateError) }
            if review.preview.existingRecovery != nil {
                Text("A referência externa já identifica uma recuperação. Confira o lançamento no histórico ou revise a referência.")
            }
            Button("Editar dados informados") {
                self.review = nil
                selected = nil
                error = nil
            }
        }
        Section("Possíveis lançamentos") {
            if review.preview.candidates.isEmpty { Text("Nenhuma sugestão para o valor e o dia informados.") }
            ForEach(review.preview.candidates) { candidate in
                let movement = Movement(id: candidate.id, amount: candidate.amountMinor, description: candidate.description,
                                        instant: candidate.occurredAt, day: candidate.occurrenceDay)
                Button {
                    selected = movement
                } label: {
                    MvpRecoveryMovementRow(movement: movement, zone: zone)
                }
                .disabled(candidate.alreadyLinked)
                .accessibilityIdentifier("mvp.recovery.candidate")
                if candidate.alreadyLinked { Text("Já vinculado a esta conferência") }
            }
            Button("Escolher no histórico") { showingHistory = true }
                .accessibilityIdentifier("mvp.recovery.history")
        }
        Section("Confirmação") {
            if let balance = review.preview.projectedBalanceMinor,
               let remaining = review.preview.projectedRemainingDifferenceMinor {
                MvpCheckAmount("Saldo se registrar nova despesa", minor: balance)
                MvpCheckAmount("Divergência se registrar nova despesa", minor: remaining, showSign: true)
            }
            TextField("Como você identificou a despesa?", text: $evidence, axis: .vertical)
                .lineLimit(2...5)
                .accessibilityIdentifier("mvp.recovery.evidence")
            if let selected {
                LabeledContent("Lançamento escolhido") {
                    MvpRecoveryMovementRow(movement: selected, zone: zone)
                }
                Button("Vincular lançamento") { confirmation = .link }
                    .disabled(!canConfirm)
                    .accessibilityIdentifier("mvp.recovery.link")
            }
            Button("Registrar como despesa distinta") { confirmation = .create }
                .disabled(!canConfirm || review.preview.dateStatus != .eligible || review.preview.existingRecovery != nil)
                .accessibilityIdentifier("mvp.recovery.create")
        }
    }

    private var canConfirm: Bool {
        model.canWrite && !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && evidence.count <= 1000
    }

    private func loadPreview() async {
        guard !loading else { return }
        error = nil
        guard let minor = MvpAccountViewModel.parseMinor(amount), (1...999_999_999).contains(minor) else {
            error = "Informe um valor positivo em reais com até duas casas decimais."
            return
        }
        let clock = time.trimmingCharacters(in: .whitespacesAndNewlines)
        let instants = MvpRecoveryTime.instants(for: clock, on: day, in: zone)
        let instant = instants.count == 1 ? instants.first : repeatedInstant
        guard clock.isEmpty || instant != nil else {
            error = instants.isEmpty ? "Confira a hora informada para esse dia." : "Escolha qual ocorrência da hora você identificou."
            return
        }
        let source = externalSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let reference = externalReference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source.isEmpty == reference.isEmpty else {
            error = "Informe a origem e o identificador externo juntos."
            return
        }
        let input = MvpRecoveryInput(
            accountId: entry.receipt.accountId, checkId: entry.id, amountMinor: String(minor),
            day: MvpRecoveryTime.day(day, in: zone), occurredAt: instant, description: description.isEmpty ? nil : description,
            externalSource: source.isEmpty ? nil : source, externalReference: reference.isEmpty ? nil : reference
        )
        loading = true
        defer { loading = false }
        do {
            let preview = try await model.previewRecovery(input)
            review = Review(input: input, preview: preview)
        } catch is CancellationError {
            return
        } catch APIError.badRequest {
            error = "Confira os dados e, se informada, a origem da referência externa."
        } catch {
            self.error = "Não foi possível consultar possíveis lançamentos. Tente novamente."
        }
    }

    private func confirm(_ action: MvpRecoveryConfirmation.Action) async {
        guard let review, canConfirm else { return }
        error = nil
        let previousReceipt = model.recoveryReceipt?.id
        await model.confirmRecovery(MvpRecoveryConfirmation(
            input: review.input, expectedRevision: review.preview.revision, action: action,
            transactionId: action == .link ? selected?.id : nil, evidence: evidence
        ))
        resetAfterRejection(previousReceipt: previousReceipt)
    }

    private func retry() async {
        let previousReceipt = model.recoveryReceipt?.id
        await model.retry()
        resetAfterRejection(previousReceipt: previousReceipt)
    }

    private func resetAfterRejection(previousReceipt: UUID?) {
        guard !model.hasPendingRecovery, model.recoveryReceipt?.id == previousReceipt else { return }
        error = model.message
        review = nil
        selected = nil
    }

    private func dateMessage(_ status: MvpRecoveryPreview.DateStatus) -> String? {
        switch status {
        case .eligible: nil
        case .timeRequired: "A hora pode mudar a cobertura ou o saldo em uma conferência. Informe a hora ou adie a decisão."
        case .outsideCoverage: "A data informada está fora da cobertura da conta."
        case .afterCheck: "A despesa precisa ter ocorrido até o corte desta conferência."
        }
    }
}

private struct MvpRecoveryMovementRow: View {
    let movement: MvpRecoveryView.Movement
    let zone: TimeZone

    var body: some View {
        VStack(alignment: .leading) {
            Text(movement.title)
            Text(MvpAccountViewModel.money(movement.amount)).monospacedDigit()
            Text(movement.occurrence(in: zone))
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MvpRecoveryHistory: View {
    let model: MvpAccountViewModel
    let accountID: UUID
    let revision: String
    let reference: Date
    let zone: TimeZone
    let select: (MvpRecoveryView.Movement) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [MvpHistoryEntry] = []
    @State private var cursor: String?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(entries) { entry in
                    let movement = MvpRecoveryView.Movement(id: entry.id, amount: entry.amountMinor,
                                                            description: entry.description, instant: entry.occurredAt,
                                                            day: entry.occurrenceDay)
                    Button { select(movement) } label: {
                        MvpRecoveryMovementRow(movement: movement, zone: zone)
                    }
                    .accessibilityIdentifier("mvp.recovery.historyMovement")
                }
                if loading { ProgressView("Consultando histórico…") }
                if let error { Text(error) }
                if !loading && (cursor != nil || error != nil) {
                    Button(error == nil ? "Carregar mais lançamentos" : "Tentar consultar novamente") {
                        Task { await load() }
                    }
                } else if !loading && entries.isEmpty {
                    Text("Nenhuma despesa no histórico para o corte da conferência.")
                }
            }
            .navigationTitle("Histórico de despesas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } }
            }
            .task { await load() }
        }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await model.loadRecoveryHistory(accountID: accountID, cursor: cursor, revision: revision)
            entries += page.entries.filter { $0.type == .expense && $0.auditAction != "invalidate" && $0.coverage == .covered && $0.occurredAt <= reference }
            cursor = page.nextCursor
            error = nil
        } catch is CancellationError {
            return
        } catch APIError.mvpConflict(code: "STALE_REVISION") {
            error = "O histórico mudou. Feche esta tela e busque os lançamentos novamente."
        } catch {
            self.error = "Não foi possível consultar o histórico."
        }
    }
}
