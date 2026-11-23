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

            if let summary, let balance = summary.balanceMinor {
                Section {
                    MvpCheckAmount("Saldo calculado atual", minor: balance)
                        .accessibilityIdentifier("mvp.check.currentBalance")
                }
                let zone = summary.base.flatMap { TimeZone(identifier: $0.referenceZone) } ?? .current
                ForEach(entries) { entry in
                    Section(entry.status == .open ? "Divergência em aberto" : "Valores coincidentes no corte") {
                        MvpCheckValues(
                            reference: entry.receipt.referenceAt, zone: zone, observed: entry.receipt.observedMinor,
                            calculated: entry.receipt.originalCalculatedMinor, difference: entry.receipt.originalDifferenceMinor
                        )
                        MvpCheckAmount("Saldo recalculado no corte", minor: entry.calculatedAtReferenceMinor)
                        MvpCheckAmount("Divergência restante no corte", minor: entry.remainingDifferenceMinor, showSign: true)
                            .accessibilityIdentifier("mvp.check.remainingDifference")
                    }
                }
                if entries.isEmpty && !loading && error == nil {
                    Text(pendingOnly ? "Nenhuma divergência em aberto." : "Nenhuma conferência registrada.")
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
        .task(id: pendingOnly) { await load(pending: pendingOnly) }
        .refreshable { await load(pending: pendingOnly) }
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
