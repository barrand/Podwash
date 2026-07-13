//
//  LibraryUITests.swift
//  PodWashUITests
//
//  Slice 23 — Library & player shell UI tests (slice-23-ux.md). AC2–AC7.
//
//  Golden titles hand-transcribed from Fixtures/itunes/itunes_popular_response.json
//  (independent provenance). Launch with -UITestFixtureLibrary / -UITestFixtureLibraryEmpty
//  only — no -UITestFixtureFeed, -UITestFixtureAudio, or -UITestFixtureDiscover.
//  Until FixtureLibrary + AppShellView exist (Engineer), these tests fail at runtime.
//

import XCTest

final class LibraryUITests: XCTestCase {

    // Hand-transcribed from itunes_popular_response.json entries 0–1 (independent golden).
    private let goldenTitle0 = "Fixture Popular Alpha"
    private let goldenTitle1 = "Fixture Popular Beta"

    private let fixtureTimeout: TimeInterval = 5

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Launch helpers

    private func launchLibraryApp(empty: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append(empty ? "-UITestFixtureLibraryEmpty" : "-UITestFixtureLibrary")
        app.launch()
        return app
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func waitForLibraryRoot(_ app: XCUIApplication, timeout: TimeInterval = 5) {
        let root = element("libraryRoot", in: app)
        XCTAssertTrue(root.waitForExistence(timeout: timeout), "libraryRoot must appear within \(timeout)s")
    }

    private func navigateToEpisodeList(_ app: XCUIApplication) {
        waitForLibraryRoot(app)
        let showCell = element("libraryCell_0", in: app)
        XCTAssertTrue(showCell.waitForExistence(timeout: fixtureTimeout))
        showCell.tap()
        let episodeList = element("episodeList", in: app)
        XCTAssertTrue(episodeList.waitForExistence(timeout: fixtureTimeout), "episodeList must appear within \(fixtureTimeout)s")
    }

    private func playFirstEpisodeAndWaitForMiniPlayer(_ app: XCUIApplication) {
        navigateToEpisodeList(app)
        let episodeCell = element("episodeCell_0", in: app)
        XCTAssertTrue(episodeCell.waitForExistence(timeout: fixtureTimeout))
        episodeCell.tap()
        let miniPlayer = element("miniPlayer", in: app)
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: fixtureTimeout), "miniPlayer must appear within \(fixtureTimeout)s")
    }

    /// Tap bar chrome away from trailing `miniPlayerPlayPause` (slice-23-ux.md AC#4b).
    private func tapMiniPlayerBar(_ app: XCUIApplication) {
        let bar = element("miniPlayer", in: app)
        XCTAssertTrue(bar.waitForExistence(timeout: fixtureTimeout))
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
    }

    private func waitForAccessibilityValue(
        _ expected: String,
        identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval,
        message: String
    ) {
        let control = element(identifier, in: app)
        let predicate = NSPredicate(format: "value == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: control)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, message)
        XCTAssertEqual(control.value as? String, expected)
    }

    // MARK: - AC2: seeded library renders golden titles

    @MainActor
    func testLibraryRendersSeededSubscriptions() throws {
        let app = launchLibraryApp()
        waitForLibraryRoot(app)

        let cell0 = element("libraryCell_0", in: app)
        let cell1 = element("libraryCell_1", in: app)
        XCTAssertTrue(cell0.waitForExistence(timeout: fixtureTimeout))
        XCTAssertTrue(cell1.waitForExistence(timeout: fixtureTimeout))

        XCTAssertTrue(cell0.label.contains(goldenTitle0), "libraryCell_0 label must contain \(goldenTitle0); got: \(cell0.label)")
        XCTAssertTrue(cell1.label.contains(goldenTitle1), "libraryCell_1 label must contain \(goldenTitle1); got: \(cell1.label)")
    }

    // MARK: - AC3: tap show opens episode list

    @MainActor
    func testTapShowOpensEpisodeList() throws {
        let app = launchLibraryApp()
        navigateToEpisodeList(app)

        for index in 0 ..< 3 {
            let cell = element("episodeCell_\(index)", in: app)
            XCTAssertTrue(cell.waitForExistence(timeout: fixtureTimeout), "episodeCell_\(index) missing")
        }
    }

    // MARK: - AC4: episode play surfaces mini-player and plays

    @MainActor
    func testTapEpisodeShowsMiniPlayerAndPlays() throws {
        let app = launchLibraryApp()
        playFirstEpisodeAndWaitForMiniPlayer(app)

        let playPause = element("miniPlayerPlayPause", in: app)
        XCTAssertTrue(playPause.waitForExistence(timeout: fixtureTimeout))
        playPause.tap()

        waitForAccessibilityValue(
            "playing",
            identifier: "miniPlayerPlayPause",
            in: app,
            timeout: fixtureTimeout,
            message: "miniPlayerPlayPause must report playing within \(fixtureTimeout)s"
        )
    }

    // MARK: - AC4b: mini-player expands to full controls

    @MainActor
    func testMiniPlayerExpandsToFullControls() throws {
        let app = launchLibraryApp()
        playFirstEpisodeAndWaitForMiniPlayer(app)

        tapMiniPlayerBar(app)

        let fullPlayPause = element("playback.playPause", in: app)
        XCTAssertTrue(
            fullPlayPause.waitForExistence(timeout: fixtureTimeout),
            "playback.playPause must appear within \(fixtureTimeout)s after expanding mini-player"
        )
    }

    // MARK: - AC5: settings reachable from Library

    @MainActor
    func testSettingsReachableFromLibrary() throws {
        let app = launchLibraryApp()
        waitForLibraryRoot(app)

        // Query as Button — shell mounts a content-tree Button (not toolbar chrome).
        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: fixtureTimeout))

        // Wait for layout to publish a hittable hit target (ui_race on first paint).
        let predicate = NSPredicate(format: "isHittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: settings)
        let result = XCTWaiter().wait(for: [expectation], timeout: fixtureTimeout)
        XCTAssertEqual(result, .completed, "settingsButton must be hittable from Library tab")
        XCTAssertTrue(settings.isHittable, "settingsButton must be hittable from Library tab")
    }

    // MARK: - AC6: Discover tab entry

    @MainActor
    func testDiscoverEntryFromLibrary() throws {
        let app = launchLibraryApp()
        waitForLibraryRoot(app)

        let discoverTab = element("tabDiscover", in: app)
        XCTAssertTrue(discoverTab.waitForExistence(timeout: fixtureTimeout))
        discoverTab.tap()

        let discoverRoot = element("discoverRoot", in: app)
        XCTAssertTrue(discoverRoot.waitForExistence(timeout: fixtureTimeout), "discoverRoot must appear within \(fixtureTimeout)s")
    }

    // MARK: - AC7: empty library prompts Discover navigation

    @MainActor
    func testEmptyLibraryShowsDiscoverPrompt() throws {
        let app = launchLibraryApp(empty: true)
        waitForLibraryRoot(app)

        let emptyState = element("libraryEmptyState", in: app)
        XCTAssertTrue(emptyState.waitForExistence(timeout: fixtureTimeout))
        XCTAssertTrue(
            emptyState.label.contains("Discover"),
            "libraryEmptyState label must contain Discover (case-sensitive); got: \(emptyState.label)"
        )

        let discoverCTA = element("libraryEmptyDiscoverButton", in: app)
        XCTAssertTrue(discoverCTA.waitForExistence(timeout: fixtureTimeout))
        discoverCTA.tap()

        let discoverRoot = element("discoverRoot", in: app)
        XCTAssertTrue(discoverRoot.waitForExistence(timeout: fixtureTimeout), "discoverRoot must appear within \(fixtureTimeout)s")
    }

    // MARK: - Task 010: mini-player must not cover tab bar

    @MainActor
    func testTabsRemainHittableWithMiniPlayerVisible() throws {
        let app = launchLibraryApp()
        playFirstEpisodeAndWaitForMiniPlayer(app)

        let miniPlayer = element("miniPlayer", in: app)
        XCTAssertTrue(miniPlayer.exists, "miniPlayer must remain visible while switching tabs")

        let discoverTab = element("tabDiscover", in: app)
        XCTAssertTrue(discoverTab.waitForExistence(timeout: fixtureTimeout))
        waitForHittable(discoverTab, timeout: fixtureTimeout, message: "tabDiscover must be hittable with miniPlayer visible")
        discoverTab.tap()

        let discoverRoot = element("discoverRoot", in: app)
        XCTAssertTrue(
            discoverRoot.waitForExistence(timeout: fixtureTimeout),
            "discoverRoot must appear within \(fixtureTimeout)s after tapping tabDiscover with miniPlayer visible"
        )

        XCTAssertTrue(miniPlayer.exists, "miniPlayer must remain visible after switching to Discover")

        let libraryTab = element("tabLibrary", in: app)
        XCTAssertTrue(libraryTab.waitForExistence(timeout: fixtureTimeout))
        waitForHittable(libraryTab, timeout: fixtureTimeout, message: "tabLibrary must be hittable with miniPlayer visible")
        libraryTab.tap()

        let libraryRoot = element("libraryRoot", in: app)
        XCTAssertTrue(
            libraryRoot.waitForExistence(timeout: fixtureTimeout),
            "libraryRoot must appear within \(fixtureTimeout)s after tapping tabLibrary with miniPlayer visible"
        )
    }

    @MainActor
    func testMiniPlayerDoesNotOverlapTabBarFrames() throws {
        let app = launchLibraryApp()
        playFirstEpisodeAndWaitForMiniPlayer(app)

        let miniPlayer = element("miniPlayer", in: app)
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: fixtureTimeout))

        for (tabID, tabName) in [("tabDiscover", "tabDiscover"), ("tabLibrary", "tabLibrary")] {
            let tab = element(tabID, in: app)
            XCTAssertTrue(tab.waitForExistence(timeout: fixtureTimeout), "\(tabName) must exist with miniPlayer visible")

            let miniFrame = miniPlayer.frame
            let tabFrame = tab.frame
            XCTAssertFalse(
                miniFrame.intersects(tabFrame),
                "\(tabName) frame must not intersect miniPlayer frame; miniPlayer=\(miniFrame) \(tabName)=\(tabFrame)"
            )
            XCTAssertGreaterThanOrEqual(
                tabFrame.minY,
                miniFrame.maxY,
                "\(tabName) must sit at or below miniPlayer (≥0pt vertical separation); miniPlayer.maxY=\(miniFrame.maxY) \(tabName).minY=\(tabFrame.minY)"
            )
        }
    }

    private func waitForHittable(_ control: XCUIElement, timeout: TimeInterval, message: String) {
        let predicate = NSPredicate(format: "isHittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: control)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, message)
        XCTAssertTrue(control.isHittable, message)
    }
}
