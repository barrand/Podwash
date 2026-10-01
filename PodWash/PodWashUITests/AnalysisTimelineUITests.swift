import XCTest
final class AnalysisTimelineUITests: XCTestCase {
    func testSharedRowShowsOneTruthfulReadinessStatusAndNoAnalysisTimeline() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-UITestFixtureAnalysisTimeline", "-UITestFixtureDownload"]
        app.launch()
        XCTAssertTrue(app.sharedEpisodeRow(at: 0).waitForExistence(timeout: 10))
        app.prepareSharedEpisode(at: 0)
        XCTAssertEqual(app.descendants(matching: .any)["episodeStatus_fixture-ep-001"].firstMatch.label, "Ready to play offline")
        XCTAssertFalse(app.descendants(matching: .any)["analysisTimeline"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["miniPlayer"].exists)
    }
}
