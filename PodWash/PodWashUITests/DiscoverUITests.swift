//
//  DiscoverUITests.swift
//  PodWashUITests
//
//  Slice 22 — Discover UI tests (slice-22-ux.md). AC6–AC7.
//
//  Golden titles hand-transcribed from Fixtures/itunes/*.json (see README.md).
//  Until FixtureDiscover routing exists (Engineer), these tests fail at runtime.
//

import XCTest

final class DiscoverUITests: XCTestCase {

    // Hand-transcribed from itunes_popular_response.json (independent golden).
    private let goldenPopularTitles = [
        "Fixture Popular Alpha",
        "Fixture Popular Beta",
        "Fixture Popular Gamma",
    ]

    // Hand-transcribed from itunes_search_response.json (independent golden).
    private let goldenSearchTitle0 = "Fixture Search Delta"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchDiscoverApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("-UITestFixtureDiscover")
        app.launch()
        return app
    }

    private func waitForDiscoverReady(_ app: XCUIApplication, timeout: TimeInterval = 10) {
        let root = app.descendants(matching: .any)["discoverRoot"]
        XCTAssertTrue(root.waitForExistence(timeout: timeout), "discoverRoot must appear within \(timeout)s")

        let loading = app.descendants(matching: .any)["discoverPopular.loading"]
        if loading.exists {
            XCTAssertFalse(loading.waitForExistence(timeout: timeout))
        }
    }

    // MARK: - AC6: popular list renders golden titles

    @MainActor
    func testPopularListRendersGoldenTitles() throws {
        let app = launchDiscoverApp()
        waitForDiscoverReady(app)

        for index in 0 ..< goldenPopularTitles.count {
            let cell = app.cells["popularCell_\(index)"].exists
                ? app.cells["popularCell_\(index)"]
                : app.descendants(matching: .any)["popularCell_\(index)"]
            XCTAssertTrue(cell.waitForExistence(timeout: 10), "popularCell_\(index) missing")
            XCTAssertEqual(cell.label, goldenPopularTitles[index])
        }
    }

    // MARK: - AC7: search + subscribe updates button accessibilityValue

    @MainActor
    func testSearchAndSubscribeUpdatesButton() throws {
        let app = launchDiscoverApp()
        waitForDiscoverReady(app)

        let searchField = app.textFields["discoverSearchField"].exists
            ? app.textFields["discoverSearchField"]
            : app.descendants(matching: .any)["discoverSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.tap()
        searchField.typeText("fixture-query")

        let searchCell = app.cells["searchResultCell_0"].exists
            ? app.cells["searchResultCell_0"]
            : app.descendants(matching: .any)["searchResultCell_0"]
        XCTAssertTrue(searchCell.waitForExistence(timeout: 10))
        XCTAssertEqual(searchCell.label, goldenSearchTitle0)

        let subscribeButton = app.buttons["subscribeButton_0"].exists
            ? app.buttons["subscribeButton_0"]
            : app.descendants(matching: .any)["subscribeButton_0"]
        XCTAssertTrue(subscribeButton.waitForExistence(timeout: 5))
        subscribeButton.tap()

        let subscribed = NSPredicate(format: "value == %@", "1")
        let expectation = XCTNSPredicateExpectation(predicate: subscribed, object: subscribeButton)
        let result = XCTWaiter().wait(for: [expectation], timeout: 5)
        XCTAssertEqual(result, XCTWaiter.Result.completed)
        XCTAssertEqual(subscribeButton.value as? String, "1")
    }
}
