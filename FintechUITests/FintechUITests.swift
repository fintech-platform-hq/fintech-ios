//
//  FintechUITests.swift
//  FintechUITests
//
//  Created by Gabriel Ferrari on 31/07/26.
//

import XCTest

final class FintechUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCreateTransactionFormAndKeyboardDismissal() throws {
        let app = XCUIApplication()
        app.launch()
        let navigationBar = app.navigationBars["Create Transaction"]

        XCTAssertTrue(
            navigationBar.waitForExistence(timeout: 2)
        )

        let amountField = app.textFields["createTransaction.amount"]
        let typePicker = app.descendants(matching: .any)[
            "createTransaction.type"
        ]
        let descriptionField = app.textViews[
            "createTransaction.description"
        ]
        let submitButton = app.buttons["createTransaction.submit"]

        XCTAssertTrue(amountField.exists)
        XCTAssertTrue(typePicker.exists)
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
            "R$ 150,25"
        )

        amountField.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(
            amountField.value as? String,
            "R$ 15,02"
        )

        typePicker.tap()

        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 2))
        XCTAssertTrue(submitButton.exists)
        XCTAssertTrue(submitButton.isHittable)
        XCTAssertEqual(
            amountField.value as? String,
            "R$ 15,02"
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
    func testDescriptionHeightStaysBoundedForRepeatedNewlines() throws {
        let app = XCUIApplication()
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
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
