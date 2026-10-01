import XCTest
final class EpisodeListUITests: XCTestCase {
    func testEpisodeListRendersFixtureTitles() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-UITestFixtureFeed"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["episodeList"].waitForExistence(timeout: 10))
        for (row, title) in ["Alpha Signal — Pilot Launch", "Beta Notes — Listener Mail", "Gamma Graph — Data Deep Dive"].enumerated() {
            XCTAssertTrue(app.sharedEpisodeRow(at: row).waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts[title].exists)
            XCTAssertTrue(app.buttons["episodePrimary_\(app.sharedEpisodeID(at: row))"].exists)
            XCTAssertTrue(app.buttons["episodeMore_\(app.sharedEpisodeID(at: row))"].exists)
        }
    }
}
