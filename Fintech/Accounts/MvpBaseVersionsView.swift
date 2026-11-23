import SwiftUI

nonisolated struct MvpBaseVersion: Decodable, Identifiable, Sendable {
    let id: UUID
    let accountId: UUID
    let authorId: UUID
    let revision: String
    let action: String
    let baseMinor: String
    let coverageStart: Date
    let referenceZone: String
    let reason: String?
    let createdAt: Date

    var title: String {
        switch action {
        case "suspend_base": "Suspensão das cifras"
        case "correct_base": "Base corrigida"
        default: "Base original"
        }
    }
}

struct MvpBaseVersionsView: View {
    let model: MvpAccountViewModel
    let accountID: UUID
    @State private var versions: [MvpBaseVersion] = []
    @State private var failed = false

    var body: some View {
        Form {
            if failed {
                Text("Não foi possível consultar o histórico da base.")
                Button("Tentar novamente") { Task { await load() } }
            } else if versions.isEmpty {
                ProgressView("Consultando histórico da base…")
            }
            ForEach(versions) { version in
                Section {
                    MvpCheckAmount("Base registrada", minor: version.baseMinor)
                        .accessibilityIdentifier("mvp.base.version.amount.\(version.action)")
                    LabeledContent("Início da cobertura", value: dateLabel(version.coverageStart, zone: version.referenceZone))
                    LabeledContent("Registrado em", value: dateLabel(version.createdAt, zone: version.referenceZone))
                    if let reason = version.reason { LabeledContent("Motivo", value: reason) }
                    LabeledContent("Revisão", value: version.revision)
                    LabeledContent("Autor", value: version.authorId.uuidString)
                } header: {
                    Text(version.title)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("mvp.base.version.\(version.action)")
                }
            }
        }
        .navigationTitle("Histórico da base")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func dateLabel(_ date: Date, zone: String) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .standard, locale: Locale(identifier: "pt_BR"),
                                        timeZone: TimeZone(identifier: zone) ?? .current)) + " (" + zone + ")"
    }

    private func load() async {
        do {
            versions = try await model.loadBaseVersions(accountID: accountID)
            failed = false
        } catch is CancellationError {
            return
        } catch {
            failed = true
        }
    }
}
