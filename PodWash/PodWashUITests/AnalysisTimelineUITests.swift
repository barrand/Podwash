//
//  AnalysisTimelineUITests.swift
//  PodWashUITests
//
//  Slice 20 — Analysis timeline UI tests (slice-20-ux.md). AC3–AC5.
//  Launch fixture: -UITestFixtureAnalysisTimeline (implies feed; stepped analyzer).
//

import XCTest

final class AnalysisTimelineUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - AC3

    @MainActor
    func testTimelineAppearsWithFirstSnapshot() throws {
        let app = launchTimelineFixtureApp()
        enableCleaningOnRow0(in: app)

        let timeline = Self.analysisTimelineElement(in: app)
        XCTAssertTrue(timeline.waitForExistence(timeout: 2))

        let firstSnapshot = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "ready:3,processing:1,pending:8"),
            object: timeline
        )
        XCTAssertEqual(XCTWaiter().wait(for: [firstSnapshot], timeout: 2), .completed)
    }

    // MARK: - AC4

    @MainActor
    func testTimelineCompletesAndRetiresProgress() throws {
        let app = launchTimelineFixtureApp()
        enableCleaningOnRow0(in: app)

        let timeline = Self.analysisTimelineElement(in: app)
        XCTAssertTrue(timeline.waitForExistence(timeout: 2))

        let terminalSnapshot = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "ready:12,processing:0,pending:0"),
            object: timeline
        )
        XCTAssertEqual(XCTWaiter().wait(for: [terminalSnapshot], timeout: 5), .completed)

        XCTAssertFalse(app.descendants(matching: .any)["analysisProgress"].exists)

        let episodeBadge = app.descendants(matching: .any)["cleaningBadge_episodeOn"]
        XCTAssertTrue(episodeBadge.waitForExistence(timeout: 2))
    }

    // MARK: - AC5

    @MainActor
    func testTimelineMidRunSnapshot() throws {
        let app = launchTimelineFixtureApp()
        enableCleaningOnRow0(in: app)

        let timeline = Self.analysisTimelineElement(in: app)
        XCTAssertTrue(timeline.waitForExistence(timeout: 2))

        let midRunSnapshot = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "ready:6,processing:1,pending:5"),
            object: timeline
        )
        XCTAssertEqual(XCTWaiter().wait(for: [midRunSnapshot], timeout: 5), .completed)

        let terminalSnapshot = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "ready:12,processing:0,pending:0"),
            object: timeline
        )
        XCTAssertEqual(XCTWaiter().wait(for: [terminalSnapshot], timeout: 5), .completed)
    }

    // MARK: - Launch + interaction

    @MainActor
    private func launchTimelineFixtureApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("-UITestFixtureAnalysisTimeline")
        app.launch()

        let episodeList = app.descendants(matching: .any)["episodeList"]
        XCTAssertTrue(episodeList.waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func enableCleaningOnRow0(in app: XCUIApplication) {
        let episodeToggle = app.switches["episodeCleaningToggle_0"]
        XCTAssertTrue(episodeToggle.waitForExistence(timeout: 5))

        let toggleHittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: episodeToggle
        )
        XCTAssertEqual(XCTWaiter().wait(for: [toggleHittable], timeout: 3), .completed)

        episodeToggle.tap()
    }

    /// Slice-20 UX: `analysisTimeline` identifier on analyzing row; label `Analysis timeline`.
    private static func analysisTimelineElement(in app: XCUIApplication) -> XCUIElement {
        let cell = app.cells["episodeCell_0"]
        let scoped = cell.descendants(matching: .any)["analysisTimeline"]
        if scoped.exists {
            return scoped
        }
        let global = app.descendants(matching: .any)["analysisTimeline"]
        if global.exists {
            return global
        }
        let scopedLabel = cell.descendants(matching: .any)["Analysis timeline"]
        if scopedLabel.exists {
            return scopedLabel
        }
        return app.descendants(matching: .any)["Analysis timeline"]
    }
}
