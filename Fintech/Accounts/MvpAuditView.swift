import SwiftUI

struct MvpMovementAuditView: View {
    let model: MvpAccountViewModel
    let entry: MvpHistoryEntry
    let accountID: UUID
    let coverageStart: Date
    let zone: TimeZone
    @State private var versions: [MvpMovementVersion] = []
    @State private var unavailable = false

    var body: some View {
        Form {
            Section("Versões do lançamento") {
                if unavailable {
                    Text("Não foi possível consultar as versões.")
                    Button("Tentar novamente", action: { Task { await load() } })
                } else if versions.isEmpty {
                    ProgressView("Consultando versões…")
                }
                ForEach(versions) { version in
                    VStack(alignment: .leading) {
                        Text(version.title).font(.headline)
                        MvpCheckAmount("Valor", minor: version.amountMinor)
                        if let description = version.description { Text(description) }
                        if let day = version.occurrenceDay {
                            Text("Dia \(day), sem hora informada")
                        } else {
                            Text(version.occurredAt, format: .dateTime.day().month().year().hour().minute().second())
                        }
                        if let reason = version.reason { Text("Motivo: \(reason)") }
                        Text("Autor: \(version.authorId.uuidString)").font(.footnote)
                        Text(version.createdAt, format: .dateTime.day().month().year().hour().minute().second())
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("mvp.audit.version.\(version.action)")
                }
            }
            if entry.auditAction != "invalidate" && versions.last?.action != "invalidate" {
                Section {
                    action(.correct)
                    action(.invalidate)
                }
                .disabled(!model.canWrite)
            }
        }
        .environment(\.timeZone, zone)
        .navigationTitle("Lançamento")
        .task(id: model.auditReceipt?.id) { await load() }
    }

    private func action(_ action: MvpAuditInput.Action) -> some View {
        NavigationLink {
            MvpAuditView(model: model, accountID: accountID, action: action, movement: entry,
                         coverageStart: coverageStart, zone: zone)
        } label: { Text(action.title) }
            .accessibilityIdentifier("mvp.audit.open.\(action.rawValue)")
    }

    private func load() async {
        do {
            versions = try await model.loadMovementVersions(accountID: accountID, movementID: entry.id)
            unavailable = false
        } catch is CancellationError {
            return
        } catch {
            unavailable = true
        }
    }
}

struct MvpAuditView: View {
    let model: MvpAccountViewModel
    let accountID: UUID
    let action: MvpAuditInput.Action
    var movement: MvpHistoryEntry?
    var check: MvpCheckEntry?
    let coverageStart: Date
    let zone: TimeZone

    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var amount = ""
    @State private var description = ""
    @State private var editDescription = false
    @State private var editDate = false
    @State private var date = Date.now
    @State private var confirmation: MvpAuditConfirmation?
    @State private var reviewing = false
    @State private var error: String?

    var body: some View {
        Form {
            if let confirmation {
                Section("Saldo da conta") {
                    MvpCheckAmount("Atual", minor: confirmation.preview.balanceMinor)
                    MvpCheckAmount("Após confirmar", minor: confirmation.preview.projectedBalanceMinor)
                        .accessibilityIdentifier("mvp.audit.projectedBalance")
                }
                ForEach(confirmation.preview.checks) { impact in
                    Section {
                        Text(impact.referenceAt, format: .dateTime.day().month().year().hour().minute())
                        MvpCheckAmount("Divergência original", minor: impact.originalDifferenceMinor, showSign: true)
                        MvpCheckAmount("Resíduo atual", minor: impact.beforeMinor, showSign: true)
                        MvpCheckAmount("Resíduo projetado", minor: impact.afterMinor, showSign: true)
                            .accessibilityIdentifier("mvp.audit.projectedDifference")
                    } header: {
                        Text(action == .replaceCheck ? "Conferência substituta" : "Conferência afetada")
                    }
                }
                Section("Dados a confirmar") {
                    if let amount = confirmation.input.amountMinor ?? confirmation.input.observedMinor {
                        MvpCheckAmount("Novo valor", minor: amount)
                    }
                    if let description = confirmation.input.description {
                        Text(description.isEmpty ? "Remover a descrição" : "Descrição: \(description)")
                    }
                    if let date = confirmation.input.occurredAt.flatMap({ try? Date($0, strategy: .iso8601) }) {
                        Text(date, format: .dateTime.day().month().year().hour().minute().second())
                    }
                    Text("Motivo: \(confirmation.input.reason)")
                }
                Section {
                    Button("Confirmar", role: action == .invalidate ? .destructive : nil) {
                        Task {
                            if await model.confirmAudit(confirmation) { dismiss() }
                            else if !model.hasPendingAudit {
                                error = model.message
                                self.confirmation = nil
                            }
                        }
                    }
                    .accessibilityIdentifier("mvp.audit.confirm")
                    Button("Editar dados") { self.confirmation = nil }
                }
                .disabled(!model.canWrite)
            } else {
                fields
                Button("Revisar impacto") { Task { await review() } }
                    .disabled(reviewing || !model.canWrite)
                    .accessibilityIdentifier("mvp.audit.preview")
            }
            if reviewing { ProgressView("Calculando impacto…") }
            if let error { Text(error).accessibilityIdentifier("mvp.audit.error") }
            if model.hasPendingAudit {
                Section {
                    Text(model.message ?? "Envio pendente de confirmação.")
                        .accessibilityIdentifier("mvp.audit.pending")
                    Button("Recuperar envio") {
                        Task {
                            await model.retry()
                            if !model.hasPendingAudit, model.auditReceipt != nil { dismiss() }
                        }
                    }
                    .disabled(model.busy)
                }
            }
        }
        .environment(\.timeZone, zone)
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle(action.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !editDate { date = check?.receipt.referenceAt ?? movement?.occurredAt ?? .now }
        }
    }

    private var fields: some View {
        Section {
            if let original = movement?.amountMinor ?? check?.receipt.observedMinor {
                MvpCheckAmount("Valor registrado", minor: original)
            }
            if action != .invalidate {
                TextField(action == .replaceCheck ? "Valor informado correto" : "Novo valor (opcional)", text: $amount)
                    .keyboardType(action == .replaceCheck ? .numbersAndPunctuation : .decimalPad)
                    .accessibilityIdentifier("mvp.audit.amount")
                if action == .correct {
                    Toggle("Alterar descrição", isOn: $editDescription)
                    if editDescription { TextField("Nova descrição", text: $description) }
                }
                Toggle(action == .replaceCheck ? "Alterar data e hora do corte" : "Alterar data e hora da ocorrência",
                       isOn: $editDate)
                if editDate {
                    DatePicker("Data e hora", selection: $date, in: coverageStart...max(coverageStart, .now))
                }
            }
            TextField("Motivo", text: $reason, axis: .vertical)
                .accessibilityIdentifier("mvp.audit.reason")
        }
    }

    private func review() async {
        error = nil
        let note = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty, let target = movement?.id ?? check?.id else {
            error = "Informe o motivo da alteração."
            return
        }
        let parsed = MvpAccountViewModel.parseMinor(amount)
        if (action == .replaceCheck || !amount.isEmpty) && parsed == nil {
            error = "Informe um valor com até duas casas decimais."
            return
        }
        if action == .correct, let parsed, !(1...999_999_999).contains(parsed) {
            error = "O lançamento deve ter valor positivo dentro do limite."
            return
        }
        var input = MvpAuditInput(accountId: accountID, targetId: target, action: action, reason: note)
        let time = editDate ? date.ISO8601Format() : nil
        switch action {
        case .correct:
            input.amountMinor = parsed.map(String.init)
            input.description = editDescription ? description : nil
            input.occurredAt = time
        case .invalidate: break
        case .replaceCheck:
            input.observedMinor = parsed.map(String.init)
            input.referenceAt = time ?? check?.receipt.referenceInstant
        }
        reviewing = true
        defer { reviewing = false }
        do {
            let preview = try await model.previewAudit(input)
            confirmation = MvpAuditConfirmation(input: input, preview: preview)
        } catch is CancellationError {
            return
        } catch APIError.mvpConflict(code: "OCCURRENCE_TIME_REQUIRED") {
            error = "Um lançamento informado só por dia torna esse corte ambíguo. Escolha outro horário."
        } catch {
            self.error = "Não foi possível gerar a prévia. Confira os dados e atualize a conta."
        }
    }
}
