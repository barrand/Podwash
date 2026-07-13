//
//  AnalysisProgressUITests.swift
//  PodWashUITests
//
//  Slice 09 — Analysis progress + cleaning toggle UI tests (slice-09-ux.md). AC2, AC3.
//  Slice 20 — migrated `analysisProgress` → `analysisTimeline` (ADR-018).
//

import XCTest

final class AnalysisProgressUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEpisodeCleaningTogglesAbsentChannelTogglePresent() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-UITestFixtureFeed")
        app.launch()

        let episodeList = app.descendants(matching: .any)["episodeList"]
        XCTAssertTrue(episodeList.waitForExistence(timeout: 10))

        XCTAssertFalse(app.switches["episodeCleaningToggle_0"].exists)
        XCTAssertFalse(app.switches["episodeCleaningToggle_1"].exists)

        let channelToggle = app.switches["channelCleaningToggle"]
        XCTAssertTrue(channelToggle.waitForExistence(timeout: 5))
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
        XCTAssertFalse(app.switches["episodeCleaningToggle_0"].exists)

        let channelToggle = app.switches["channelCleaningToggle"]
        XCTAssertTrue(channelToggle.waitForExistence(timeout: 5))
        channelToggle.tap()

        let channelOnExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "on"),
            object: channelToggle
        )
        XCTAssertEqual(XCTWaiter().wait(for: [channelOnExpectation], timeout: 2), .completed)
        XCTAssertFalse(app.descendants(matching: .any)["cleaningBadge_channelOn"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["cleaningBadge_episodeOn"].exists)

        channelToggle.tap()

        let channelOffExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "off"),
            object: channelToggle
        )
        XCTAssertEqual(XCTWaiter().wait(for: [channelOffExpectation], timeout: 2), .completed)
        XCTAssertFalse(app.descendants(matching: .any)["cleaningBadge_channelOn"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["cleaningBadge_episodeOn"].exists)
    }

    @MainActor
    func testAnalysisProgressLifecycle() throws {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-UITestFixtureFeed", "-UITestFixtureAnalysis"])
        app.launch()

        let episodeList = app.descendants(matching: .any)["episodeList"]
        XCTAssertTrue(episodeList.waitForExistence(timeout: 10))

        let channelToggle = app.switches["channelCleaningToggle"]
        XCTAssertTrue(channelToggle.waitForExistence(timeout: 5))

        let episodeCell = app.cells["episodeCell_0"]
        XCTAssertTrue(episodeCell.waitForExistence(timeout: 5))

        // CarPlay multi-scene can leave a non-key empty window; wait until the
        // UIKit switch is hittable so the tap lands on the content WindowGroup.
        let toggleHittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: channelToggle
        )
        XCTAssertEqual(XCTWaiter().wait(for: [toggleHittable], timeout: 3), .completed)

        // Register before tap so XCTest observes accessibility updates during the
        // toggle action (timeline can appear and vanish before post-tap idle ends).
        let timelineAppeared = expectation(
            for: Self.analysisTimelineVisiblePredicate,
            evaluatedWith: app,
            handler: nil
        )

        channelToggle.tap()

        wait(for: [timelineAppeared], timeout: 2)

        let timeline = Self.analysisTimelineElement(in: app, cell: episodeCell)
        let timelineGone = NSPredicate(format: "exists == false")
        let timelineExpectation = XCTNSPredicateExpectation(predicate: timelineGone, object: timeline)
        XCTAssertEqual(XCTWaiter().wait(for: [timelineExpectation], timeout: 5), .completed)

        XCTAssertFalse(app.descendants(matching: .any)["analysisProgress"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["cleaningBadge_episodeOn"].exists)
    }

    private static var analysisTimelineVisiblePredicate: NSPredicate {
        NSPredicate { evaluatedObject, _ in
            guard let app = evaluatedObject as? XCUIApplication else { return false }
            let cell = app.cells["episodeCell_0"]
            return analysisTimelineElement(in: app, cell: cell).exists
        }
    }

    /// Slice-20 UX: `analysisTimeline` identifier on row *i*; label `Analysis timeline`.
    private static func analysisTimelineElement(in app: XCUIApplication, cell: XCUIElement) -> XCUIElement {
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
