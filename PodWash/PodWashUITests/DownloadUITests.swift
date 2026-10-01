import XCTest
final class DownloadUITests: XCTestCase {
    func testExplicitDownloadAndMenuRemovalNeverStartPlayback() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-UITestFixtureFeed", "-UITestFixtureDownload"]
        app.launch()
        XCTAssertTrue(app.sharedEpisodeRow(at: 0).waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["episodePrimary_fixture-ep-001"].label, "Download")
        app.prepareSharedEpisode(at: 0)
        XCTAssertFalse(app.descendants(matching: .any)["miniPlayer"].exists)
        app.performSharedEpisodeAction("removeDownload", at: 0)
        let download = app.buttons["episodePrimary_fixture-ep-001"]
        let waiting = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Download"), object: download)
        XCTAssertEqual(XCTWaiter.wait(for: [waiting], timeout: 10), .completed)
        XCTAssertFalse(app.descendants(matching: .any)["miniPlayer"].exists)
    }
}
