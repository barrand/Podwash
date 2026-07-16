//
//  AnalysisProgressUITests.swift
//  PodWashUITests
//
//  Slice 09 — Analysis progress + cleaning toggle UI tests (slice-09-ux.md). AC2, AC3.
//  Slice 20 — migrated `analysisProgress` → `analysisTimeline` (ADR-018).
//  Task 026 — row `analysisTimeline` retired; lifecycle asserts absence on episode rows.
//

import XCTest

final class AnalysisProgressUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testChannelDetailCleaningTogglesAbsent() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-UITestFixtureLibrary")
        app.launch()

        navigateLibraryFixtureToEpisodeList(in: app)

        let channelCleaningToggle = app.switches["channelCleaningToggle"]
        let channelUnrelatedToggle = app.switches["channelUnrelatedContentToggle"]
        let cleaningCaption = app.staticTexts["channelCleaningCaption"]

        XCTAssertFalse(
            channelCleaningToggle.waitForExistence(timeout: 5),
            "channelCleaningToggle must not appear on podcast detail within 5s"
        )
        XCTAssertFalse(
            channelUnrelatedToggle.waitForExistence(timeout: 5),
            "channelUnrelatedContentToggle must not appear on podcast detail within 5s"
        )
        XCTAssertFalse(
            cleaningCaption.waitForExistence(timeout: 5),
            "channelCleaningCaption must not appear on podcast detail within 5s"
        )
        XCTAssertFalse(channelCleaningToggle.exists)
        XCTAssertFalse(channelUnrelatedToggle.exists)
        XCTAssertFalse(cleaningCaption.exists)
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
        XCTAssertFalse(app.switches["channelCleaningToggle"].exists)
        XCTAssertFalse(app.switches["channelUnrelatedContentToggle"].exists)
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
        XCTAssertFalse(app.switches["channelCleaningToggle"].exists)

        // Channel cleaning defaults on (task-023); badges stay hidden with no per-episode toggles.
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

        let episodeCell = app.cells["episodeCell_0"]
        XCTAssertTrue(episodeCell.waitForExistence(timeout: 5))

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

        defer { timer.invalidate() }

        let analyzingDeadline = Date().addingTimeInterval(5)
        while Date() < analyzingDeadline, !sawBadge {
            XCTAssertFalse(
                Self.analysisTimelineElement(in: app, cell: episodeCell).exists,
                "analysisTimeline must stay absent on episode row 0 during analysis"
            )
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        wait(for: [badgeAppeared], timeout: 5)

        XCTAssertFalse(
            Self.analysisTimelineElement(in: app, cell: episodeCell).exists,
            "analysisTimeline must not exist on episode row 0 after analysis completes"
        )
        XCTAssertFalse(app.descendants(matching: .any)["analysisProgress"].exists)
        XCTAssertTrue(
            Self.cleaningBadgeEpisodeOn(in: app).exists,
            "cleaningBadge_episodeOn must appear on row 0 after analysis completes"
        )
    }

    @MainActor
    private func navigateLibraryFixtureToEpisodeList(in app: XCUIApplication) {
        let libraryRoot = app.descendants(matching: .any)["libraryRoot"]
        XCTAssertTrue(libraryRoot.waitForExistence(timeout: 5), "libraryRoot must appear within 5s")

        let showCell = app.descendants(matching: .any)["libraryCell_0"]
        XCTAssertTrue(showCell.waitForExistence(timeout: 5), "libraryCell_0 must appear within 5s")
        showCell.tap()

        let episodeList = app.descendants(matching: .any)["episodeList"]
        XCTAssertTrue(episodeList.waitForExistence(timeout: 5), "episodeList must appear within 5s")
    }

    private static func cleaningBadgeEpisodeOn(in app: XCUIApplication) -> XCUIElement {
        let cell = app.cells["episodeCell_0"]
        let scoped = cell.descendants(matching: .any)["cleaningBadge_episodeOn"]
        if scoped.exists {
            return scoped
        }
        return app.descendants(matching: .any)["cleaningBadge_episodeOn"]
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
