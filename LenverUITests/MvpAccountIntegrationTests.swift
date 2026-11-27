import XCTest

final class MvpAccountIntegrationTests: XCTestCase {
    @MainActor
    func testI1BRegistersAndRecoversCommittedSendAcrossRelaunchOverHTTPS() async throws {
        guard ProcessInfo.processInfo.environment["FINTECH_I1B_HTTPS_TEST"] == "1" else {
            throw XCTSkip("Requires the disposable I1-B HTTPS API and response-loss fixture.")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        let baseURL = "https://localhost:55443"
        app.launchArguments = ["-staging", "-mvp-account"]
        app.launchEnvironment["LENVER_STAGING_API_BASE_URL"] = baseURL
        app.launch()
        if app.buttons["Sair"].waitForExistence(timeout: 2) { tap(app.buttons["Sair"]) }
        signIn(app, email: "i1b-a@example.test", password: "i1b disposable password")
        tap(app.buttons["Abrir conta pessoal em reais"])
        let base = app.textFields["mvp.account.openingAmount"]
        tap(base)
        base.typeText("900,00")
        tap(app.buttons["Revisar abertura"])
        tap(app.buttons["Confirmar abertura"])

        let balance = app.staticTexts["mvp.account.balance"]
        waitForLabel(balance, "R$ 900,00")
        let standardBalanceHeight = balance.frame.height
        register(app, amountDigits: "5500", description: "FICTITIOUS-I1B-EXPENSE")
        waitForLabel(balance, "R$ 845,00")
        let confirmed = app.staticTexts["mvp.transaction.confirmedID"]
        show(app, confirmed)
        let expenseID = try XCTUnwrap(UUID(uuidString: confirmed.label))
        attachScreen(app, named: "Despesa confirmada")

        register(app, amountDigits: "1000", description: "FICTITIOUS-I1B-RECOVERY", income: true)
        let pending = app.staticTexts["mvp.intent.pending"]
        show(app, pending)
        XCTAssertTrue(app.buttons["mvp.intent.retry"].exists)
        XCTAssertFalse(confirmed.exists)
        attachScreen(app, named: "Confirmação pendente")

        app.terminate()
        app.launch()
        show(app, pending)
        XCTAssertTrue(app.buttons["mvp.intent.retry"].exists)
        XCTAssertFalse(confirmed.exists)
        tap(app.buttons["Sair"])
        XCTAssertTrue(pending.waitForNonExistence(timeout: 10))
        XCTAssertFalse(balance.exists)
        signIn(app, email: "i1b-b@example.test", password: "i1b disposable password")
        tap(app.buttons["Conta antiga fictícia"])
        let noBase = app.staticTexts["Saldo indisponível. Esta conta ainda não tem uma base confirmada."]
        XCTAssertTrue(noBase.waitForExistence(timeout: 10))
        XCTAssertFalse(pending.exists)
        XCTAssertFalse(balance.exists)
        XCTAssertFalse(confirmed.exists)
        tap(app.buttons["Sair"])

        var request = URLRequest(url: try XCTUnwrap(URL(string: baseURL + "/__i1b/resume")))
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)

        signIn(app, email: "i1b-a@example.test", password: "i1b disposable password")
        waitForLabel(balance, "R$ 855,00")
        show(app, confirmed)
        let recoveredID = try XCTUnwrap(UUID(uuidString: confirmed.label))
        XCTAssertNotEqual(expenseID, recoveredID)
        XCTAssertFalse(pending.exists)
        attachScreen(app, named: "Recuperação confirmada após novo login")

        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        waitForLabel(balance, "R$ 855,00")
        XCTAssertGreaterThan(balance.frame.height, standardBalanceHeight)
        let entries = app.descendants(matching: .any).matching(identifier: "mvp.history.entry")
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(entries.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(entries.count, 2)
        let labels = entries.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(labels.contains { $0.contains("Receita") && $0.contains("+R$ 10,00") && $0.contains("FICTITIOUS-I1B-RECOVERY") })
        XCTAssertTrue(labels.contains { $0.contains("Despesa") && $0.contains("-R$ 55,00") && $0.contains("FICTITIOUS-I1B-EXPENSE") })
        try app.performAccessibilityAudit(for: [.dynamicType, .sufficientElementDescription])
        attachScreen(app, named: "Histórico em Dynamic Type máximo")
        tap(app.buttons["Sair"])
    }

    @MainActor
    func testI2ChecksAndContinuesAfterInterruptedSendsOverHTTPS() async throws {
        guard ProcessInfo.processInfo.environment["FINTECH_I2_HTTPS_TEST"] == "1" else {
            throw XCTSkip("Requires the disposable I2 HTTPS fixture.")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        let baseURL = "https://localhost:55445"
        app.launchArguments = ["-staging", "-mvp-account"]
        app.launchEnvironment["LENVER_STAGING_API_BASE_URL"] = baseURL

        func fixture(_ action: String) async throws {
            var request = URLRequest(url: try XCTUnwrap(URL(string: baseURL + "/__i2/" + action)))
            request.httpMethod = "POST"
            let (_, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
        }

        app.launch()
        if app.buttons["Sair"].waitForExistence(timeout: 2) { tap(app.buttons["Sair"]) }
        signIn(app, email: "i2-a@example.test", password: "fictional i2 password")
        let balance = app.staticTexts["mvp.account.balance"]
        waitForLabel(balance, "R$ 845,00")
        let standardBalanceHeight = balance.frame.height
        let startCheck = app.buttons["Conferir saldo"]
        show(app, startCheck)
        tap(startCheck)
        let observed = app.textFields["mvp.check.amount"]
        tap(observed)
        observed.typeText("800,00")
        let preview = app.buttons["Revisar conferência"]
        tap(preview)
        let previewError = app.staticTexts["mvp.check.message"]
        XCTAssertTrue(previewError.waitForExistence(timeout: 10))
        XCTAssertTrue(previewError.label.contains("Tente novamente"))
        XCTAssertEqual(observed.value as? String, "800,00")
        tap(preview)
        let confirm = app.buttons["Confirmar conferência"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        let original = app.descendants(matching: .any)["mvp.check.originalDifference"]
        XCTAssertEqual(original.label, "Divergência original")
        XCTAssertEqual(original.value as? String, "mais R$ 45,00")
        XCTAssertTrue(app.staticTexts["mvp.check.reference"].exists)
        attachScreen(app, named: "Prévia do saldo observado e da diferença assinada")
        tap(confirm)
        let pending = app.staticTexts["mvp.intent.pending"]
        show(app, pending)
        XCTAssertTrue(app.buttons["mvp.intent.retry"].exists)
        attachScreen(app, named: "Resultado da conferência incerto após interrupção HTTPS")

        try await fixture("expire")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.textFields["Email"].waitForExistence(timeout: 20))
        XCTAssertFalse(pending.exists)
        XCTAssertFalse(balance.exists)
        signIn(app, email: "i2-b@example.test", password: "fictional i2 password")
        XCTAssertTrue(app.buttons["Abrir conta pessoal em reais"].waitForExistence(timeout: 10))
        XCTAssertFalse(pending.exists)
        XCTAssertFalse(balance.exists)
        XCTAssertFalse(original.exists)
        tap(app.buttons["Sair"])

        try await fixture("release-check")
        signIn(app, email: "i2-a@example.test", password: "fictional i2 password")
        waitForLabel(balance, "R$ 845,00")
        show(app, original)
        XCTAssertEqual(original.value as? String, "mais R$ 45,00")
        XCTAssertFalse(pending.exists)
        attachScreen(app, named: "Conferência recuperada com ação para registrar lançamento")

        register(app, amountDigits: "1800", description: "FICTITIOUS-I2-COFFEE")
        show(app, pending)
        XCTAssertFalse(app.staticTexts["mvp.transaction.confirmedID"].exists)
        app.terminate()
        try await fixture("release-coffee")
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        waitForLabel(balance, "R$ 827,00")
        XCTAssertGreaterThan(balance.frame.height, standardBalanceHeight)
        XCTAssertFalse(pending.exists)
        try await fixture("fail-list")
        let openChecks = app.descendants(matching: .any).matching(identifier: "mvp.checks.open").firstMatch
        show(app, openChecks)
        tap(openChecks)
        let retryList = app.buttons["Atualizar conferências"]
        show(app, retryList)
        let current = app.descendants(matching: .any)["mvp.check.currentBalance"]
        XCTAssertFalse(current.exists)
        XCTAssertFalse(original.exists)
        tap(retryList)
        show(app, current)
        XCTAssertEqual(current.label, "Saldo calculado atual")
        XCTAssertEqual(current.value as? String, "R$ 827,00")
        attachScreen(app, named: "Saldo calculado atual em Dynamic Type máximo")
        try app.performAccessibilityAudit(for: [.dynamicType, .sufficientElementDescription])
        show(app, original)
        XCTAssertEqual(original.value as? String, "mais R$ 45,00")
        XCTAssertTrue(app.staticTexts["mvp.check.reference"].exists)
        let remaining = app.descendants(matching: .any)["mvp.check.remainingDifference"]
        show(app, remaining)
        XCTAssertEqual(remaining.value as? String, "mais R$ 45,00")
        try app.performAccessibilityAudit(for: [.dynamicType, .sufficientElementDescription])
        attachScreen(app, named: "Saldo atual e pendência histórica com Dynamic Type máximo")
        tap(app.navigationBars.firstMatch.buttons.firstMatch)
        let coffeeID = app.staticTexts["mvp.transaction.confirmedID"]
        show(app, coffeeID)
        XCTAssertNotNil(UUID(uuidString: coffeeID.label))
    }

    @MainActor
    func testI3ReviewsLinksDefersAndRecoversConfirmedExpenseOverHTTPS() async throws {
        guard ProcessInfo.processInfo.environment["FINTECH_I3_HTTPS_TEST"] == "1" else {
            throw XCTSkip("Requires the disposable I3 HTTPS fixture.")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        let baseURL = "https://localhost:55448"
        app.launchArguments = ["-staging", "-mvp-account"]
        app.launchEnvironment["LENVER_STAGING_API_BASE_URL"] = baseURL
        app.launch()
        if app.buttons["Sair"].waitForExistence(timeout: 2) { tap(app.buttons["Sair"]) }
        signIn(app, email: "i3-a@example.test", password: "fictional i3 password")

        let balance = app.staticTexts["mvp.account.balance"]
        waitForLabel(balance, "R$ 827,00")
        let standardBalanceHeight = balance.frame.height
        let checks = app.descendants(matching: .any).matching(identifier: "mvp.checks.open").firstMatch
        show(app, checks)
        tap(checks)

        openRecovery(app)
        enterRecovery(app, amount: "55,00", time: "")
        let error = app.staticTexts["mvp.recovery.error"]
        show(app, error)
        XCTAssertTrue(error.label.contains("Tente novamente"))
        let preview = app.buttons["mvp.recovery.preview"]
        show(app, preview)
        tap(preview)
        let candidate = app.buttons.matching(identifier: "mvp.recovery.candidate").firstMatch
        show(app, candidate)
        XCTAssertTrue(candidate.label.contains("Despesa anterior"))
        let deferAction = app.buttons["mvp.recovery.defer"]
        show(app, deferAction)
        tap(deferAction)
        let current = app.descendants(matching: .any)["mvp.check.currentBalance"]
        show(app, current)
        XCTAssertEqual(current.value as? String, "R$ 827,00")
        let deferredRequestCount = try await recoveryRequestCount(baseURL)
        XCTAssertEqual(deferredRequestCount, "0")

        openRecovery(app)
        enterRecovery(app, amount: "54,00", time: "")
        let history = app.buttons["mvp.recovery.history"]
        show(app, history)
        tap(history)
        let historicalExpense = app.buttons.matching(identifier: "mvp.recovery.historyMovement").firstMatch
        show(app, historicalExpense)
        XCTAssertTrue(historicalExpense.label.contains("Despesa anterior"))
        tap(historicalExpense)
        typeRecoveryEvidence(app, "Despesa conferida no histórico")
        let link = app.buttons["mvp.recovery.link"]
        show(app, link)
        tap(link)
        tap(app.buttons["Confirmar vínculo"])
        show(app, current)
        XCTAssertEqual(current.value as? String, "R$ 827,00")

        openRecovery(app)
        enterRecovery(app, amount: "25,00", time: "08:00:00")
        typeRecoveryEvidence(app, "Comprovante de padaria")
        confirmDistinctRecovery(app)
        let retry = app.buttons["mvp.recovery.retry"]
        show(app, retry)
        attachScreen(app, named: "Recuperação com resposta HTTPS interrompida")
        app.terminate()
        app.launch()
        let stored = app.staticTexts["mvp.intent.pending"]
        show(app, stored)
        let beforeSwitch = try await recoveryRequestCount(baseURL)
        tap(app.buttons["Sair"])
        signIn(app, email: "i3-b@example.test", password: "fictional i3 password")
        XCTAssertTrue(app.buttons["Abrir conta pessoal em reais"].waitForExistence(timeout: 10))
        XCTAssertFalse(stored.exists)
        XCTAssertFalse(balance.exists)
        let afterSwitch = try await recoveryRequestCount(baseURL)
        XCTAssertEqual(beforeSwitch, afterSwitch)
        tap(app.buttons["Sair"])

        var release = URLRequest(url: try XCTUnwrap(URL(string: baseURL + "/__i3/release")))
        release.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: release)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
        signIn(app, email: "i3-a@example.test", password: "fictional i3 password")
        waitForLabel(balance, "R$ 802,00")
        XCTAssertFalse(stored.exists)
        show(app, checks)
        tap(checks)
        let remaining = app.descendants(matching: .any)["mvp.check.remainingDifference"]
        show(app, remaining)
        XCTAssertEqual(remaining.value as? String, "mais R$ 20,00")
        openRecovery(app)
        enterRecovery(app, amount: "20,00", time: "08:10:00")
        typeRecoveryEvidence(app, "Outro comprovante identificado")
        confirmDistinctRecovery(app)
        show(app, remaining)
        XCTAssertEqual(remaining.value as? String, "R$ 0,00")
        let original = app.descendants(matching: .any)["mvp.check.originalDifference"]
        show(app, original)
        XCTAssertEqual(original.value as? String, "mais R$ 45,00")
        XCTAssertEqual(current.value as? String, "R$ 782,00")
        XCTAssertTrue(app.staticTexts["Resolvida por lançamentos identificados"].exists)

        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        waitForLabel(balance, "R$ 782,00")
        XCTAssertGreaterThan(balance.frame.height, standardBalanceHeight)
        show(app, checks)
        tap(checks)
        show(app, remaining)
        XCTAssertEqual(remaining.value as? String, "R$ 0,00")
        try app.performAccessibilityAudit(for: [.dynamicType, .sufficientElementDescription])
        attachScreen(app, named: "Conferência resolvida com Dynamic Type máximo")
    }

    @MainActor
    func testI5SuspendsAndRecoversBaseCorrectionAcrossSessionsOverHTTPS() async throws {
        guard ProcessInfo.processInfo.environment["FINTECH_I5_HTTPS_TEST"] == "1" else {
            throw XCTSkip("Requires the disposable I5 HTTPS fixture.")
        }
        continueAfterFailure = false
        let app = launchI5()
        if app.buttons["Sair"].waitForExistence(timeout: 2) { tap(app.buttons["Sair"]) }
        signIn(app, email: "i5-a@example.test", password: "fictional i5 password")
        let balance = app.staticTexts["mvp.account.balance"]
        waitForLabel(balance, "R$ 827,00")
        let standardHeight = balance.frame.height

        openBaseAction(app, "suspend_base")
        typeAudit(app, amount: nil, reason: "Base em verificacao I5")
        let confirm = app.buttons["mvp.audit.confirm"]
        show(app, confirm)
        tap(confirm)
        let suspended = app.staticTexts["mvp.base.suspended"]
        show(app, suspended)
        XCTAssertFalse(balance.exists)
        openChecks(app)
        let original = app.descendants(matching: .any)["mvp.check.originalDifference"]
        show(app, original)
        XCTAssertEqual(original.value as? String, "mais R$ 45,00")
        XCTAssertTrue(app.staticTexts["Recálculo indisponível"].exists)
        attachScreen(app, named: "I5: cifras suspensas e conferência original preservada")
        tap(app.navigationBars.firstMatch.buttons.firstMatch)

        openBaseAction(app, "correct_base")
        typeAudit(app, amount: "910,00", reason: "Base conferida I5")
        let projected = app.descendants(matching: .any)["mvp.audit.projectedBalance"]
        show(app, projected)
        XCTAssertEqual(projected.value as? String, "R$ 837,00")
        let difference = app.descendants(matching: .any)["mvp.audit.projectedDifference"]
        show(app, difference)
        XCTAssertEqual(difference.value as? String, "mais R$ 55,00")
        show(app, confirm)
        tap(confirm)
        try await waitForI5Replay("interrupted")
        app.terminate()

        app.launch()
        let pending = app.staticTexts["mvp.intent.pending"]
        show(app, pending)
        XCTAssertFalse(balance.exists)
        tap(app.buttons["Sair"])
        let attempts = try await i5Status("attempts")
        signIn(app, email: "i5-b@example.test", password: "fictional i5 password")
        XCTAssertTrue(app.buttons["Abrir conta pessoal em reais"].waitForExistence(timeout: 10))
        XCTAssertFalse(pending.exists)
        XCTAssertFalse(balance.exists)
        let attemptsAfterSwitch = try await i5Status("attempts")
        XCTAssertEqual(attemptsAfterSwitch, attempts)
        tap(app.buttons["Sair"])

        var release = URLRequest(url: i5URL.appending(path: "__i5/release"))
        release.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: release)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        signIn(app, email: "i5-a@example.test", password: "fictional i5 password")
        try await waitForI5Replay("verified")
        waitForLabel(balance, "R$ 837,00")
        XCTAssertGreaterThan(balance.frame.height, standardHeight)
        XCTAssertFalse(pending.exists)
        openChecks(app)
        show(app, original)
        XCTAssertEqual(original.value as? String, "mais R$ 45,00")
        let residual = app.descendants(matching: .any)["mvp.check.remainingDifference"]
        show(app, residual)
        XCTAssertEqual(residual.value as? String, "mais R$ 55,00")
        try app.performAccessibilityAudit(for: [.dynamicType, .sufficientElementDescription])
        attachScreen(app, named: "I5 S10: diferença original de R$ 45 e resíduo de R$ 55")
        tap(app.navigationBars.firstMatch.buttons.firstMatch)

        let versions = app.buttons["mvp.base.versions"]
        show(app, versions)
        tap(versions)
        for action in ["correct_base", "suspend_base", "original"] {
            let header = app.descendants(matching: .any)
                .matching(identifier: "mvp.base.version.\(action)").firstMatch
            show(app, header)
        }
        try app.performAccessibilityAudit(for: [.dynamicType, .sufficientElementDescription])
    }

    @MainActor
    func testI5VerifiesOpeningRegistrationAndRecoveryOverHTTPS() throws {
        guard ProcessInfo.processInfo.environment["FINTECH_I5_HTTPS_TEST"] == "1" else {
            throw XCTSkip("Requires the disposable I5 HTTPS fixture.")
        }
        continueAfterFailure = false
        let app = launchI5()
        if app.buttons["Sair"].waitForExistence(timeout: 2) { tap(app.buttons["Sair"]) }
        signIn(app, email: "i5-d@example.test", password: "fictional i5 password")
        tap(app.buttons["Abrir conta pessoal em reais"])
        let base = app.textFields["mvp.account.openingAmount"]
        tap(base)
        base.typeText("900,00")
        tap(app.buttons["Revisar abertura"])
        tap(app.buttons["Confirmar abertura"])
        let balance = app.staticTexts["mvp.account.balance"]
        waitForLabel(balance, "R$ 900,00")
        register(app, amountDigits: "5500", description: "Lancamento ficticio I5")
        waitForLabel(balance, "R$ 845,00")
        let check = app.buttons["Conferir saldo"]
        show(app, check)
        tap(check)
        let observed = app.textFields["mvp.check.amount"]
        tap(observed)
        observed.typeText("800,00")
        tap(app.buttons["Revisar conferência"])
        let confirm = app.buttons["Confirmar conferência"]
        show(app, confirm)
        tap(confirm)
        waitForLabel(balance, "R$ 845,00")
        tap(app.buttons["Sair"])

        signIn(app, email: "i5-c@example.test", password: "fictional i5 password")
        waitForLabel(balance, "R$ 827,00")
        openChecks(app)
        openRecovery(app)
        enterRecovery(app, amount: "25,00", time: "08:00:00")
        typeRecoveryEvidence(app, "Comprovante ficticio I5")
        confirmDistinctRecovery(app)
        let residual = app.descendants(matching: .any)["mvp.check.remainingDifference"]
        show(app, residual)
        XCTAssertEqual(residual.value as? String, "mais R$ 20,00")
        attachScreen(app, named: "I5: recuperação retroativa no fluxo existente")
    }

    @MainActor
    func testI5ReadsBaseVersionDetailsAtMaximumDynamicType() throws {
        guard ProcessInfo.processInfo.environment["FINTECH_I5_HISTORY_TEST"] == "1" else {
            throw XCTSkip("Requires the completed I5 HTTPS fixture.")
        }
        continueAfterFailure = false
        let app = launchI5(maximumDynamicType: true)
        if app.buttons["Sair"].waitForExistence(timeout: 2) { tap(app.buttons["Sair"]) }
        signIn(app, email: "i5-a@example.test", password: "fictional i5 password")
        waitForLabel(app.staticTexts["mvp.account.balance"], "R$ 837,00")
        let versions = app.buttons["mvp.base.versions"]
        show(app, versions)
        tap(versions)

        let corrected = app.descendants(matching: .any)["mvp.base.version.amount.correct_base"]
        show(app, corrected)
        XCTAssertEqual(corrected.value as? String, "R$ 910,00")
        attachScreen(app, named: "I5: base corrigida em Dynamic Type máximo")

        let suspension = app.staticTexts["mvp.base.version.suspend_base"]
        show(app, suspension)
        let original = app.descendants(matching: .any)["mvp.base.version.amount.original"]
        show(app, original)
        XCTAssertEqual(original.value as? String, "R$ 900,00")
        attachScreen(app, named: "I5: base original em Dynamic Type máximo")
        try app.performAccessibilityAudit(for: [.dynamicType, .sufficientElementDescription])
    }

#if compiler(>=6.4)
    @MainActor
    func testI5VoiceOverReadsCorrectedBalanceAndOriginalDifference() throws {
        guard ProcessInfo.processInfo.environment["FINTECH_I5_VOICEOVER_TEST"] == "1", #available(iOS 27.0, *) else {
            throw XCTSkip("Requires iOS 27 and the completed I5 HTTPS fixture.")
        }
        continueAfterFailure = false
        let app = launchI5()
        if !app.buttons["Sair"].waitForExistence(timeout: 2) {
            signIn(app, email: "i5-a@example.test", password: "fictional i5 password")
        }
        waitForLabel(app.staticTexts["mvp.account.balance"], "R$ 837,00")
        openChecks(app)
        XCTAssertTrue(app.descendants(matching: .any)["mvp.check.currentBalance"].waitForExistence(timeout: 10))
        let voiceOver = XCUIDevice.shared.voiceOverService
        try voiceOver.enable()
        defer { try? voiceOver.disable() }
        var expected = [
            ["Saldo calculado atual", "837"],
            ["Data e hora da conferência"],
            ["Divergência original", "mais", "45"],
            ["Divergência restante no corte", "mais", "55"],
        ]
        var spoken: [String] = []
        for _ in 0..<40 {
            let utterance = try voiceOver.moveForward().utterance
            spoken.append(utterance)
            if let next = expected.first, next.allSatisfy({ utterance.localizedCaseInsensitiveContains($0) }) {
                expected.removeFirst()
                if expected.isEmpty { break }
            }
        }
        let evidence = XCTAttachment(string: spoken.joined(separator: "\n"))
        evidence.name = "I5 VoiceOver utterances"
        evidence.lifetime = .keepAlways
        add(evidence)
        XCTAssertTrue(expected.isEmpty, spoken.joined(separator: " | "))
    }
#endif

    private var i5URL: URL { URL(string: "https://localhost:55465")! }

    @MainActor
    private func launchI5(maximumDynamicType: Bool = false) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-staging", "-mvp-account"]
        if maximumDynamicType {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launchEnvironment["LENVER_STAGING_API_BASE_URL"] = i5URL.absoluteString
        app.launch()
        return app
    }

    @MainActor
    private func openBaseAction(_ app: XCUIApplication, _ action: String) {
        let link = app.descendants(matching: .any).matching(identifier: "mvp.audit.open.\(action)").firstMatch
        show(app, link)
        tap(link)
    }

    private func i5Status(_ action: String) async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: i5URL.appending(path: "__i5/\(action)"))
        return String(decoding: data, as: UTF8.self)
    }

    private func waitForI5Replay(_ expected: String) async throws {
        for _ in 0..<40 {
            if try await i5Status("replay") == expected { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTFail("Expected fixture state \(expected)")
    }

    @MainActor
    func testI4CorrectionRecoversAfterRelaunchOverHTTPS() async throws {
        guard ProcessInfo.processInfo.environment["FINTECH_I4_HTTPS_TEST"] == "1" else {
            throw XCTSkip("Requires the disposable I4 HTTPS fixture.")
        }
        continueAfterFailure = false
        let app = launchI4()
        if app.buttons["Sair"].waitForExistence(timeout: 2) { tap(app.buttons["Sair"]) }
        signIn(app, email: "i4-a@example.test", password: "fictional i4 password")
        let balance = app.staticTexts["mvp.account.balance"]
        waitForLabel(balance, "R$ 782,00")
        let standardHeight = balance.frame.height

        openI4Movement(app, named: "Padaria I4")
        tap(app.buttons["mvp.audit.open.correct"])
        typeAudit(app, amount: "24,00", reason: "Valor do comprovante")
        let projected = app.descendants(matching: .any)["mvp.audit.projectedBalance"]
        show(app, projected)
        XCTAssertEqual(projected.value as? String, "R$ 783,00")
        let projectedDifference = app.descendants(matching: .any)["mvp.audit.projectedDifference"]
        show(app, projectedDifference)
        XCTAssertEqual(projectedDifference.value as? String, "mais R$ 1,00")
        let confirm = app.buttons["mvp.audit.confirm"]
        show(app, confirm)
        tap(confirm)
        let replayURL = try XCTUnwrap(URL(string: "https://localhost:55456/__i4/replay"))
        var interrupted = false
        for _ in 0..<30 {
            let (status, _) = try await URLSession.shared.data(from: replayURL)
            if String(decoding: status, as: UTF8.self) == "interrupted" {
                interrupted = true
                break
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertTrue(interrupted, "The proxy must drop the response after commit before terminating the app.")
        app.terminate()

        var release = URLRequest(url: try XCTUnwrap(URL(string: "https://localhost:55456/__i4/release")))
        release.httpMethod = "POST"
        let (_, releaseResponse) = try await URLSession.shared.data(for: release)
        XCTAssertEqual((releaseResponse as? HTTPURLResponse)?.statusCode, 204)
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        waitForLabel(balance, "R$ 783,00")
        XCTAssertGreaterThan(balance.frame.height, standardHeight)
        var replayed = false
        for _ in 0..<40 {
            let (proof, _) = try await URLSession.shared.data(from: replayURL)
            if String(decoding: proof, as: UTF8.self) == "verified" {
                replayed = true
                break
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertTrue(replayed)

        openChecks(app)
        let original = app.descendants(matching: .any)["mvp.check.originalDifference"]
        show(app, original)
        XCTAssertEqual(original.value as? String, "mais R$ 45,00")
        let residual = app.descendants(matching: .any)["mvp.check.remainingDifference"]
        show(app, residual)
        XCTAssertEqual(residual.value as? String, "mais R$ 1,00")
        try app.performAccessibilityAudit(for: [.dynamicType, .sufficientElementDescription])
        attachScreen(app, named: "I4 S03: R$ 1 reaberto, original R$ 45, Dynamic Type máximo")
    }

    @MainActor
    func testI4InvalidatesAndReplacesOverHTTPS() throws {
        guard ProcessInfo.processInfo.environment["FINTECH_I4_HTTPS_TEST"] == "1" else {
            throw XCTSkip("Requires the disposable I4 HTTPS fixture.")
        }
        continueAfterFailure = false
        let app = launchI4()
        if app.buttons["Sair"].waitForExistence(timeout: 2) { tap(app.buttons["Sair"]) }
        signIn(app, email: "i4-b@example.test", password: "fictional i4 password")
        waitForLabel(app.staticTexts["mvp.account.balance"], "R$ 782,00")
        openI4Movement(app, named: "Despesa duplicada I4")
        tap(app.buttons["mvp.audit.open.invalidate"])
        typeAudit(app, amount: nil, reason: "Lancamento duplicado")
        let projected = app.descendants(matching: .any)["mvp.audit.projectedBalance"]
        show(app, projected)
        XCTAssertEqual(projected.value as? String, "R$ 802,00")
        let confirm = app.buttons["mvp.audit.confirm"]
        show(app, confirm)
        tap(confirm)
        let invalidated = app.descendants(matching: .any).matching(identifier: "mvp.audit.version.invalidate").firstMatch
        show(app, invalidated)
        XCTAssertTrue(invalidated.label.contains("Lancamento duplicado"))
        tap(app.navigationBars.firstMatch.buttons.firstMatch)
        waitForLabel(app.staticTexts["mvp.account.balance"], "R$ 802,00")

        openChecks(app)
        let remaining = app.descendants(matching: .any)["mvp.check.remainingDifference"]
        show(app, remaining)
        XCTAssertEqual(remaining.value as? String, "mais R$ 20,00")
        let replace = app.buttons.matching(identifier: "mvp.audit.open.replace_check").firstMatch
        show(app, replace)
        tap(replace)
        typeAudit(app, amount: "819,00", reason: "Erro de digitacao")
        show(app, confirm)
        tap(confirm)
        let replaced = app.staticTexts["Conferência substituída"]
        show(app, replaced)
        attachScreen(app, named: "I4: conferência original preservada após substituição")
    }

#if compiler(>=6.4)
    @MainActor
    func testI4VoiceOverReadsTheReopenedDifference() throws {
        guard ProcessInfo.processInfo.environment["FINTECH_I4_VOICEOVER_TEST"] == "1", #available(iOS 27.0, *) else {
            throw XCTSkip("Requires iOS 27 and the completed I4 correction fixture.")
        }
        continueAfterFailure = false
        let app = launchI4()
        if !app.buttons["Sair"].waitForExistence(timeout: 2) {
            signIn(app, email: "i4-a@example.test", password: "fictional i4 password")
        }
        waitForLabel(app.staticTexts["mvp.account.balance"], "R$ 783,00")
        openChecks(app)
        XCTAssertTrue(app.descendants(matching: .any)["mvp.check.currentBalance"].waitForExistence(timeout: 10))
        let voiceOver = XCUIDevice.shared.voiceOverService
        try voiceOver.enable()
        defer { try? voiceOver.disable() }
        var expected = [
            ["Saldo calculado atual", "783"],
            ["Divergência original", "mais", "45"],
            ["Divergência restante no corte", "mais", "1"],
        ]
        var spoken: [String] = []
        for _ in 0..<40 {
            let utterance = try voiceOver.moveForward().utterance
            spoken.append(utterance)
            if let next = expected.first, next.allSatisfy({ utterance.localizedCaseInsensitiveContains($0) }) {
                expected.removeFirst()
                if expected.isEmpty { break }
            }
        }
        let evidence = XCTAttachment(string: spoken.joined(separator: "\n"))
        evidence.name = "I4 VoiceOver utterances"
        evidence.lifetime = .keepAlways
        add(evidence)
        XCTAssertTrue(expected.isEmpty, spoken.joined(separator: " | "))
    }
#endif

    @MainActor
    private func launchI4() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-staging", "-mvp-account"]
        app.launchEnvironment["LENVER_STAGING_API_BASE_URL"] = "https://localhost:55456"
        app.launch()
        return app
    }

    @MainActor
    private func openI4Movement(_ app: XCUIApplication, named name: String) {
        let row = app.buttons.matching(identifier: "mvp.history.entry")
            .matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        show(app, row)
        tap(row)
    }

    @MainActor
    private func openChecks(_ app: XCUIApplication) {
        let checks = app.descendants(matching: .any).matching(identifier: "mvp.checks.open").firstMatch
        show(app, checks)
        tap(checks)
    }

    @MainActor
    private func typeAudit(_ app: XCUIApplication, amount: String?, reason: String) {
        if let amount {
            let field = app.textFields["mvp.audit.amount"]
            show(app, field)
            tap(field)
            field.typeText(amount)
        }
        let field = app.descendants(matching: .any).matching(identifier: "mvp.audit.reason").firstMatch
        show(app, field)
        tap(field)
        field.typeText(reason)
        let preview = app.buttons["mvp.audit.preview"]
        show(app, preview)
        tap(preview)
    }

    @MainActor
    private func openRecovery(_ app: XCUIApplication) {
        let recovery = app.descendants(matching: .any).matching(identifier: "mvp.recovery.open").firstMatch
        show(app, recovery)
        tap(recovery)
    }

    @MainActor
    private func enterRecovery(_ app: XCUIApplication, amount: String, time: String) {
        let value = app.textFields["mvp.recovery.amount"]
        show(app, value)
        if let previous = value.value as? String, previous != "Valor em reais", !previous.isEmpty {
            tap(value)
            value.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
        }
        tap(value)
        value.typeText(amount)
        if !time.isEmpty {
            let hour = app.textFields["mvp.recovery.time"]
            show(app, hour)
            tap(hour)
            hour.typeText(time)
        }
        let preview = app.buttons["mvp.recovery.preview"]
        show(app, preview)
        tap(preview)
    }

    @MainActor
    private func typeRecoveryEvidence(_ app: XCUIApplication, _ text: String) {
        let evidence = app.descendants(matching: .any).matching(identifier: "mvp.recovery.evidence").firstMatch
        show(app, evidence)
        tap(evidence)
        evidence.typeText(text)
    }

    @MainActor
    private func confirmDistinctRecovery(_ app: XCUIApplication) {
        let create = app.buttons["mvp.recovery.create"]
        show(app, create)
        tap(create)
        tap(app.buttons["Confirmar despesa distinta"])
    }

    private func recoveryRequestCount(_ baseURL: String) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: baseURL + "/__i3/count")))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return String(decoding: data, as: UTF8.self)
    }

#if compiler(>=6.4)
    @MainActor
    func testI3VoiceOverReadsResolutionAndPreservedDifference() throws {
        guard ProcessInfo.processInfo.environment["FINTECH_I3_VOICEOVER_TEST"] == "1", #available(iOS 27.0, *) else {
            throw XCTSkip("Requires iOS 27 and the completed S03 fixture.")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-staging", "-mvp-account"]
        app.launchEnvironment["LENVER_STAGING_API_BASE_URL"] = "https://localhost:55448"
        app.launch()
        if !app.buttons["Sair"].waitForExistence(timeout: 2) {
            signIn(app, email: "i3-a@example.test", password: "fictional i3 password")
        }
        waitForLabel(app.staticTexts["mvp.account.balance"], "R$ 782,00")
        let checks = app.descendants(matching: .any).matching(identifier: "mvp.checks.open").firstMatch
        attachScreen(app, named: "Conta antes de abrir a conferência no iOS 27")
        tap(checks)
        XCTAssertTrue(app.descendants(matching: .any)["mvp.check.currentBalance"].waitForExistence(timeout: 10))

        let voiceOver = XCUIDevice.shared.voiceOverService
        try voiceOver.enable()
        defer { try? voiceOver.disable() }
        XCTAssertTrue(voiceOver.isEnabled)
        let expected = [
            ["Saldo calculado atual", "782"],
            ["Resolvida por lançamentos identificados"],
            ["Valor informado", "800"],
            ["Divergência original", "mais", "45"],
            ["Divergência restante no corte", "0"],
        ]
        var spoken: [String] = []
        var next = 0
        for _ in 0..<35 {
            let speech = try voiceOver.moveForward().utterance
            spoken.append(speech)
            if expected[next].allSatisfy({ speech.localizedCaseInsensitiveContains($0) }) {
                next += 1
                if next == expected.count { break }
            }
        }
        let evidence = XCTAttachment(string: spoken.joined(separator: "\n"))
        evidence.name = "I3 VoiceOver utterances"
        evidence.lifetime = .keepAlways
        add(evidence)
        XCTAssertEqual(next, expected.count, spoken.joined(separator: " | "))
    }
#endif

#if compiler(>=6.4)
    @MainActor
    func testI2VoiceOverReadsTheCutAndSeparateBalances() throws {
        guard ProcessInfo.processInfo.environment["FINTECH_I2_VOICEOVER_TEST"] == "1" else {
            throw XCTSkip("Requires the S02 HTTPS fixture after the coffee has been recovered.")
        }
        guard #available(iOS 27.0, *) else {
            throw XCTSkip("XCUIVoiceOverService requires iOS 27 or later.")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-staging", "-mvp-account"]
        app.launchEnvironment["LENVER_STAGING_API_BASE_URL"] = "https://localhost:55445"
        app.launch()
        if !app.buttons["Sair"].waitForExistence(timeout: 2) {
            signIn(app, email: "i2-a@example.test", password: "fictional i2 password")
        }
        waitForLabel(app.staticTexts["mvp.account.balance"], "R$ 827,00")
        let link = app.descendants(matching: .any).matching(identifier: "mvp.checks.open").firstMatch
        show(app, link)
        tap(link)
        let current = app.descendants(matching: .any)["mvp.check.currentBalance"]
        XCTAssertTrue(current.waitForExistence(timeout: 10))

        let voiceOver = XCUIDevice.shared.voiceOverService
        try voiceOver.enable()
        defer { try? voiceOver.disable() }
        XCTAssertTrue(voiceOver.isEnabled)

        let expected = [
            ["Saldo calculado atual", "827"],
            ["Divergência em aberto"],
            ["Data e hora da conferência"],
            ["Valor informado", "800"],
            ["Saldo calculado na conferência", "845"],
            ["Divergência original", "mais", "45"],
            ["Divergência restante no corte", "mais", "45"],
        ]
        var spoken: [String] = []
        var next = 0
        for _ in 0..<35 {
            let speech = try voiceOver.moveForward().utterance
            spoken.append(speech)
            if expected[next].allSatisfy({ speech.localizedCaseInsensitiveContains($0) }) {
                next += 1
                if next == expected.count { break }
            }
        }
        let evidence = XCTAttachment(string: spoken.joined(separator: "\n"))
        evidence.name = "VoiceOver utterances in navigation order"
        evidence.lifetime = .keepAlways
        add(evidence)
        XCTAssertEqual(next, expected.count, spoken.joined(separator: " | "))
    }
#endif

    @MainActor
    func testSignInConfirmBaseAndReadOwnedBalanceOverHTTPS() throws {
        guard ProcessInfo.processInfo.environment["FINTECH_I1A_HTTPS_TEST"] == "1" else {
            throw XCTSkip("Requires a disposable HTTPS API and dedicated simulator.")
        }
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments = ["-staging", "-mvp-account"]
        app.launchEnvironment["LENVER_STAGING_API_BASE_URL"] = "https://localhost:55440"
        app.launch()

        if app.buttons["Sair"].exists { tap(app.buttons["Sair"]) }
        signIn(app, email: "i1a-a@example.test")
        tap(app.buttons["Abrir conta pessoal em reais"])

        let amount = app.textFields["mvp.account.openingAmount"]
        tap(amount)
        amount.typeText("900,25")
        tap(app.buttons["Revisar abertura"])
        tap(app.buttons["Confirmar abertura"])

        let balance = app.staticTexts["mvp.account.balance"]
        XCTAssertTrue(balance.waitForExistence(timeout: 15))
        XCTAssertEqual(balance.label, "R$ 900,25")
        attachScreen(app, named: "Saldo confirmado")
        tap(app.buttons["Sair"])
        XCTAssertTrue(balance.waitForNonExistence(timeout: 5))

        signIn(app, email: "i1a-b@example.test")
        tap(app.buttons["Conta antiga fictícia"])
        XCTAssertTrue(app.staticTexts["Saldo indisponível. Esta conta ainda não tem uma base confirmada."].waitForExistence(timeout: 10))
        XCTAssertFalse(balance.exists)
        attachScreen(app, named: "Conta sem base")
        tap(app.buttons["Sair"])
    }

    @MainActor
    private func signIn(_ app: XCUIApplication, email: String, password: String = "i1a disposable password") {
        let emailField = app.textFields["Email"]
        tap(emailField)
        if let previous = emailField.value as? String, previous != "Email", !previous.isEmpty {
            emailField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
        }
        emailField.typeText(email)
        let passwordField = app.secureTextFields["Password"]
        tap(passwordField)
        passwordField.typeText(password)
        tap(app.buttons["authentication.submit"])
        let skipPasswordSave = app.buttons["Not Now"]
        for _ in 0..<3 {
            guard skipPasswordSave.waitForExistence(timeout: 3) else { break }
            skipPasswordSave.tap()
        }
    }

    @MainActor
    private func register(_ app: XCUIApplication, amountDigits: String, description: String, income: Bool = false) {
        let open = app.buttons["Registrar lançamento"]
        show(app, open)
        tap(open)
        if income { tap(app.segmentedControls["createTransaction.type"].buttons["Income"]) }
        let amount = app.textFields["createTransaction.amount"]
        tap(amount)
        amount.typeText(amountDigits)
        let field = app.textViews["createTransaction.description"]
        tap(field)
        field.typeText(description)
        tap(app.buttons["createTransaction.submit"])
    }

    @MainActor
    private func show(_ app: XCUIApplication, _ element: XCUIElement) {
        for _ in 0..<4 {
            if element.waitForExistence(timeout: 2) {
                let frame = element.frame
                let navigationBottom = app.navigationBars.firstMatch.frame.maxY
                if element.isHittable && frame.midY > navigationBottom && frame.midY < app.frame.maxY { return }
                if frame.midY <= navigationBottom {
                    app.swipeDown()
                    continue
                }
            }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }

    @MainActor
    private func waitForLabel(_ element: XCUIElement, _ label: String) {
        let predicate = NSPredicate(format: "exists == true AND label == %@", label)
        let wait = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [wait], timeout: 15), .completed)
    }

    @MainActor
    private func attachScreen(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 15), file: file, line: line)
        element.tap()
    }
}
