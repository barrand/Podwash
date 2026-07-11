//
//  SettingsUITests.swift
//  PodWashUITests
//
//  Slice 13 — Settings UI tests (slice-13-settings-ux.md). AC5–AC6.
//  Slice 16 — `testMuteOverlayControlCycles` (slice-16-ux.md).
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
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    private func launchSettingsApp() -> XCUIApplication {
        // Settings UITests assume portrait height; sims often wake in landscape
        // (~402pt), which leaves categoryToggle_sWord off-screen with a zero AX frame.
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments.append("-UITestFixtureSettings")
        app.launch()
        return app
    }

    private func waitForSettingsRoot(_ app: XCUIApplication, timeout: TimeInterval = 10) {
        let root = app.descendants(matching: .any)["settingsRoot"]
        XCTAssertTrue(root.waitForExistence(timeout: timeout), "settingsRoot must appear within \(timeout)s")
    }

    private func categoryToggle(_ id: String, in app: XCUIApplication) -> XCUIElement {
        // Category rows are Buttons (Image indicator, not UISwitch). Prefer buttons
        // so AX activate hits the control action — switches were a prior miss path.
        let asButton = app.buttons[id]
        if asButton.exists { return asButton }
        return app.descendants(matching: .any)[id]
    }

    /// True when the element has a non-zero frame whose center sits inside the window.
    /// `isHittable` alone is insufficient: landscape ScrollView can expose AX nodes
    /// with zero/stale frames that still report hittable, and taps then no-op.
    private func hasTappableFrame(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        guard frame.width > 1, frame.height > 1 else { return false }
        let window = app.windows.firstMatch.frame
        guard window.width > 0, window.height > 0 else { return false }
        let inset = window.insetBy(dx: 4, dy: 12)
        return inset.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    /// Scrolls via an edge drag so center `swipeUp` cannot flip Unrelated/Auto toggles.
    private func scrollUntilTappable(
        identifier: String,
        in app: XCUIApplication,
        maxSwipes: Int = 12
    ) -> XCUIElement {
        var swipes = 0
        while swipes < maxSwipes {
            let element = categoryToggle(identifier, in: app)
            if hasTappableFrame(element, in: app) {
                return element
            }
            let window = app.windows.firstMatch
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.82))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.28))
            start.press(forDuration: 0.05, thenDragTo: end)
            swipes += 1
        }
        let element = categoryToggle(identifier, in: app)
        XCTAssertTrue(
            hasTappableFrame(element, in: app),
            "\(identifier) must have an on-screen frame after scrolling; got frame=\(element.frame) hittable=\(element.isHittable)"
        )
        return element
    }

    private func tapCategoryToggle(identifier: String, in app: XCUIApplication) {
        let element = scrollUntilTappable(identifier: identifier, in: app)
        // AX activate on the Button — coordinate taps miss SwiftUI Button actions.
        element.tap()
    }

    private func waitForAccessibilityValue(
        _ expected: String,
        identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval,
        message: String
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        var lastValue: String?
        while Date() < deadline {
            let element = categoryToggle(identifier, in: app)
            lastValue = element.value as? String
            if lastValue == expected {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("\(message); expected accessibilityValue \(expected), got \(lastValue ?? "nil")")
    }

    private func muteOverlayControl(in app: XCUIApplication) -> XCUIElement {
        let asButton = app.buttons["muteOverlayControl"]
        if asButton.exists { return asButton }
        return app.descendants(matching: .any)["muteOverlayControl"]
    }

    // MARK: - Slice 16: mute overlay control cycles off/beep/quack

    @MainActor
    func testMuteOverlayControlCycles() throws {
        let app = launchSettingsApp()
        waitForSettingsRoot(app)

        let control = muteOverlayControl(in: app)
        XCTAssertTrue(control.waitForExistence(timeout: 5), "muteOverlayControl must exist")
        XCTAssertEqual(
            control.value as? String,
            "off",
            "Fresh store: mute overlay must default to off"
        )

        control.tap()
        waitForAccessibilityValue(
            "beep",
            identifier: "muteOverlayControl",
            in: app,
            timeout: 2,
            message: "One tap must select beep overlay"
        )

        muteOverlayControl(in: app).tap()
        waitForAccessibilityValue(
            "quack",
            identifier: "muteOverlayControl",
            in: app,
            timeout: 2,
            message: "Second tap must select quack overlay"
        )

        muteOverlayControl(in: app).tap()
        waitForAccessibilityValue(
            "off",
            identifier: "muteOverlayControl",
            in: app,
            timeout: 2,
            message: "Third tap must return overlay to off"
        )
    }

    // MARK: - AC5: category toggle accessibilityValue cycles "1" ↔ "0"

    @MainActor
    func testCategoryToggleAccessibilityValue() throws {
        let app = launchSettingsApp()
        waitForSettingsRoot(app)

        let toggleID = "categoryToggle_sWord"
        XCTAssertTrue(categoryToggle(toggleID, in: app).waitForExistence(timeout: 5))

        _ = scrollUntilTappable(identifier: toggleID, in: app)
        XCTAssertEqual(
            categoryToggle(toggleID, in: app).value as? String,
            "1",
            "Fresh store: sWord category must be ON"
        )

        tapCategoryToggle(identifier: toggleID, in: app)
        waitForAccessibilityValue(
            "0",
            identifier: toggleID,
            in: app,
            timeout: 5,
            message: "One tap must disable sWord category"
        )

        tapCategoryToggle(identifier: toggleID, in: app)
        waitForAccessibilityValue(
            "1",
            identifier: toggleID,
            in: app,
            timeout: 5,
            message: "Second tap must re-enable sWord category"
        )
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
        // Field may sit below the fold after Slice 19's unrelated section / landscape.
        if !hasTappableFrame(textField, in: app) {
            let window = app.windows.firstMatch
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.82))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.28))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
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
