import XCTest
final class AnalysisProgressUITests: XCTestCase {
    func testExplicitPreparationReachesReadyWithoutPlaybackOrOldToggleChrome() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-UITestFixtureFeed", "-UITestFixtureAnalysis", "-UITestFixtureDownload"]
        app.launch()
        XCTAssertTrue(app.sharedEpisodeRow(at: 0).waitForExistence(timeout: 10))
        XCTAssertFalse(app.switches["channelCleaningToggle"].exists)
        XCTAssertFalse(app.switches["episodeCleaningToggle_0"].exists)
        app.prepareSharedEpisode(at: 0)
        XCTAssertEqual(app.buttons["episodePrimary_fixture-ep-001"].label, "Play")
        XCTAssertFalse(app.descendants(matching: .any)["miniPlayer"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["analysisTimeline"].exists)
    }
}
