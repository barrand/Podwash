//
//  AnalysisProgressUITests.swift
//  PodWashUITests
//
//  Slice 09 — Analysis progress + cleaning toggle UI tests (slice-09-ux.md). AC2, AC3.
//

import XCTest

final class AnalysisProgressUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testToggleBadges() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-UITestFixtureFeed")
        app.launch()

        let episodeList = app.descendants(matching: .any)["episodeList"]
        XCTAssertTrue(episodeList.waitForExistence(timeout: 10))

        XCTAssertFalse(app.descendants(matching: .any)["cleaningBadge_channelOn"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["cleaningBadge_episodeOn"].exists)

        let channelToggle = app.switches["channelCleaningToggle"]
        XCTAssertTrue(channelToggle.waitForExistence(timeout: 5))
        channelToggle.tap()

        let channelBadge = app.descendants(matching: .any)["cleaningBadge_channelOn"]
        XCTAssertTrue(channelBadge.waitForExistence(timeout: 2))

        let episodeToggle = app.switches["episodeCleaningToggle_0"]
        XCTAssertTrue(episodeToggle.waitForExistence(timeout: 5))
        episodeToggle.tap()

        let episodeBadge = app.descendants(matching: .any)["cleaningBadge_episodeOn"]
        XCTAssertTrue(episodeBadge.waitForExistence(timeout: 2))
    }

    @MainActor
    func testProgressIndicatorLifecycle() throws {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-UITestFixtureFeed", "-UITestFixtureAnalysis"])
        app.launch()

        let episodeList = app.descendants(matching: .any)["episodeList"]
        XCTAssertTrue(episodeList.waitForExistence(timeout: 10))

        let episodeToggle = app.switches["episodeCleaningToggle_0"]
        XCTAssertTrue(episodeToggle.waitForExistence(timeout: 5))

        let episodeCell = app.cells["episodeCell_0"]
        XCTAssertTrue(episodeCell.waitForExistence(timeout: 5))

        // Register before tap so XCTest observes accessibility updates during the
        // toggle action (progress can appear and vanish before post-tap idle ends).
        let progressAppeared = expectation(
            for: Self.analysisProgressVisiblePredicate,
            evaluatedWith: app,
            handler: nil
        )

        episodeToggle.tap()

        wait(for: [progressAppeared], timeout: 2)

        let progress = Self.analysisProgressElement(in: app, cell: episodeCell)
        let progressGone = NSPredicate(format: "exists == false")
        let progressExpectation = XCTNSPredicateExpectation(predicate: progressGone, object: progress)
        XCTAssertEqual(XCTWaiter().wait(for: [progressExpectation], timeout: 5), .completed)

        let episodeBadge = app.descendants(matching: .any)["cleaningBadge_episodeOn"]
        XCTAssertTrue(episodeBadge.waitForExistence(timeout: 2))
    }

    private static var analysisProgressVisiblePredicate: NSPredicate {
        NSPredicate { evaluatedObject, _ in
            guard let app = evaluatedObject as? XCUIApplication else { return false }
            let cell = app.cells["episodeCell_0"]
            return analysisProgressElement(in: app, cell: cell).exists
        }
    }

    /// Slice-09 UX: `analysisProgress` identifier on row *i*; label `Analyzing episode`.
    private static func analysisProgressElement(in app: XCUIApplication, cell: XCUIElement) -> XCUIElement {
        let scoped = cell.descendants(matching: .any)["analysisProgress"]
        if scoped.exists {
            return scoped
        }
        let global = app.descendants(matching: .any)["analysisProgress"]
        if global.exists {
            return global
        }
        let scopedLabel = cell.descendants(matching: .any)["Analyzing episode"]
        if scopedLabel.exists {
            return scopedLabel
        }
        return app.descendants(matching: .any)["Analyzing episode"]
    }
}
