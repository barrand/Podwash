//
//  TranscriptUITests.swift
//  PodWashUITests
//
//  Slice 26 — Episode transcript viewer UI tests (slice-26-ux.md). AC4–AC9.
//  Launch fixtures: -UITestFixtureTranscript (AC4–AC8),
//  -UITestFixtureTranscriptNoCache (AC7 negative), -UITestFixtureProgressivePlayback (AC9).
//  Until FixtureTranscript + transcript accessibility contract exist (Engineer),
//  these tests fail at compile or launch — intended TDD red state.
//

import XCTest

final class TranscriptUITests: XCTestCase {

    private let libraryRootTimeout: TimeInterval = 10
    private let fixtureTimeout: TimeInterval = 5
    private let transcriptOpenTimeout: TimeInterval = 3
    private let progressiveTimelineTimeout: TimeInterval = 5
    private let backfillAffordanceTimeout: TimeInterval = 10

    private static let transcriptFixtureArg = "-UITestFixtureTranscript"
    private static let transcriptNoCacheArg = "-UITestFixtureTranscriptNoCache"
    private static let progressiveFixtureArg = "-UITestFixtureProgressivePlayback"
    private static let firstChunkTimelineValue = "ready:3,processing:1,pending:8"

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: - AC4

    @MainActor
    func testEpisodeRowOpensTranscriptWithCounts() throws {
        let app = launchTranscriptFixtureApp()
        navigateToEpisodeList(app)

        tapEpisodeViewTranscript(onRow: 0, in: app)

        let transcriptView = element("transcript.view", in: app)
        XCTAssertTrue(
            transcriptView.waitForExistence(timeout: transcriptOpenTimeout),
            "transcript.view must appear within \(transcriptOpenTimeout)s"
        )

        XCTAssertEqual(
            accessibilityValue(for: "transcript.wordCount", in: app),
            "24",
            "transcript.wordCount accessibilityValue"
        )
        XCTAssertEqual(
            accessibilityValue(for: "transcript.listenedCount", in: app),
            "12",
            "transcript.listenedCount accessibilityValue"
        )
    }

    // MARK: - AC5

    @MainActor
    func testTranscriptShowsSkippedAdCount() throws {
        let app = launchTranscriptFixtureApp()
        openTranscriptFromEpisodeRow(app)

        XCTAssertEqual(
            accessibilityValue(for: "transcript.skippedAdCount", in: app),
            "3",
            "transcript.skippedAdCount accessibilityValue"
        )
    }

    // MARK: - AC6

    @MainActor
    func testFullPlayerOpensSameTranscript() throws {
        let app = launchTranscriptFixtureApp()
        navigateToExpandedFullPlayer(app)

        let viewTranscript = element("playback.viewTranscript", in: app)
        XCTAssertTrue(viewTranscript.waitForExistence(timeout: fixtureTimeout))
        viewTranscript.tap()

        let transcriptView = element("transcript.view", in: app)
        XCTAssertTrue(
            transcriptView.waitForExistence(timeout: transcriptOpenTimeout),
            "transcript.view must appear within \(transcriptOpenTimeout)s from full player"
        )
        XCTAssertEqual(
            accessibilityValue(for: "transcript.wordCount", in: app),
            "24",
            "transcript.wordCount accessibilityValue from full player entry"
        )
    }

    // MARK: - AC7

    @MainActor
    func testTranscriptAffordanceHiddenWithoutCache() throws {
        let app = launchTranscriptFixtureApp(includeTranscriptCache: false)
        navigateToEpisodeList(app)

        assertTranscriptAffordanceAbsent("episode.viewTranscript", scopedToRow: 0, in: app)

        // Expand full player (mini bar → sheet) before asserting player affordance —
        // `playback.playPause` / `playback.viewTranscript` live on the expanded sheet.
        let episodeCell = app.cells["episodeCell_0"]
        XCTAssertTrue(episodeCell.waitForExistence(timeout: fixtureTimeout))
        episodeCell.tap()

        let miniPlayer = element("miniPlayer", in: app)
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: fixtureTimeout))
        miniPlayer.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()

        let fullPlayPause = element("playback.playPause", in: app)
        XCTAssertTrue(fullPlayPause.waitForExistence(timeout: fixtureTimeout))

        assertTranscriptAffordanceAbsent("playback.viewTranscript", scopedToRow: nil, in: app)
    }

    // MARK: - AC8

    @MainActor
    func testTranscriptScrollsNearPlaybackPosition() throws {
        let app = launchTranscriptFixtureApp()
        openTranscriptFromEpisodeRow(app)

        guard let anchorRaw = accessibilityValue(for: "transcript.scrollAnchor", in: app),
              let anchor = Int(anchorRaw) else {
            XCTFail("transcript.scrollAnchor must expose a parseable integer accessibilityValue")
            return
        }

        XCTAssertGreaterThanOrEqual(anchor, 28, "scroll anchor must be ≥ 28 for playbackPosition 30.0")
        XCTAssertLessThanOrEqual(anchor, 32, "scroll anchor must be ≤ 32 for playbackPosition 30.0")
    }

    // MARK: - Task 021

    @MainActor
    func testTranscriptShowsParagraphStartTimestamp() throws {
        let app = launchTranscriptFixtureApp()
        openTranscriptFromEpisodeRow(app)

        let timestamp = element("transcript.paragraph_0.timestamp", in: app)
        XCTAssertTrue(
            timestamp.waitForExistence(timeout: transcriptOpenTimeout),
            "transcript.paragraph_0.timestamp must appear within \(transcriptOpenTimeout)s"
        )
        XCTAssertEqual(
            accessibilityValue(for: "transcript.paragraph_0.timestamp", in: app),
            "0:00",
            "paragraph 0 timestamp must match fixture first-word start (0.0 s)"
        )
    }

    @MainActor
    func testAdjacentTranscriptWordsShareLine() throws {
        let app = launchTranscriptFixtureApp()
        openTranscriptFromEpisodeRow(app)

        let word0 = element("transcript.word_0", in: app)
        let word1 = element("transcript.word_1", in: app)
        XCTAssertTrue(
            word0.waitForExistence(timeout: transcriptOpenTimeout),
            "transcript.word_0 must appear within \(transcriptOpenTimeout)s"
        )
        XCTAssertTrue(
            word1.waitForExistence(timeout: transcriptOpenTimeout),
            "transcript.word_1 must appear within \(transcriptOpenTimeout)s"
        )

        let midYDelta = abs(word0.frame.midY - word1.frame.midY)
        XCTAssertLessThanOrEqual(
            midYDelta,
            8,
            "adjacent words must share a wrapped line (midY delta \(midYDelta) pt)"
        )
    }

    // MARK: - Task 020

    /// Fixture: interval cache seeded, transcript file omitted (`-UITestFixtureTranscriptNoCache`),
    /// cleaning on, local bundled audio. Stable entry: `episode.viewTranscript` on row 0 after
    /// first play/prepare (not full-player `playback.viewTranscript`).
    @MainActor
    func testTranscriptAffordanceAppearsAfterBackfillWhenIntervalsCached() throws {
        let app = launchTranscriptFixtureApp(includeTranscriptCache: false)
        navigateToEpisodeList(app)
        ensureChannelCleaningOn(in: app)

        assertTranscriptAffordanceAbsent("episode.viewTranscript", scopedToRow: 0, in: app)

        let episodeCell = app.cells["episodeCell_0"]
        XCTAssertTrue(episodeCell.waitForExistence(timeout: fixtureTimeout))
        episodeCell.tap()

        let miniPlayer = element("miniPlayer", in: app)
        XCTAssertTrue(
            miniPlayer.waitForExistence(timeout: fixtureTimeout),
            "first play/prepare must surface miniPlayer"
        )

        let viewTranscript = episodeCell.descendants(matching: .any)["episode.viewTranscript"]
        XCTAssertTrue(
            waitForElementHittable(viewTranscript, timeout: backfillAffordanceTimeout),
            "episode.viewTranscript must become hittable within \(backfillAffordanceTimeout)s after backfill"
        )
    }

    // MARK: - AC9

    @MainActor
    func testTranscriptHiddenDuringProgressiveAnalysis() throws {
        let app = launchProgressiveFixtureApp()
        navigateToEpisodeList(app)
        ensureChannelCleaningOn(in: app)

        let episodeCell = app.cells["episodeCell_0"]
        XCTAssertTrue(episodeCell.waitForExistence(timeout: fixtureTimeout))
        episodeCell.tap()

        let miniPlayer = element("miniPlayer", in: app)
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: fixtureTimeout))
        miniPlayer.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()

        let playPause = element("playback.playPause", in: app)
        XCTAssertTrue(playPause.waitForExistence(timeout: fixtureTimeout))
        if accessibilityValue(for: "playback.playPause", in: app) != "playing" {
            playPause.tap()
        }

        waitForSuperSeekBarValue(Self.firstChunkTimelineValue, in: app, timeout: progressiveTimelineTimeout)

        assertTranscriptAffordanceAbsent("episode.viewTranscript", scopedToRow: 0, in: app)
    }

    // MARK: - Launch helpers

    @MainActor
    private func launchTranscriptFixtureApp(includeTranscriptCache: Bool = true) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments.append(Self.transcriptFixtureArg)
        if !includeTranscriptCache {
            app.launchArguments.append(Self.transcriptNoCacheArg)
        }
        app.launch()
        return app
    }

    @MainActor
    private func launchProgressiveFixtureApp() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments.append(Self.progressiveFixtureArg)
        app.launch()
        return app
    }

    // MARK: - Navigation helpers (slice-26-ux.md)

    @MainActor
    private func navigateToEpisodeList(_ app: XCUIApplication) {
        let root = element("libraryRoot", in: app)
        XCTAssertTrue(
            root.waitForExistence(timeout: libraryRootTimeout),
            "libraryRoot must appear within \(libraryRootTimeout)s"
        )

        let showCell = element("libraryCell_0", in: app)
        XCTAssertTrue(showCell.waitForExistence(timeout: fixtureTimeout))
        showCell.tap()

        let episodeList = element("episodeList", in: app)
        XCTAssertTrue(
            episodeList.waitForExistence(timeout: fixtureTimeout),
            "episodeList must appear within \(fixtureTimeout)s"
        )
    }

    @MainActor
    private func openTranscriptFromEpisodeRow(_ app: XCUIApplication) {
        navigateToEpisodeList(app)
        tapEpisodeViewTranscript(onRow: 0, in: app)

        let transcriptView = element("transcript.view", in: app)
        XCTAssertTrue(
            transcriptView.waitForExistence(timeout: transcriptOpenTimeout),
            "transcript.view must appear within \(transcriptOpenTimeout)s"
        )
    }

    @MainActor
    private func navigateToExpandedFullPlayer(_ app: XCUIApplication) {
        navigateToEpisodeList(app)

        // Prefer `app.cells` over descendants(.any) — slice-06-ux / slice-26-ux.
        // A descendants query can match more than one node if identifiers collide.
        let episodeCell = app.cells["episodeCell_0"]
        XCTAssertTrue(episodeCell.waitForExistence(timeout: fixtureTimeout))
        episodeCell.tap()

        let miniPlayer = element("miniPlayer", in: app)
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: fixtureTimeout))
        miniPlayer.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()

        let fullPlayPause = element("playback.playPause", in: app)
        XCTAssertTrue(fullPlayPause.waitForExistence(timeout: fixtureTimeout))
    }

    @MainActor
    private func tapEpisodeViewTranscript(onRow row: Int, in app: XCUIApplication) {
        let cell = app.cells["episodeCell_\(row)"]
        XCTAssertTrue(cell.waitForExistence(timeout: fixtureTimeout))

        let button = cell.descendants(matching: .any)["episode.viewTranscript"]
        XCTAssertTrue(button.waitForExistence(timeout: fixtureTimeout), "episode.viewTranscript must exist on row \(row)")
        button.tap()
    }

    @MainActor
    private func assertTranscriptAffordanceAbsent(
        _ identifier: String,
        scopedToRow row: Int?,
        in app: XCUIApplication
    ) {
        let control: XCUIElement
        if let row {
            control = app.cells["episodeCell_\(row)"].descendants(matching: .any)[identifier]
        } else {
            control = element(identifier, in: app)
        }

        if control.exists {
            XCTAssertFalse(
                control.isHittable,
                "\(identifier) must not be hittable when no complete transcript is cached"
            )
        }
    }

    @MainActor
    private func ensureChannelCleaningOn(in app: XCUIApplication) {
        // Task-023: channel cleaning defaults on; podcast detail no longer exposes the toggle.
    }

    @MainActor
    private func waitForElementHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.isHittable { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return element.exists && element.isHittable
    }

    @MainActor
    private func waitForSuperSeekBarValue(
        _ expected: String,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) {
        let match = expectation(description: "superSeekBar \(expected)")
        match.assertForOverFulfill = false

        var saw = false
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            guard !saw,
                  Self.accessibilityValue(for: "playback.superSeekBar", in: app) == expected
            else { return }
            saw = true
            timer.invalidate()
            match.fulfill()
        }
        RunLoop.current.add(timer, forMode: .common)
        defer { timer.invalidate() }
        wait(for: [match], timeout: timeout)
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func accessibilityValue(for identifier: String, in app: XCUIApplication) -> String? {
        Self.accessibilityValue(for: identifier, in: app)
    }

    private static func accessibilityValue(for identifier: String, in app: XCUIApplication) -> String? {
        let control = app.descendants(matching: .any)[identifier]
        guard control.exists else { return nil }
        if let string = control.value as? String { return string }
        if let nsString = control.value as? NSString { return nsString as String }
        return nil
    }
}
