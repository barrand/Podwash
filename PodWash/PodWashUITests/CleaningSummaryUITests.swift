import XCTest
final class CleaningSummaryUITests: XCTestCase {
    func testSummaryAbsentWithoutCache() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestFixtureFeed"]
        app.launch()
        XCTAssertTrue(app.sharedEpisodeRow(at: 0).waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["episodeCleaningSummary_fixture-ep-001"].exists)
    }
    func testSummaryShowsPinnedCountsWhenCached() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestFixtureCleaningSummary"]
        app.launch()
        let summary = app.descendants(matching: .any)["episodeCleaningSummary_fixture-ep-001"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        XCTAssertEqual(summary.value as? String, "profanity:2,ads:2,adMinutes:1.5")
        XCTAssertEqual(summary.label, "Cleaning summary")
    }
}
