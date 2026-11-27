//
//  LenverUITests.swift
//  LenverUITests
//
//  Created by Gabriel Ferrari on 31/07/26.
//

import XCTest
import UIKit

final class LenverUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCreateTransactionFormAndKeyboardDismissal() throws {
        let app = makeAuthenticatedApp()
        app.launch()
        let navigationBar = app.navigationBars["Create Transaction"]

        XCTAssertTrue(
            navigationBar.waitForExistence(timeout: 2)
        )

        let signOutButton = app.buttons["Sign Out"]
        XCTAssertTrue(signOutButton.waitForExistence(timeout: 2))
        XCTAssertTrue(signOutButton.isHittable)

        let amountField = app.textFields["createTransaction.amount"]
        let typePicker = app.segmentedControls["createTransaction.type"]
        let incomeSegment = typePicker.buttons["Income"]
        let descriptionField = app.textViews[
            "createTransaction.description"
        ]
        let submitButton = app.buttons["createTransaction.submit"]

        XCTAssertTrue(amountField.exists)
        XCTAssertTrue(typePicker.exists)
        XCTAssertTrue(incomeSegment.exists)
        XCTAssertTrue(descriptionField.exists)
        XCTAssertTrue(submitButton.exists)
        XCTAssertTrue(submitButton.isHittable)

        amountField.tap()

        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 2))
        XCTAssertTrue(keyboard.keys["1"].exists)
        XCTAssertFalse(keyboard.keys["A"].exists)
        XCTAssertTrue(submitButton.exists)
        XCTAssertTrue(submitButton.isHittable)
        XCTAssertFalse(app.toolbars.buttons["Done"].exists)

        amountField.typeText("abc150,25xyz")
        XCTAssertEqual(
            amountField.value as? String,
            "-R$150.25"
        )

        amountField.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(
            amountField.value as? String,
            "-R$15.02"
        )

        incomeSegment.tap()

        let updatedAmountField = app.textFields["createTransaction.amount"]
        let amountUpdated = expectation(
            for: NSPredicate(format: "value == %@", "+R$15.02"),
            evaluatedWith: updatedAmountField
        )
        wait(for: [amountUpdated], timeout: 10)
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 2))
        XCTAssertTrue(submitButton.exists)
        XCTAssertTrue(submitButton.isHittable)
        XCTAssertEqual(
            updatedAmountField.value as? String,
            "+R$15.02"
        )

        descriptionField.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 2))
        XCTAssertTrue(submitButton.exists)
        XCTAssertTrue(submitButton.isHittable)
        descriptionField.typeText(String(repeating: "a", count: 255))

        let limitedDescription = try XCTUnwrap(
            descriptionField.value as? String
        )
        XCTAssertEqual(limitedDescription.count, 255)

        let heightAtLimit = descriptionField.frame.height
        descriptionField.typeText("b")

        let descriptionAfterExcessInput = try XCTUnwrap(
            descriptionField.value as? String
        )
        XCTAssertEqual(descriptionAfterExcessInput.count, 255)
        XCTAssertEqual(descriptionField.frame.height, heightAtLimit)

        let descriptionCount = app.staticTexts[
            "createTransaction.descriptionCount"
        ]
        XCTAssertEqual(descriptionCount.label, "255 of 255 characters")

        typePicker.tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 2))
        XCTAssertTrue(submitButton.exists)
        XCTAssertTrue(submitButton.isHittable)
    }

    @MainActor
    func testUnsupportedFrenchLanguageFallsBackToEnglishWithBRL() {
        let app = makeAuthenticatedApp()
        app.launchArguments = [
            "-ui-testing-authenticated", "-AppleLanguages", "(fr-FR)",
            "-AppleLocale", "fr_FR"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Create Transaction"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls["createTransaction.type"].buttons["Income"].exists)
        let amount = app.textFields["createTransaction.amount"]
        amount.tap()
        amount.typeText("123")
        XCTAssertEqual(amount.value as? String, "-R$1.23")
    }

    @MainActor
    func testDescriptionHeightStaysBoundedForRepeatedNewlines() throws {
        let app = makeAuthenticatedApp()
        app.launch()

        let descriptionField = app.textViews[
            "createTransaction.description"
        ]
        let descriptionSurface = app.descendants(matching: .any)[
            "createTransaction.descriptionSurface"
        ]
        let descriptionCount = app.staticTexts[
            "createTransaction.descriptionCount"
        ]
        XCTAssertTrue(descriptionField.waitForExistence(timeout: 2))
        XCTAssertTrue(descriptionSurface.exists)
        XCTAssertTrue(descriptionCount.exists)

        let initialFieldHeight = descriptionField.frame.height
        let initialSurfaceHeight = descriptionSurface.frame.height
        let initialSectionSpan = descriptionCount.frame.maxY
            - descriptionSurface.frame.minY
        descriptionField.tap()
        descriptionField.typeText(
            String(
                repeating: XCUIKeyboardKey.return.rawValue,
                count: 40
            )
        )

        let enteredDescription = try XCTUnwrap(
            descriptionField.value as? String
        )
        XCTAssertEqual(enteredDescription.count, 40)
        XCTAssertEqual(descriptionField.frame.height, initialFieldHeight)
        XCTAssertEqual(descriptionSurface.frame.height, initialSurfaceHeight)
        XCTAssertEqual(
            descriptionCount.frame.maxY - descriptionSurface.frame.minY,
            initialSectionSpan
        )
    }

    @MainActor
    func testInvalidAmountShowsExistingValidationStatus() throws {
        let app = makeAuthenticatedApp()
        app.launch()

        let submitButton = app.buttons["createTransaction.submit"]
        XCTAssertTrue(submitButton.waitForExistence(timeout: 2))

        submitButton.tap()

        let status = app.staticTexts["createTransaction.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 2))
        XCTAssertEqual(status.label, "Enter an amount.")
    }

    @MainActor
    func testPrimaryActionUsesReadableWidthOnIPad() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("This layout assertion requires an iPad destination.")
        }

        let app = makeAuthenticatedApp()
        app.launch()

        let submitButton = app.buttons["createTransaction.submit"]
        XCTAssertTrue(submitButton.waitForExistence(timeout: 2))
        XCTAssertLessThanOrEqual(submitButton.frame.width, 640)
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            makeAuthenticatedApp().launch()
        }
    }

    private func makeAuthenticatedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing-authenticated", "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        return app
    }
}
