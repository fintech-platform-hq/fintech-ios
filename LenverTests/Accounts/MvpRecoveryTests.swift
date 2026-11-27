import Foundation
import Synchronization
import Testing
@testable import Lenver

@MainActor
struct MvpRecoveryTests {
    @Test(arguments: [URLError.Code.timedOut, .notConnectedToInternet])
    func relaunchRecoversFrozenTransactionWithoutReplayingAsAnotherUser(failure: URLError.Code) async throws {
        let fixture = RecoveryFixture()
        defer { fixture.cleanUp() }
        fixture.install(firstFailure: failure)
        let a = try await fixture.model(token: "a")
        await a.load()
        let form = try #require(openForm(a))
        await form.submit()
        #expect(a.hasPendingTransaction)
        #expect(a.confirmedID == nil)
        #expect(fixture.posts.withLock { $0.count } == 1)

        let b = try await fixture.model(token: "b")
        await b.load(recover: true)
        #expect(!b.hasPendingTransaction)
        #expect(b.confirmedID == nil)
        #expect(fixture.posts.withLock { $0.count } == 1)

        let reopened = try await fixture.model(token: "a")
        await reopened.load(recover: true)
        #expect(!reopened.hasPendingTransaction)
        #expect(reopened.confirmedID == RecoveryFixture.transactionID)
        #expect(reopened.entries.map(\.id) == [RecoveryFixture.transactionID])
        let posts = fixture.posts.withLock { $0 }
        try #require(posts.count == 2)
        #expect(posts[0].httpBody == posts[1].httpBody)
        #expect(posts[0].value(forHTTPHeaderField: "Idempotency-Key") == posts[1].value(forHTTPHeaderField: "Idempotency-Key"))
        #expect(posts.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer a" })

        let body = try #require(posts[0].httpBody)
        let fields = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(fields["expectedRevision"] as? String == "1")
        #expect(fields["amountMinor"] as? Int == 5500)
        #expect((fields["accountId"] as? String).flatMap(UUID.init(uuidString:)) == RecoveryFixture.accountID)
    }

    @Test(arguments: [false, true])
    func replaysTheOriginalCheckOnlyForItsPrincipal(expireSession: Bool) async throws {
        let fixture = RecoveryFixture()
        defer { fixture.cleanUp() }
        fixture.install(
            firstFailure: expireSession ? nil : .timedOut, expireFirstSession: expireSession, checkingBalance: true
        )
        let a = try await fixture.model(token: "a")
        await a.load()
        await a.reviewCheck(amount: "800,00", reference: Date(timeIntervalSince1970: 1_795_428_000))
        #expect(a.checkPreview?.differenceMinor == "10000")
        await a.confirmCheck()
        #expect(a.hasPendingCheck)
        #expect(a.checkReceipt == nil)
        #expect(!a.canWrite)

        let b = try await fixture.model(token: "b")
        await b.load(recover: true)
        #expect(!b.hasPendingCheck)
        #expect(b.checkReceipt == nil)
        #expect(fixture.posts.withLock { $0.count } == 1)

        let reopened = try await fixture.model(token: "a")
        await reopened.load(recover: true)
        #expect(!reopened.hasPendingCheck)
        #expect(reopened.checkReceipt?.originalDifferenceMinor == "10000")
        #expect(reopened.entries.isEmpty)
        let posts = fixture.posts.withLock { $0 }
        try #require(posts.count == 2)
        #expect(posts[0].httpBody == posts[1].httpBody)
        #expect(posts[0].value(forHTTPHeaderField: "Idempotency-Key") == posts[1].value(forHTTPHeaderField: "Idempotency-Key"))
        #expect(posts.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer a" })
        let body = try #require(posts[0].httpBody)
        let fields = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(fields["expectedRevision"] as? String == "1")
        #expect(fields["observedMinor"] as? String == "80000")
        #expect(fields["referenceAt"] as? String == "2026-11-22T12:00:00.123456Z")
    }

    @Test
    func checkPreviewIsReplacedAfterStaleConfirmation() async throws {
        let fixture = RecoveryFixture()
        defer { fixture.cleanUp() }
        fixture.install(checkingBalance: true, rejectFirstCheck: true)
        let model = try await fixture.model(token: "a")
        await model.load()
        let reference = Date(timeIntervalSince1970: 1_795_428_000)
        await model.reviewCheck(amount: "800,00", reference: reference)
        await model.confirmCheck()
        #expect(model.checkPreview == nil)
        #expect(model.checkReceipt == nil)
        #expect(!model.hasPendingCheck)
        #expect(model.canWrite)
        #expect(model.message?.contains("Revise novamente") == true)
        await model.reviewCheck(amount: "800,00", reference: reference)
        await model.confirmCheck()
        let posts = fixture.posts.withLock { $0 }
        try #require(posts.count == 2)
        #expect(posts[0].value(forHTTPHeaderField: "Idempotency-Key") != posts[1].value(forHTTPHeaderField: "Idempotency-Key"))
        #expect(model.checkReceipt?.originalDifferenceMinor == "10000")
    }

    @Test
    func protectedWriteFailureDoesNotStartNetwork() async throws {
        let fixture = RecoveryFixture()
        defer { fixture.cleanUp() }
        fixture.install()
        let model = try await fixture.model(token: "a")
        await model.load()
        let form = try #require(openForm(model))
        try Data([1]).write(to: fixture.root)
        await form.submit()
        #expect(fixture.posts.withLock { $0.isEmpty })
        #expect(model.confirmedID == nil)
        #expect(!model.hasPendingTransaction)
        guard case .failure(.requestRejected) = form.state else {
            Issue.record("Expected an explicit local storage failure")
            return
        }
    }

    @Test
    func expiredSessionKeepsIntentUntilSamePrincipalSignsInAgain() async throws {
        let fixture = RecoveryFixture()
        defer { fixture.cleanUp() }
        fixture.install(expireFirstSession: true)
        let session = fixture.session(token: "a")
        let original = try await fixture.model(token: "a", session: session)
        await original.load()
        let form = try #require(openForm(original))
        await form.submit()
        let generation = await session.currentGeneration()
        #expect(!(await session.hasActiveSession(generation: generation)))
        #expect(original.hasPendingTransaction)
        #expect(original.confirmedID == nil)
        await original.retry()
        #expect(fixture.posts.withLock { $0.count } == 1)

        let reopened = try await fixture.model(token: "a")
        await reopened.load(recover: true)
        #expect(reopened.confirmedID == RecoveryFixture.transactionID)
        #expect(fixture.posts.withLock { $0.count } == 2)
    }

    @Test
    func storeReopensWithProtectionAndSeparatesEnvironmentAndPrincipal() async throws {
        let fixture = RecoveryFixture()
        defer { fixture.cleanUp() }
        let a = RecoveryFixture.accountID
        let b = UUID()
        let intent = MvpIntent(
            environment: fixture.baseURL.absoluteString, principalID: a, accountID: a,
            operation: .transaction, key: UUID(), body: Data("fictitious".utf8)
        )
        try await MvpIntentStore(root: fixture.root).save(intent)
        let reopened = MvpIntentStore(root: fixture.root)
        #expect(try await reopened.load(environment: intent.environment, principalID: a) == intent)
        #expect(try await reopened.load(environment: intent.environment, principalID: b) == nil)
        #expect(try await reopened.load(environment: "https://other.unit.test", principalID: a) == nil)

        let file = try #require(FileManager.default.contentsOfDirectory(
            at: fixture.root, includingPropertiesForKeys: nil
        ).first)
        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
#if !targetEnvironment(simulator)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let protection = attributes[.protectionKey]
        #expect((protection as? FileProtectionType)?.rawValue == FileProtectionType.complete.rawValue ||
                (protection as? String) == FileProtectionType.complete.rawValue)
#endif

        try await reopened.remove(intent)
        #expect(try await reopened.load(environment: intent.environment, principalID: a) == nil)
    }

    @Test(arguments: [false, true])
    func expenseRecoveryResumesOnlyForTheSamePrincipal(expireSession: Bool) async throws {
        let fixture = RecoveryFixture()
        defer { fixture.cleanUp() }
        fixture.install(firstFailure: expireSession ? nil : .timedOut, expireFirstSession: expireSession, recoveringExpense: true)
        let a = try await fixture.model(token: "a")
        await a.load()
        let confirmation = expenseConfirmation()
        await a.confirmRecovery(confirmation)
        #expect(a.hasPendingRecovery)
        #expect(a.recoveryReceipt == nil)
        #expect(!a.canWrite)

        let b = try await fixture.model(token: "b")
        await b.load(recover: true)
        #expect(!b.hasPendingRecovery)
        #expect(b.recoveryReceipt == nil)
        #expect(fixture.posts.withLock { $0.count } == 1)

        let restarted = try await fixture.model(token: "a")
        await restarted.load(recover: true)
        #expect(!restarted.hasPendingRecovery)
        #expect(restarted.recoveryReceipt?.checkId == RecoveryFixture.checkID)
        let posts = fixture.posts.withLock { $0 }
        try #require(posts.count == 2)
        #expect(posts[0].httpBody == posts[1].httpBody)
        #expect(posts[0].value(forHTTPHeaderField: "Idempotency-Key") == posts[1].value(forHTTPHeaderField: "Idempotency-Key"))
        #expect(posts.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer a" })
        let bytes = try #require(posts[0].httpBody)
        let fields = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(fields["occurredAt"] == nil)
        #expect(fields["day"] as? String == "2026-11-15")
        #expect(fields["action"] as? String == "create")
        #expect(fields["expectedRevision"] as? String == "1")
    }

    @Test
    func storageFailurePreventsTransmissionAndRestartRecoversUnsentIntent() async throws {
        let fixture = RecoveryFixture()
        defer { fixture.cleanUp() }
        fixture.install(recoveringExpense: true)
        let a = try await fixture.model(token: "a")
        await a.load()
        let confirmation = expenseConfirmation()
        try Data("fictitious blocked directory".utf8).write(to: fixture.root)
        await a.confirmRecovery(confirmation)
        #expect(fixture.posts.withLock { $0.isEmpty })
        #expect(a.message?.contains("Nenhum envio foi iniciado") == true)
        try FileManager.default.removeItem(at: fixture.root)

        let intent = MvpIntent(
            environment: fixture.baseURL.absoluteString, principalID: RecoveryFixture.principalA,
            accountID: RecoveryFixture.accountID, operation: .recovery, key: UUID(),
            body: try APIClient.freeze(confirmation)
        )
        try await MvpIntentStore(root: fixture.root).save(intent)
        #expect(fixture.posts.withLock { $0.isEmpty })
        let b = try await fixture.model(token: "b")
        await b.load(recover: true)
        #expect(!b.hasPendingRecovery)
        #expect(fixture.posts.withLock { $0.isEmpty })

        let restarted = try await fixture.model(token: "a")
        await restarted.load(recover: true)
        #expect(restarted.recoveryReceipt?.checkId == RecoveryFixture.checkID)
        let posts = fixture.posts.withLock { $0 }
        try #require(posts.count == 1)
        #expect(posts[0].httpBody == intent.body)
        #expect(posts[0].value(forHTTPHeaderField: "Idempotency-Key") == intent.key.uuidString)
    }

    @Test
    func civilDayAndRepeatedClockUseAccountZone() throws {
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        let formatter = ISO8601DateFormatter()
        let spring = try #require(formatter.date(from: "2026-03-08T12:00:00Z"))
        let fall = try #require(formatter.date(from: "2026-11-01T12:00:00Z"))
        #expect(MvpRecoveryTime.day(spring, in: zone) == "2026-03-08")
        #expect(MvpRecoveryTime.instants(for: "02:30", on: spring, in: zone).isEmpty)
        let repeated = MvpRecoveryTime.instants(for: "01:30:00", on: fall, in: zone)
        #expect(repeated.map { formatter.string(from: $0) } == ["2026-11-01T05:30:00Z", "2026-11-01T06:30:00Z"])
        #expect(repeated.map { MvpRecoveryTime.offset($0, in: zone) } == ["UTC−04:00", "UTC−05:00"])
        #expect(MvpRecoveryTime.instants(for: "01:60", on: fall, in: zone).isEmpty)
    }

    private func expenseConfirmation() -> MvpRecoveryConfirmation {
        MvpRecoveryConfirmation(
            input: MvpRecoveryInput(accountId: RecoveryFixture.accountID, checkId: RecoveryFixture.checkID,
                                    amountMinor: "2500", day: "2026-11-15", occurredAt: nil,
                                    description: "Padaria", externalSource: nil, externalReference: nil),
            expectedRevision: "1", action: .create, transactionId: nil, evidence: "Comprovante"
        )
    }

    private func openForm(_ model: MvpAccountViewModel) -> CreateTransactionViewModel? {
        model.startTransaction()
        model.transactionForm?.updateAmountDigits("5500")
        return model.transactionForm
    }
}

private nonisolated final class RecoveryFixture: Sendable {
    static let accountID = UUID(uuidString: "f10f00d2-1f56-4df2-9954-a265950ee2c2")!
    static let checkID = UUID(uuidString: "8b5e65d2-2c95-45fb-81f0-3f63dd778a10")!
    static let transactionID = UUID(uuidString: "d1b67397-a4f5-4338-b733-93f8f214e6a6")!
    static let principalA = UUID(uuidString: "00c7b06c-a57b-491d-8f50-3b6574dfbe76")!
    static let principalB = UUID(uuidString: "46c46c22-e57c-45de-9d86-64ca17c5fdad")!

    let baseURL = URL(string: "https://\(UUID().uuidString.lowercased()).unit.test")!
    let root = URL.temporaryDirectory.appending(path: "mvp-\(UUID().uuidString)")
    let posts = Mutex<[URLRequest]>([])
    let completed = Mutex(false)

    func install(
        firstFailure: URLError.Code? = nil, expireFirstSession: Bool = false,
        checkingBalance: Bool = false, rejectFirstCheck: Bool = false, recoveringExpense: Bool = false
    ) {
        let writePath = recoveringExpense ? "/mvp/recoveries" : (checkingBalance ? "/mvp/checks" : "/mvp/transactions")
        URLProtocolStub.install(for: baseURL) { request in
            let url = try #require(request.url)
            if url.path == writePath {
                let count = self.posts.withLock { $0.append(request); return $0.count }
                if count == 1 {
                    if let firstFailure { return .failure(URLError(firstFailure)) }
                    if expireFirstSession { return try self.response(url, status: 401, json: "{}") }
                    if rejectFirstCheck {
                        return try self.response(url, status: 409, json: #"{"code":"STALE_REVISION"}"#)
                    }
                }
                self.completed.withLock { $0 = true }
                let receipt = recoveringExpense ? """
                    {"id":"\(Self.transactionID)","accountId":"\(Self.accountID)","checkId":"\(Self.checkID)",
                    "transactionId":"\(Self.transactionID)"}
                    """ : (checkingBalance ? Self.checkReceipt : Self.receipt)
                return try self.response(url, status: 201, json: receipt)
            }
            if url.path == "/mvp/check-previews" {
                let revision = rejectFirstCheck && self.posts.withLock({ !$0.isEmpty }) ? "2" : "1"
                return try self.response(url, status: 200, json: """
                    {"accountId":"\(Self.accountID)","observedMinor":"80000","revision":"\(revision)",
                    "referenceAt":"2026-11-22T12:00:00.123456Z","calculatedMinor":"90000","differenceMinor":"10000"}
                    """)
            }
            if url.path == "/auth/refresh" { return try self.response(url, status: 401, json: "{}") }

            let isA = request.value(forHTTPHeaderField: "Authorization") == "Bearer a"
            let confirmed = self.completed.withLock { $0 }
            let summary = Self.summary(isA: isA, confirmed: confirmed, checkingBalance: checkingBalance)
            if url.path.hasSuffix("/history") {
                let entries = confirmed && !checkingBalance ? "[\(Self.historyEntry)]" : "[]"
                return try self.response(url, status: 200, json: """
                    {"summary":\(summary),"entries":\(entries),"nextCursor":null}
                    """)
            }
            return try self.response(url, status: 200, json: summary)
        }
    }

    func cleanUp() {
        URLProtocolStub.reset(for: baseURL)
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    func model(token: String, session: AuthenticationSession? = nil) async throws -> MvpAccountViewModel {
        let session = session ?? self.session(token: token)
        _ = try await session.restore()
        let apiClient = APIClient(baseURL: baseURL, session: transport(), authenticationSession: session)
        return MvpAccountViewModel(service: MvpAccountService(apiClient: apiClient), session: session,
                                   store: MvpIntentStore(root: root))
    }

    func session(token: String) -> AuthenticationSession {
        AuthenticationSession(
            service: AuthenticationService(apiClient: APIClient(baseURL: baseURL, session: transport())),
            credentialStore: RecoveryCredentials(token: token)
        )
    }

    private func transport() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private func response(_ url: URL, status: Int, json: String) throws -> URLProtocolStub.Behavior {
        .response(try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)),
                  Data(json.utf8))
    }

    private static func summary(isA: Bool, confirmed: Bool, checkingBalance: Bool) -> String {
        let asOf = "2026-11-23T12:00:00.000000Z"
        if isA {
            return """
            {"principalId":"\(principalA)","account":{"id":"\(accountID)","name":"Fictícia"},
            "legacyAccounts":[],"status":"available","base":{"baseMinor":"90000",
            "coverageStart":"2026-11-01T12:00:00.000000Z","referenceZone":"UTC"},
            "balanceMinor":"\(confirmed && !checkingBalance ? "84500" : "90000")","revision":"\(confirmed ? "2" : "1")","asOf":"\(asOf)"}
            """
        }
        return """
        {"principalId":"\(principalB)","account":null,"legacyAccounts":[],"status":"no_account",
        "base":null,"balanceMinor":null,"revision":null,"asOf":"\(asOf)"}
        """
    }

    private static let checkReceipt = """
        {"id":"\(transactionID)","accountId":"\(accountID)","observedMinor":"80000",
        "referenceAt":"2026-11-22T12:00:00.123456Z","originalCalculatedMinor":"90000","originalDifferenceMinor":"10000"}
        """
    private static let receipt = """
        {"id":"\(transactionID)","accountId":"\(accountID)","type":"expense","amountMinor":"5500","currency":"BRL",
        "occurredAt":"2026-11-22T12:00:00.000000Z","createdAt":"2026-11-23T12:00:00.000000Z"}
        """
    private static let historyEntry = """
        {"id":"\(transactionID)","type":"expense","amountMinor":"5500","coverage":"covered",
        "occurredAt":"2026-11-22T12:00:00.000000Z"}
        """
}

private actor RecoveryCredentials: CredentialStoring {
    let token: String

    init(token: String) { self.token = token }

    func load() async throws -> AuthTokens? {
        AuthTokens(accessToken: token, refreshToken: "fake-refresh", tokenType: "Bearer", expiresIn: 900)
    }
    func save(_ tokens: AuthTokens) async throws {}
    func delete() async throws {}
}
