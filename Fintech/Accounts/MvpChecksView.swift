import SwiftUI

struct MvpChecksView: View {
    let model: MvpAccountViewModel
    let accountID: UUID
    @State private var pendingOnly = false
    @State private var summary: MvpAccountSummary?
    @State private var entries: [MvpCheckEntry] = []
    @State private var nextAfter: UUID?
    @State private var loading = true
    @State private var error: String?
    @State private var requestID = UUID()

    var body: some View {
        Form {
            Picker("Exibir", selection: $pendingOnly) {
                Text("Todas as conferências").tag(false)
                Text("Somente pendências").tag(true)
            }
            .pickerStyle(.inline)
            .accessibilityIdentifier("mvp.check.filter")

            if let summary {
                Section {
                    MvpCheckAmount("Saldo calculado atual", minor: model.hasPendingBaseChange ? nil : summary.balanceMinor)
                        .accessibilityIdentifier("mvp.check.currentBalance")
                }
                let zone = summary.base.flatMap { TimeZone(identifier: $0.referenceZone) } ?? .current
                ForEach(entries) { entry in
                    Section(title(for: entry)) {
                        MvpCheckValues(
                            reference: entry.receipt.referenceAt, zone: zone, observed: entry.receipt.observedMinor,
                            calculated: entry.receipt.originalCalculatedMinor, difference: entry.receipt.originalDifferenceMinor
                        )
                        MvpCheckAmount("Saldo recalculado no corte", minor: model.hasPendingBaseChange ? nil : entry.calculatedAtReferenceMinor)
                        MvpCheckAmount("Divergência restante no corte", minor: model.hasPendingBaseChange ? nil : entry.remainingDifferenceMinor, showSign: true)
                            .accessibilityIdentifier("mvp.check.remainingDifference")
                        if let reason = entry.replacementReason {
                            Text("Motivo da substituição: \(reason)")
                        }
                        if entry.replacesCheckId != nil {
                            Text("Substitui uma observação anterior")
                            if let author = entry.receipt.authorId { Text("Autor: \(author.uuidString)").font(.footnote) }
                            if let instant = entry.receipt.createdAt {
                                Text(instant, format: .dateTime.day().month().year().hour().minute().second())
                                    .environment(\.timeZone, zone)
                            }
                        }
                        if entry.supersededBy == nil, summary.status == .available, let base = summary.base {
                            NavigationLink {
                                MvpAuditView(model: model, accountID: accountID, action: .replaceCheck, check: entry,
                                             coverageStart: base.coverageStart, zone: zone)
                            } label: { Text("Substituir conferência") }
                                .accessibilityIdentifier("mvp.audit.open.replace_check")
                                .disabled(!model.canWrite)
                        }
                        if entry.canRecover, let base = summary.base {
                            NavigationLink {
                                MvpRecoveryView(model: model, entry: entry, base: base, zone: zone)
                            } label: {
                                Text("Investigar divergência")
                            }
                            .accessibilityIdentifier("mvp.recovery.open")
                            .disabled(!model.canWrite)
                        }
                    }
                }
                if entries.isEmpty && !loading && error == nil {
                    if pendingOnly && (summary.baseSuspended == true || model.hasPendingBaseChange) {
                        Text("Pendências indisponíveis. Consulte os resultados originais em Todas as conferências.")
                    } else {
                        Text(pendingOnly ? "Nenhuma divergência em aberto." : "Nenhuma conferência registrada.")
                    }
                }
                if let nextAfter, !loading {
                    Button("Carregar mais conferências") {
                        Task { await load(pending: pendingOnly, after: nextAfter) }
                    }
                }
            }
            if loading {
                ProgressView("Consultando conferências…")
            } else if let error {
                Section {
                    Text(error)
                    Button("Atualizar conferências") { Task { await load(pending: pendingOnly) } }
                }
            }
        }
        .navigationTitle("Conferências e pendências")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(pendingOnly)-\(model.recoveryReceipt?.id.uuidString ?? "")-\(model.auditReceipt?.id.uuidString ?? "")") { await load(pending: pendingOnly) }
        .refreshable { await load(pending: pendingOnly) }
    }

    private func title(for entry: MvpCheckEntry) -> String {
        if entry.supersededBy != nil { return "Conferência substituída" }
        if model.hasPendingBaseChange { return "Recálculo indisponível" }
        return entry.status.title
    }

    private func load(pending: Bool, after: UUID? = nil) async {
        let currentRequest = UUID()
        requestID = currentRequest
        loading = true
        error = nil
        if after == nil {
            summary = nil
            entries = []
            nextAfter = nil
        }
        defer { if currentRequest == requestID && !Task.isCancelled { loading = false } }
        do {
            let page = try await model.loadChecks(accountID: accountID, pendingOnly: pending,
                                                  after: after, revision: summary?.revision)
            try Task.checkCancellation()
            guard currentRequest == requestID, pending == pendingOnly else { return }
            summary = page.summary
            entries += page.entries
            nextAfter = page.nextAfter
        } catch is CancellationError {
            return
        } catch {
            guard currentRequest == requestID, pending == pendingOnly else { return }
            if case APIError.mvpConflict(code: "STALE_REVISION") = error {
                summary = nil
                entries = []
                nextAfter = nil
                self.error = "As conferências mudaram. Atualize para consultar a revisão atual."
            } else {
                self.error = after == nil
                    ? "Saldo e conferências temporariamente indisponíveis. Tente novamente."
                    : "Não foi possível carregar mais conferências. Os valores exibidos são da última consulta."
            }
        }
    }
}
