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

    /// Play-time analysis in Library shell — stepped analyzer pinned to terminal
    /// `ready:12,processing:0,pending:0` (parallel to `-UITestFixtureAnalysisTimeline`).
    private let libraryPlayerAnalysisTimelineArgs = [
        "-UITestFixtureDownload",
        "-UITestFixtureLibraryAnalysisTimeline",
    ]

    /// Mini-player timeline — unchanged by slice-27 (mute markers are full-player only).
    private static let terminalTimelineValue = "ready:12,processing:0,pending:0"
    /// Full-player super seek bar terminal for library analysis fixture (0 profanity mutes).
    private static let terminalSuperSeekBarValue = "ready:12,processing:0,pending:0,muteMarkers:0"
    private static let timelineValuePattern = try! NSRegularExpression(
        pattern: #"^ready:(\d+),processing:(\d+),pending:(\d+)$"#
    )

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Launch helpers

    private func launchLibraryApp(
        empty: Bool = false,
        extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append(empty ? "-UITestFixtureLibraryEmpty" : "-UITestFixtureLibrary")
        app.launchArguments.append(contentsOf: extraArguments)
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

    private func playFirstEpisodeWithChannelCleaningOn(_ app: XCUIApplication) {
        navigateToEpisodeList(app)
        ensureChannelCleaningOn(in: app)

        let downloadButton = app.buttons["downloadButton_0"]
        XCTAssertTrue(downloadButton.waitForExistence(timeout: fixtureTimeout))

        let episodeCell = element("episodeCell_0", in: app)
        XCTAssertTrue(episodeCell.waitForExistence(timeout: fixtureTimeout))
        episodeCell.tap()

        if downloadButton.value as? String != "downloaded" {
            waitForAccessibilityValue(
                "downloaded",
                identifier: "downloadButton_0",
                in: app,
                timeout: fixtureTimeout,
                message: "downloadButton_0 must report downloaded before play-time analysis starts"
            )
        }

        let miniPlayer = element("miniPlayer", in: app)
        XCTAssertTrue(
            miniPlayer.waitForExistence(timeout: fixtureTimeout),
            "miniPlayer must appear within \(fixtureTimeout)s after downloaded local play starts"
        )
    }

    @discardableResult
    private func waitForPlayerAnalysisTimeline(
        identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> String {
        let control = element(identifier, in: app)
        XCTAssertTrue(
            control.waitForExistence(timeout: timeout),
            "\(identifier) must appear within \(timeout)s"
        )

        let terminalSnapshot = expectation(description: "terminal \(identifier) snapshot")
        terminalSnapshot.assertForOverFulfill = false

        var resolved = ""
        var sawTerminal = false
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            guard control.exists, let value = control.value as? String else { return }
            guard Self.isValidTimelineAccessibilityValue(value) else { return }
            guard value == Self.terminalTimelineValue else { return }
            sawTerminal = true
            resolved = value
            timer.invalidate()
            terminalSnapshot.fulfill()
        }
        RunLoop.current.add(timer, forMode: .common)

        defer { timer.invalidate() }
        wait(for: [terminalSnapshot], timeout: timeout)

        XCTAssertTrue(
            sawTerminal,
            "\(identifier) must reach terminal analysis snapshot within \(timeout)s; last value: \(control.value as? String ?? "nil")"
        )
        return resolved
    }

    private static func isValidTimelineAccessibilityValue(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..., in: value)
        guard let match = timelineValuePattern.firstMatch(in: value, range: range),
              match.numberOfRanges == 4,
              let readyRange = Range(match.range(at: 1), in: value),
              let processingRange = Range(match.range(at: 2), in: value),
              let pendingRange = Range(match.range(at: 3), in: value),
              let ready = Int(value[readyRange]),
              let processing = Int(value[processingRange]),
              let pending = Int(value[pendingRange])
        else {
            return false
        }
        return ready + processing + pending == 12
    }

    private static func segmentTriple(from value: String) -> (Int, Int, Int)? {
        let segmentPart = value.split(separator: ",").filter { !$0.hasPrefix("muteMarkers:") }
        guard segmentPart.count == 3 else { return nil }
        func parse(_ s: Substring, prefix: String) -> Int? {
            guard s.hasPrefix(prefix), let v = Int(s.dropFirst(prefix.count)) else { return nil }
            return v
        }
        guard let r = parse(segmentPart[0], prefix: "ready:"),
              let p = parse(segmentPart[1], prefix: "processing:"),
              let n = parse(segmentPart[2], prefix: "pending:")
        else { return nil }
        return (r, p, n)
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
        // Mini-player play/pause contract only (task-012). Fixture library mode plays
        // bundled FixtureAudio; Clean Profanity stays off so this test does not overlap
        // testTapEpisodeDownloadsBeforePlayWhenChannelCleaningOn.
        let app = launchLibraryApp()
        navigateToEpisodeList(app)
        ensureChannelCleaningOff(in: app)

        let episodeCell = element("episodeCell_0", in: app)
        XCTAssertTrue(episodeCell.waitForExistence(timeout: fixtureTimeout))
        episodeCell.tap()

        let miniPlayer = element("miniPlayer", in: app)
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: fixtureTimeout), "miniPlayer must appear within \(fixtureTimeout)s")

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

    // MARK: - Task 012: tap episode downloads before play when Clean Profanity on

    @MainActor
    func testTapEpisodeDownloadsBeforePlayWhenChannelCleaningOn() throws {
        let app = launchLibraryApp(extraArguments: ["-UITestFixtureDownload"])
        navigateToEpisodeList(app)
        ensureChannelCleaningOn(in: app)

        let downloadButton = app.buttons["downloadButton_0"]
        XCTAssertTrue(downloadButton.waitForExistence(timeout: fixtureTimeout))
        XCTAssertEqual(downloadButton.value as? String, "notDownloaded")

        let episodeCell = element("episodeCell_0", in: app)
        XCTAssertTrue(episodeCell.waitForExistence(timeout: fixtureTimeout))

        let playPause = element("miniPlayerPlayPause", in: app)
        XCTAssertFalse(playPause.exists, "mini-player must not appear before download completes")

        episodeCell.tap()

        assertDownloadingStarted(
            downloadButton: downloadButton,
            progressIdentifier: "downloadProgress_0",
            in: app,
            timeout: 2
        )
        XCTAssertNotEqual(
            playPause.value as? String,
            "playing",
            "Engine must not report playing from a stream before the episode is downloaded"
        )

        waitForAccessibilityValue(
            "downloaded",
            identifier: "downloadButton_0",
            in: app,
            timeout: fixtureTimeout,
            message: "downloadButton_0 must report downloaded after tap-to-play download completes"
        )

        let miniPlayer = element("miniPlayer", in: app)
        XCTAssertTrue(
            miniPlayer.waitForExistence(timeout: fixtureTimeout),
            "miniPlayer must appear after downloaded local play session starts"
        )

        XCTAssertTrue(playPause.waitForExistence(timeout: fixtureTimeout))
        playPause.tap()

        waitForAccessibilityValue(
            "playing",
            identifier: "miniPlayerPlayPause",
            in: app,
            timeout: fixtureTimeout,
            message: "miniPlayerPlayPause must report playing within \(fixtureTimeout)s after download"
        )
    }

    // MARK: - Task 011: analysis timeline in mini and full player

    @MainActor
    func testMiniPlayerShowsAnalysisTimelineWhenAnalysisComplete() throws {
        let app = launchLibraryApp(extraArguments: libraryPlayerAnalysisTimelineArgs)
        playFirstEpisodeWithChannelCleaningOn(app)

        let value = waitForPlayerAnalysisTimeline(
            identifier: "miniPlayerAnalysisTimeline",
            in: app,
            timeout: fixtureTimeout
        )
        XCTAssertTrue(
            Self.isValidTimelineAccessibilityValue(value),
            "miniPlayerAnalysisTimeline accessibilityValue must match ready/processing/pending with segment sum 12; got: \(value)"
        )
        XCTAssertEqual(
            value,
            Self.terminalTimelineValue,
            "Fixture must pin terminal complete analysis for player chrome"
        )
    }

    @MainActor
    func testFullPlayerShowsMatchingAnalysisTimeline() throws {
        let app = launchLibraryApp(extraArguments: libraryPlayerAnalysisTimelineArgs)
        playFirstEpisodeWithChannelCleaningOn(app)

        let miniValue = waitForPlayerAnalysisTimeline(
            identifier: "miniPlayerAnalysisTimeline",
            in: app,
            timeout: fixtureTimeout
        )

        tapMiniPlayerBar(app)

        let superSeekBar = element("playback.superSeekBar", in: app)
        XCTAssertTrue(
            superSeekBar.waitForExistence(timeout: fixtureTimeout),
            "playback.superSeekBar must appear within \(fixtureTimeout)s after expanding mini-player"
        )
        waitForAccessibilityValue(
            Self.terminalSuperSeekBarValue,
            identifier: "playback.superSeekBar",
            in: app,
            timeout: fixtureTimeout,
            message: "playback.superSeekBar must expose terminal segment triple plus muteMarkers:0"
        )
        if let superValue = element("playback.superSeekBar", in: app).value as? String {
            // 3-element tuples are not Equatable; assert components (Swift arity limit).
            let superTriple = Self.segmentTriple(from: superValue)
            let miniTriple = Self.segmentTriple(from: miniValue)
            XCTAssertEqual(superTriple?.0, miniTriple?.0, "Super seek bar ready must match mini-player")
            XCTAssertEqual(superTriple?.1, miniTriple?.1, "Super seek bar processing must match mini-player")
            XCTAssertEqual(superTriple?.2, miniTriple?.2, "Super seek bar pending must match mini-player")
        }
        XCTAssertFalse(
            element("playbackAnalysisTimeline", in: app).exists,
            "Retired playbackAnalysisTimeline must not appear after slice-25 migration"
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

    private func ensureChannelCleaningOff(in app: XCUIApplication) {
        let channelToggle = app.switches["channelCleaningToggle"]
        guard channelToggle.waitForExistence(timeout: fixtureTimeout) else { return }
        guard (channelToggle.value as? String) == "on" else { return }
        channelToggle.tap()
        waitForSwitchValue("off", switch: channelToggle, timeout: fixtureTimeout)
    }

    private func ensureChannelCleaningOn(in app: XCUIApplication) {
        // Task-023: channel cleaning defaults on; podcast detail no longer exposes the toggle.
    }

    private func waitForSwitchValue(_ expected: String, switch control: XCUIElement, timeout: TimeInterval) {
        let predicate = NSPredicate(format: "value == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: control)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "channelCleaningToggle must report \(expected) within \(timeout)s")
        XCTAssertEqual(control.value as? String, expected)
    }

    private func assertDownloadingStarted(
        downloadButton: XCUIElement,
        progressIdentifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) {
        let progress = element(progressIdentifier, in: app)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if progress.exists {
                return
            }
            // Re-resolve by id each poll — cached XCUIElement values can miss a short
            // `downloading` window under verify load (task-012 / ui_race).
            let liveButton = app.buttons["downloadButton_0"]
            if liveButton.exists, liveButton.value as? String == "downloading" {
                return
            }
            if downloadButton.value as? String == "downloading" {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail(
            "Expected \(progressIdentifier) or downloadButton_0 accessibilityValue == downloading within \(timeout)s"
        )
    }
}
