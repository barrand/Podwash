//
//  CleaningSummaryUITests.swift
//  PodWashUITests
//
//  Slice 29 — Episode cleaning summary on channel screen (slice-29-ux.md). AC4–AC6.
//  Launch fixtures: -UITestFixtureFeed (AC4 negative),
//  -UITestFixtureCleaningSummary (AC5), -UITestFixtureAnalysisTimeline (AC6).
//  Until FixtureCleaningSummary + row AX contract exist (Engineer), these tests
//  fail at compile or launch — intended TDD red state.
//

import XCTest

final class CleaningSummaryUITests: XCTestCase {

    private static let cleaningSummaryIdentifier = "episode.cleaningSummary"
    private static let pinnedAccessibilityValue = "profanity:2,ads:2,adMinutes:1.5"
    private let episodeListTimeout: TimeInterval = 10
    private let summaryAbsentTimeout: TimeInterval = 2
    private let summaryPresentTimeout: TimeInterval = 5
    private let inFlightAbsentTimeout: TimeInterval = 2

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - AC4

    @MainActor
    func testSummaryAbsentWithoutCache() throws {
        let app = launchFeedFixtureApp()
        let episodeList = app.descendants(matching: .any)["episodeList"]
        XCTAssertTrue(episodeList.waitForExistence(timeout: episodeListTimeout))

        let absentDeadline = Date().addingTimeInterval(summaryAbsentTimeout)
        while Date() < absentDeadline {
            assertCleaningSummaryAbsent(onRow: 0, in: app)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        assertCleaningSummaryAbsent(onRow: 0, in: app)
    }

    // MARK: - AC5

    @MainActor
    func testSummaryShowsPinnedCountsWhenCached() throws {
        let app = launchCleaningSummaryFixtureApp()
        let episodeList = app.descendants(matching: .any)["episodeList"]
        XCTAssertTrue(episodeList.waitForExistence(timeout: episodeListTimeout))

        let summary = cleaningSummaryElement(onRow: 0, in: app)
        XCTAssertTrue(
            summary.waitForExistence(timeout: summaryPresentTimeout),
            "\(Self.cleaningSummaryIdentifier) must appear within \(summaryPresentTimeout)s"
        )

        XCTAssertEqual(
            accessibilityValue(of: summary),
            Self.pinnedAccessibilityValue,
            "episode.cleaningSummary accessibilityValue"
        )
        XCTAssertEqual(summary.label, "Cleaning summary")
    }

    // MARK: - AC6

    @MainActor
    func testSummaryHiddenWhileTimelineInFlight() throws {
        let app = launchTimelineFixtureApp()
        let episodeList = app.descendants(matching: .any)["episodeList"]
        XCTAssertTrue(episodeList.waitForExistence(timeout: episodeListTimeout))

        startAnalysisIfNeeded(in: app)

        let inFlightDeadline = Date().addingTimeInterval(inFlightAbsentTimeout)
        while Date() < inFlightDeadline {
            assertAnalysisTimelineAbsent(onRow: 0, in: app)
            assertCleaningSummaryAbsent(onRow: 0, in: app)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        assertAnalysisTimelineAbsent(onRow: 0, in: app)
        assertCleaningSummaryAbsent(onRow: 0, in: app)
    }

    // MARK: - Launch

    @MainActor
    private func launchFeedFixtureApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("-UITestFixtureFeed")
        app.launch()
        return app
    }

    @MainActor
    private func launchCleaningSummaryFixtureApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("-UITestFixtureCleaningSummary")
        app.launch()
        return app
    }

    @MainActor
    private func launchTimelineFixtureApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("-UITestFixtureAnalysisTimeline")
        app.launch()
        return app
    }

    // MARK: - Interaction

    /// Channel cleaning defaults on for timeline fixture (task-023); tap episode toggle when present.
    @MainActor
    private func startAnalysisIfNeeded(in app: XCUIApplication) {
        let episodeToggle = app.switches["episodeCleaningToggle_0"]
        if episodeToggle.waitForExistence(timeout: 1) {
            episodeToggle.tap()
        }
    }

    // MARK: - Queries

    private func cleaningSummaryElement(onRow index: Int, in app: XCUIApplication) -> XCUIElement {
        let cell = app.cells["episodeCell_\(index)"]
        let scoped = cell.descendants(matching: .any)[Self.cleaningSummaryIdentifier]
        if scoped.exists {
            return scoped
        }
        return app.descendants(matching: .any)[Self.cleaningSummaryIdentifier]
    }

    private func assertCleaningSummaryAbsent(onRow index: Int, in app: XCUIApplication) {
        let cell = app.cells["episodeCell_\(index)"]
        XCTAssertFalse(
            cell.descendants(matching: .any)[Self.cleaningSummaryIdentifier].exists,
            "\(Self.cleaningSummaryIdentifier) must not exist on episodeCell_\(index)"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)[Self.cleaningSummaryIdentifier].exists,
            "\(Self.cleaningSummaryIdentifier) must not exist globally"
        )
    }

    private func accessibilityValue(of element: XCUIElement) -> String? {
        if let string = element.value as? String {
            return string
        }
        if let nsString = element.value as? NSString {
            return nsString as String
        }
        return nil
    }

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
}
