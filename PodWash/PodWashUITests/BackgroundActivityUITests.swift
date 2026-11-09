import XCTest

final class BackgroundActivityUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testActivityWithoutPlayerSurvivesTabSwitchAndCollapsesWhenReady() {
        let app = launch()
        beginPreparation(app)
        let status = element("backgroundActivity.status", app)
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("Preparing"))
        XCTAssertFalse(element("miniPlayer", app).exists)
        XCTAssertFalse(element("queueButton", app).exists)

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(status.exists, "Background work must remain visible across tabs")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Activity above tabs — preparing without a player"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        waitForDisappearance(status, timeout: 20)

        app.tabBars.buttons["Library"].tap()
        let primary = app.buttons["episodePrimary_\(app.sharedEpisodeID(at: 0))"]
        XCTAssertEqual(primary.label, "Play")
        primary.tap()
        let player = element("miniPlayer", app)
        XCTAssertTrue(player.waitForExistence(timeout: 5))
        waitForDisappearance(status, timeout: 20)
        XCTAssertTrue(element("miniPlayerPlayPause", app).isHittable)
        let seek = element("miniPlayer.superSeekBar", app)
        XCTAssertTrue(seek.exists)
        for name in ["Library", "Queue", "Discover", "Settings"] {
            let tab = app.tabBars.buttons[name]
            XCTAssertTrue(tab.isHittable)
            XCTAssertGreaterThanOrEqual(tab.frame.minY - seek.frame.maxY, 0)
            XCTAssertLessThanOrEqual(tab.frame.minY - seek.frame.maxY, 16)
        }
        let compact = XCTAttachment(screenshot: app.screenshot())
        compact.name = "Idle mini player — no activity row or reserved gap"
        compact.lifetime = .keepAlways
        add(compact)

        // Prepare another episode while listening: transport remains usable and
        // the activity strip expands above it without touching the tab bar.
        let next = app.buttons["episodePrimary_\(app.sharedEpisodeID(at: 1))"]
        XCTAssertTrue(next.isHittable)
        next.tap()
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(status.frame.maxY, player.frame.minY)
        let playPause = element("miniPlayerPlayPause", app)
        XCTAssertTrue(playPause.isHittable)
        playPause.tap()
        XCTAssertEqual(playPause.value as? String, "paused")
        XCTAssertTrue(status.exists)
        let activePlayer = XCTAttachment(screenshot: app.screenshot())
        activePlayer.name = "Background preparation above a usable mini player"
        activePlayer.lifetime = .keepAlways
        add(activePlayer)
        app.performSharedEpisodeAction("cancelPreparation", at: 1)
        waitForDisappearance(status, timeout: 5)
    }

    @MainActor
    func testCancellingPreparationRemovesActivityImmediately() {
        let app = launch()
        beginPreparation(app)
        let status = element("backgroundActivity.status", app)
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        app.performSharedEpisodeAction("cancelPreparation", at: 0)
        waitForDisappearance(status, timeout: 5)
        XCTAssertFalse(element("miniPlayer", app).exists)
    }

    @MainActor
    func testFailureOpensRecoveryAndCanBeDismissedWithoutLosingIssue() {
        let app = launch(failure: true)
        beginPreparation(app)
        let status = element("backgroundActivity.status", app)
        let failure = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label CONTAINS %@", "needs attention"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [failure], timeout: 8), .completed)
        status.tap()
        XCTAssertTrue(element("preparationIssueSheet", app).waitForExistence(timeout: 5))
        let recovery = XCTAttachment(screenshot: app.screenshot())
        recovery.name = "Activity failure — visible recovery actions"
        recovery.lifetime = .keepAlways
        add(recovery)
        XCTAssertTrue(app.buttons["preparationIssueRetry"].isHittable, app.debugDescription)
        app.buttons["preparationIssueDone"].tap()
        app.buttons["backgroundActivity.dismiss"].tap()
        waitForDisappearance(status, timeout: 3)
        app.performSharedEpisodeAction("viewPreparationIssue", at: 0)
        XCTAssertTrue(element("preparationIssueSheet", app).waitForExistence(timeout: 5),
                      "Dismissing the marquee must preserve recovery in the episode row")
    }

    @MainActor
    private func launch(failure: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestFixtureLibrary", "-UITestFixtureDownload",
                               "-UITestFixtureLibraryAnalysisTimeline", "-UITestFixtureBackgroundActivity"]
        if failure { app.launchArguments.append("-UITestFixtureBackgroundActivityFailure") }
        app.launch()
        let show = element("libraryCell_0", app)
        XCTAssertTrue(show.waitForExistence(timeout: 10))
        show.tap()
        return app
    }

    @MainActor
    private func beginPreparation(_ app: XCUIApplication) {
        let primary = app.buttons["episodePrimary_\(app.sharedEpisodeID(at: 0))"]
        XCTAssertTrue(primary.waitForExistence(timeout: 5))
        primary.tap()
        let decline = app.buttons["cloudConsentDeclineButton"]
        if decline.waitForExistence(timeout: 2) { decline.tap() }
    }

    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: timeout), .completed)
    }
}
