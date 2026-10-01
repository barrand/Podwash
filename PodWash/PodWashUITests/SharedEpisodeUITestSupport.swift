import XCTest

extension XCUIApplication {
    /// Independent golden fixture identities; never infer a row identity from
    /// its current table index or from implementation output.
    func sharedEpisodeID(at row: Int) -> String {
        let suffix = String(format: "fixture-ep-%03d", row % 5 + 1)
        if launchArguments.contains("-UITestFixtureLibraryLongEpisodes") {
            return "lib-0-long-\(row)-\(suffix)"
        }
        let library = launchArguments.contains { $0.contains("Library") || $0.contains("Transcript")
            || $0.contains("MuteMarkers") || $0.contains("PrerollAdBands") || $0.contains("NowPlayingSession") }
        return library ? "lib-0-\(suffix)" : suffix
    }

    func sharedEpisodeRow(at row: Int) -> XCUIElement {
        descendants(matching: .any).matching(identifier: "episodeRow_\(sharedEpisodeID(at: row))").firstMatch
    }

    func prepareSharedEpisode(at row: Int, timeout: TimeInterval = 20) {
        let primary = buttons["episodePrimary_\(sharedEpisodeID(at: row))"]
        XCTAssertTrue(primary.waitForExistence(timeout: timeout))
        if primary.label != "Play" {
            primary.tap()
            let decline = buttons["cloudConsentDeclineButton"]
            if decline.waitForExistence(timeout: 1) { decline.tap() }
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", "Play"), object: primary)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed)
        }
    }

    func playSharedEpisode(at row: Int) {
        prepareSharedEpisode(at: row)
        buttons["episodePrimary_\(sharedEpisodeID(at: row))"].tap()
    }

    func openSharedEpisodeMenu(at row: Int) {
        let more = buttons["episodeMore_\(sharedEpisodeID(at: row))"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
    }

    func performSharedEpisodeAction(_ action: String, at row: Int) {
        openSharedEpisodeMenu(at: row)
        let item = buttons["episodeMenu_\(action)_\(sharedEpisodeID(at: row))"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
    }
}
