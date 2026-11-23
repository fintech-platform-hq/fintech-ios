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
        app.launchEnvironment["FINTECH_STAGING_BASE_URL"] = baseURL
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
        app.launchEnvironment["FINTECH_STAGING_BASE_URL"] = baseURL

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
        app.launchEnvironment["FINTECH_STAGING_BASE_URL"] = "https://localhost:55445"
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
        app.launchEnvironment["FINTECH_STAGING_BASE_URL"] = "https://localhost:55440"
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
