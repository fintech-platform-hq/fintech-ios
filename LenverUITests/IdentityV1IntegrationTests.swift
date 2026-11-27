import XCTest

final class IdentityV1IntegrationTests: XCTestCase {
    @MainActor
    func testVerificationAccountAndSignOutAgainstLocalAPI() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let port = environment["LENVER_IDENTITY_TEST_PORT"],
              let email = environment["LENVER_IDENTITY_TEST_EMAIL"],
              let code = environment["LENVER_IDENTITY_TEST_CODE"] else {
            throw XCTSkip("Requires the loopback V1 API and a pre-issued synthetic email proof.")
        }
        continueAfterFailure = false
        let portuguese = environment["LENVER_IDENTITY_TEST_LANGUAGE"] == "pt-BR"
        let app = XCUIApplication()
        app.launchArguments = [
            "-local-identity", "-AppleLanguages", portuguese ? "(pt-BR)" : "(en)",
            "-AppleLocale", portuguese ? "pt_BR" : "en_US"
        ]
        func localized(_ english: String, _ brazilianPortuguese: String) -> String {
            portuguese ? brazilianPortuguese : english
        }
        app.launchEnvironment["LENVER_LOCAL_IDENTITY_PORT"] = port
        app.launchEnvironment["LENVER_IDENTITY_UI_TEST_CREDENTIALS"] = "1"
        app.launch()

        let submit = app.buttons["authentication.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 12))
        let address = app.textFields[localized("Email", "E-mail")]
        address.tap()
        address.typeText(email)
        let password = app.secureTextFields[localized("Password", "Senha")]
        password.tap()
        password.typeText("disposable interface password")
        submit.tap()

        let verification = app.navigationBars[localized("Verify your email", "Verifique seu e-mail")]
        XCTAssertTrue(verification.waitForExistence(timeout: 12))
        XCTAssertFalse(app.buttons["identity.open"].exists)
        attach(app, "V1-01-verification")
        let field = app.textFields["identity.code"]
        field.tap()
        field.typeText(code)
        app.buttons[localized("Confirm code", "Confirmar código")].tap()

        let account = app.buttons["identity.open"]
        XCTAssertTrue(account.waitForExistence(timeout: 12))
        account.tap()
        XCTAssertTrue(app.navigationBars[localized("User Account", "Conta do usuário")].waitForExistence(timeout: 12))
        attach(app, "V1-02-account")
        app.buttons[localized("Privacy", "Privacidade")].tap()
        XCTAssertTrue(app.staticTexts[localized("Delete account", "Excluir conta")].waitForExistence(timeout: 5))
        attach(app, "V1-03-privacy")
        app.navigationBars[localized("Privacy", "Privacidade")].buttons.firstMatch.tap()

        let close = app.buttons[localized("Close", "Fechar")]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        account.tap()
        XCTAssertTrue(app.navigationBars[localized("User Account", "Conta do usuário")].waitForExistence(timeout: 5))

        if !portuguese, environment["LENVER_IDENTITY_TEST_CHANGE_PASSWORD"] == "1" {
            app.buttons["Change password"].tap()
            XCTAssertTrue(app.navigationBars["Change password"].waitForExistence(timeout: 5))
            attach(app, "V1-04-password-change")
            for (label, value) in [
                ("Current password", "disposable interface password"),
                ("New password", "disposable changed interface password"),
                ("Confirm new password", "disposable changed interface password")
            ] {
                let field = app.secureTextFields[label]
                field.tap()
                field.typeText(value)
            }
            app.buttons["Save password"].tap()
            XCTAssertTrue(app.staticTexts["Password updated."].waitForExistence(timeout: 10))
            app.navigationBars["Change password"].buttons.firstMatch.tap()
        }

        app.buttons[localized("Sign Out", "Sair")].tap()
        let confirm = app.sheets.buttons[localized("Sign Out", "Sair")].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(submit.waitForExistence(timeout: 10))
        XCTAssertFalse(account.exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(submit.waitForExistence(timeout: 10))
        XCTAssertFalse(account.exists)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
