//
//  EpisodeListUITests.swift
//  PodWashUITests
//
//  Slice 06 — Episode list UI tests (slice-06-ux.md). AC4.
//

import XCTest

final class EpisodeListUITests: XCTestCase {

    // Hand-transcribed from sample_feed_expected.json (independent golden; not parser output).
    private let goldenChannelTitle = "PodWash Fixture Feed"
    private let goldenEpisodeCount = "5"
    private let goldenTitles = [
        "Alpha Signal — Pilot Launch",
        "Beta Notes — Listener Mail",
        "Gamma Graph — Data Deep Dive",
    ]
    private let goldenFirstEpisodePubDate = "2026-01-15T08:00:00Z"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEpisodeListRendersFixtureTitles() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-UITestFixtureFeed")
        app.launch()

        let episodeList = app.descendants(matching: .any)["episodeList"]
        XCTAssertTrue(episodeList.waitForExistence(timeout: 10))

        XCTAssertFalse(app.descendants(matching: .any)["feed.loading"].exists)

        XCTAssertEqual(episodeList.value as? String, goldenEpisodeCount)

        let podcastTitle = app.descendants(matching: .any)["podcastTitle"]
        XCTAssertTrue(podcastTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(podcastTitle.value as? String, goldenChannelTitle)

        for (index, expectedTitle) in goldenTitles.enumerated() {
            let cell = app.cells["episodeCell_\(index)"]
            XCTAssertTrue(cell.waitForExistence(timeout: 5), "episodeCell_\(index) missing")
            XCTAssertEqual(cell.label, expectedTitle)
        }

        let firstCell = app.cells["episodeCell_0"]
        XCTAssertEqual(firstCell.value as? String, goldenFirstEpisodePubDate)
    }
}
