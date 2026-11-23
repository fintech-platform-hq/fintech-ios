import SwiftUI

struct MvpCheckView: View {
    let model: MvpAccountViewModel
    let base: MvpAccountSummary.Base
    @State private var amount = ""
    @State private var reference = Date.now
    @FocusState private var amountFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var zone: TimeZone { TimeZone(identifier: base.referenceZone) ?? .current }

    var body: some View {
        NavigationStack {
            Form {
                if let preview = model.checkPreview {
                    Section("Revise a conferência") {
                        MvpCheckValues(
                            reference: reference, zone: zone, observed: preview.observedMinor,
                            calculated: preview.calculatedMinor, difference: preview.differenceMinor
                        )
                        Button("Confirmar conferência") {
                            Task {
                                await model.confirmCheck()
                                if model.hasPendingCheck || model.checkReceipt != nil { dismiss() }
                            }
                        }
                        .disabled(!model.canWrite)
                        Button("Editar conferência", action: model.editCheck)
                            .disabled(!model.canWrite)
                    }
                } else {
                    Section {
                        TextField("Saldo observado em reais", text: $amount)
                            .keyboardType(.numbersAndPunctuation)
                            .focused($amountFocused)
                            .accessibilityIdentifier("mvp.check.amount")
                        DatePicker(
                            "Data e hora do saldo observado",
                            selection: $reference,
                            in: base.coverageStart...max(base.coverageStart, .now)
                        )
                        .environment(\.timeZone, zone)
                        .environment(\.locale, Locale(identifier: "pt_BR"))
                        Text("Horário de referência da conta: \(base.referenceZone)")
                        Button("Revisar conferência") {
                            amountFocused = false
                            let minute = Date(timeIntervalSince1970: floor(reference.timeIntervalSince1970 / 60) * 60)
                            reference = max(minute, base.coverageStart)
                            Task { await model.reviewCheck(amount: amount, reference: reference) }
                        }
                        .disabled(!model.canWrite)
                    }
                    .disabled(model.busy)
                }
                if model.busy {
                    ProgressView("Consultando conferência…")
                } else if let message = model.message {
                    Text(message).accessibilityIdentifier("mvp.check.message")
                }
            }
            .navigationTitle("Conferir saldo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar") { dismiss() }
                        .disabled(model.busy)
                }
            }
            .interactiveDismissDisabled(model.busy)
        }
    }
}

struct MvpCheckValues: View {
    let reference: Date
    let zone: TimeZone
    let observed: String
    let calculated: String
    let difference: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let dateLabel = reference.formatted(Date.FormatStyle(
                date: .abbreviated, time: .shortened, locale: Locale(identifier: "pt_BR"), timeZone: zone
            ))
            Text(dateLabel)
                .accessibilityLabel("Data e hora da conferência: \(dateLabel)")
                .accessibilityIdentifier("mvp.check.reference")
            MvpCheckAmount("Valor informado", minor: observed)
            MvpCheckAmount("Saldo calculado na conferência", minor: calculated)
            MvpCheckAmount("Divergência original", minor: difference, showSign: true)
                .accessibilityIdentifier("mvp.check.originalDifference")
            if difference != "0" {
                Text(difference.hasPrefix("-") ? "Calculado abaixo do informado." : "Calculado acima do informado.")
            } else {
                Text("Valores coincidentes na conferência.")
            }
        }
    }
}

struct MvpCheckAmount: View {
    let title: String
    let minor: String?
    let showSign: Bool

    init(_ title: String, minor: String?, showSign: Bool = false) {
        self.title = title
        self.minor = minor
        self.showSign = showSign
    }

    var body: some View {
        if let minor {
            amount(minor)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text("Indisponível")
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func amount(_ minor: String) -> some View {
        let negative = minor.hasPrefix("-")
        let magnitude = MvpAccountViewModel.money(negative ? String(minor.dropFirst()) : minor)
        let positive = showSign && minor != "0" && !negative
        let sign = negative ? "−" : positive ? "+" : ""
        let spokenSign = negative ? "menos " : positive ? "mais " : ""
        return VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(sign + magnitude).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(spokenSign + magnitude)
    }
}
