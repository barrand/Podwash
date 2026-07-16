//
//  AnalysisTimelineUITests.swift
//  PodWashUITests
//
//  Task 026 — Episode row no longer hosts `analysisTimeline` (slice-20 retirement).
//  Launch fixture: -UITestFixtureAnalysisTimeline (implies feed; stepped analyzer).
//

import XCTest

final class AnalysisTimelineUITests: XCTestCase {

    private let episodeListTimeout: TimeInterval = 10
    private let timelineAbsentTimeout: TimeInterval = 2
    private let completeTimeout: TimeInterval = 5

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Task 026 AC1

    @MainActor
    func testEpisodeRowDoesNotShowAnalysisTimelineWhileAnalyzing() throws {
        let app = launchTimelineFixtureApp()
        enableChannelCleaning(in: app)

        let absentDeadline = Date().addingTimeInterval(timelineAbsentTimeout)
        while Date() < absentDeadline {
            assertAnalysisTimelineAbsent(onRow: 0, in: app)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        assertAnalysisTimelineAbsent(onRow: 0, in: app)
    }

    // MARK: - Task 026 AC2

    @MainActor
    func testEpisodeRowShowsBadgeWithoutTimelineAtComplete() throws {
        let app = launchTimelineFixtureApp()

        let badgeAppeared = expectation(description: "cleaning badge at terminal complete")
        badgeAppeared.assertForOverFulfill = false

        var sawBadge = false
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            guard !sawBadge else { return }
            let badge = Self.cleaningBadgeEpisodeOn(in: app)
            guard badge.exists else { return }
            sawBadge = true
            timer.invalidate()
            badgeAppeared.fulfill()
        }
        RunLoop.current.add(timer, forMode: .common)

        enableChannelCleaning(in: app)

        defer { timer.invalidate() }
        wait(for: [badgeAppeared], timeout: completeTimeout)

        assertAnalysisTimelineAbsent(onRow: 0, in: app)
        XCTAssertTrue(
            Self.cleaningBadgeEpisodeOn(in: app).exists,
            "cleaningBadge_episodeOn must appear on row 0 after analysis completes"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["analysisProgress"].exists,
            "retired analysisProgress must not reappear"
        )
    }

    // MARK: - Launch + interaction

    @MainActor
    private func launchTimelineFixtureApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("-UITestFixtureAnalysisTimeline")
        app.launch()

        let episodeList = app.descendants(matching: .any)["episodeList"]
        XCTAssertTrue(episodeList.waitForExistence(timeout: episodeListTimeout))
        return app
    }

    /// Task-023: channel cleaning defaults on; podcast detail no longer exposes the toggle.
    @MainActor
    private func enableChannelCleaning(in app: XCUIApplication) {}

    // MARK: - Queries

    private func assertAnalysisTimelineAbsent(onRow index: Int, in app: XCUIApplication) {
        let cell = app.cells["episodeCell_\(index)"]
        XCTAssertFalse(
            cell.descendants(matching: .any)["analysisTimeline"].exists,
            "analysisTimeline must not exist on episodeCell_\(index)"
        )
        XCTAssertFalse(
            cell.descendants(matching: .any)["Analysis timeline"].exists,
            "Analysis timeline label must not exist on episodeCell_\(index)"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["analysisTimeline"].exists,
            "analysisTimeline must not exist globally"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["Analysis timeline"].exists,
            "Analysis timeline label must not exist globally"
        )
    }

    private static func cleaningBadgeEpisodeOn(in app: XCUIApplication) -> XCUIElement {
        let cell = app.cells["episodeCell_0"]
        let scoped = cell.descendants(matching: .any)["cleaningBadge_episodeOn"]
        if scoped.exists {
            return scoped
        }
        return app.descendants(matching: .any)["cleaningBadge_episodeOn"]
    }
}
