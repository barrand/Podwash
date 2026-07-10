//
//  SettingsUITests.swift
//  PodWashUITests
//
//  Slice 13 — Settings UI tests (slice-13-settings-ux.md). AC5–AC6.
//
//  Launch fixture: -UITestFixtureSettings opens SettingsView directly (no RSS/network).
//  Scheme parallelization is already disabled (Slice 03 precedent).
//
//  Until FixtureSettings routing and SettingsView exist (Engineer, later effort),
//  these tests fail at runtime — intended TDD red state after compile.
//

import XCTest

final class SettingsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchSettingsApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("-UITestFixtureSettings")
        app.launch()
        return app
    }

    private func waitForSettingsRoot(_ app: XCUIApplication, timeout: TimeInterval = 10) {
        let root = app.descendants(matching: .any)["settingsRoot"]
        XCTAssertTrue(root.waitForExistence(timeout: timeout), "settingsRoot must appear within \(timeout)s")
    }

    // MARK: - AC5: category toggle accessibilityValue cycles "1" ↔ "0"

    @MainActor
    func testCategoryToggleAccessibilityValue() throws {
        let app = launchSettingsApp()
        waitForSettingsRoot(app)

        let sWordToggle = app.descendants(matching: .any)["categoryToggle_sWord"]
        XCTAssertTrue(sWordToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(sWordToggle.value as? String, "1", "Fresh store: sWord category must be ON")

        sWordToggle.tap()
        XCTAssertEqual(sWordToggle.value as? String, "0", "One tap must disable sWord category")

        sWordToggle.tap()
        XCTAssertEqual(sWordToggle.value as? String, "1", "Second tap must re-enable sWord category")
    }

    // MARK: - AC6: custom word add shows row with stored label

    @MainActor
    func testCustomWordAppearsInList() throws {
        let app = launchSettingsApp()
        waitForSettingsRoot(app)

        let firstRow = app.descendants(matching: .any)["customWordRow_0"]
        XCTAssertFalse(firstRow.exists, "Fresh store must have no custom words")

        let textField = app.descendants(matching: .any)["customWordTextField"]
        XCTAssertTrue(textField.waitForExistence(timeout: 5))
        textField.tap()
        textField.typeText("testword")

        let addButton = app.descendants(matching: .any)["customWordAddButton"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        let rowExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"),
            object: firstRow
        )
        XCTAssertEqual(XCTWaiter().wait(for: [rowExpectation], timeout: 2), .completed)

        let label = firstRow.label.lowercased()
        XCTAssertTrue(
            label.contains("testword"),
            "customWordRow_0 label must contain testword (case-insensitive); got: \(firstRow.label)"
        )
    }
}
