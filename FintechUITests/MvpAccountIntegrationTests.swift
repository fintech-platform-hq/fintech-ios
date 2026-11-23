import XCTest

final class MvpAccountIntegrationTests: XCTestCase {
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
    private func signIn(_ app: XCUIApplication, email: String) {
        let emailField = app.textFields["Email"]
        tap(emailField)
        if let previous = emailField.value as? String, previous != "Email", !previous.isEmpty {
            emailField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
        }
        emailField.typeText(email)
        let password = app.secureTextFields["Password"]
        tap(password)
        password.typeText("i1a disposable password")
        tap(app.buttons["authentication.submit"])
        let skipPasswordSave = app.buttons["Not Now"]
        for _ in 0..<3 {
            guard skipPasswordSave.waitForExistence(timeout: 3) else { break }
            skipPasswordSave.tap()
        }
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
