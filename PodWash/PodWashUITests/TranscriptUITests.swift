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
    private let miniPlayerExpandFromTranscriptTimeout: TimeInterval = 5
    private let backfillAffordanceTimeout: TimeInterval = 10

    private static let transcriptFixtureArg = "-UITestFixtureTranscript"
    private static let transcriptNoCacheArg = "-UITestFixtureTranscriptNoCache"
    private static let longFollowFixtureArg = "-UITestFixtureTranscriptLongFollow"
    private static let scrollFollowFixtureArg = "-UITestFixtureTranscriptScrollFollow"

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

    @MainActor
    func testLongTranscriptOpensAtFortyOneMinutePosition() throws {
        let app = launchLongFollowTranscriptFixtureApp()
        openTranscriptFromEpisodeRow(app)

        // 41:00 ÷ 2.5 seconds per word = word 984. This is deliberately far
        // outside the initial lazy viewport, proving the render-block target.
        let expectedWord = element("transcript.word_984", in: app)
        XCTAssertTrue(
            expectedWord.waitForExistence(timeout: transcriptOpenTimeout),
            "opening a long transcript must materialize the live 41-minute word"
        )

        let transcriptView = element("transcript.view", in: app)
        XCTAssertTrue(transcriptView.exists)
        XCTAssertGreaterThanOrEqual(expectedWord.frame.midY, transcriptView.frame.minY)
        XCTAssertLessThanOrEqual(expectedWord.frame.midY, transcriptView.frame.maxY)
    }

    @MainActor
    func testActiveWordHighlightDoesNotChangeWordGeometry() throws {
        let app = launchTranscriptFixtureApp()
        openTranscriptFromEpisodeRow(app)

        // Fixture resume is 30.0 s, which is word 12's half-open interval.
        let previousWord = element("transcript.word_11", in: app)
        let activeWord = element("transcript.word_12", in: app)
        XCTAssertTrue(previousWord.waitForExistence(timeout: transcriptOpenTimeout))
        XCTAssertTrue(activeWord.waitForExistence(timeout: transcriptOpenTimeout))
        XCTAssertEqual(accessibilityValue(for: "transcript.activeWord", in: app), "12")
        XCTAssertLessThanOrEqual(
            abs(previousWord.frame.height - activeWord.frame.height),
            1,
            "The active pill must not add padding or alter the word's font metrics."
        )
    }

    @MainActor
    func testManualScrollShowsFollowButtonAndSnapRestoresFollow() throws {
        let app = launchScrollFollowTranscriptFixtureApp()
        startPlaybackAndOpenTranscript(app)

        let transcript = element("transcript.view", in: app)
        let miniPlayer = element("miniPlayer", in: app)
        XCTAssertTrue(transcript.exists)
        XCTAssertTrue(miniPlayer.exists)
        XCTAssertFalse(element("transcript.snapToFollow", in: app).exists)

        guard let initialIndex = activeWordIndex(in: app) else {
            XCTFail("The scroll-follow fixture must expose an active word index.")
            return
        }
        let initialWord = element("transcript.word_\(initialIndex)", in: app)
        XCTAssertTrue(isVisible(initialWord, in: transcript, above: miniPlayer))

        for _ in 0 ..< 3 where isVisible(initialWord, in: transcript, above: miniPlayer) {
            transcript.swipeUp()
        }
        XCTAssertFalse(
            isVisible(initialWord, in: transcript, above: miniPlayer),
            "A real manual scroll must move the active word outside the viewport."
        )

        let snap = element("transcript.snapToFollow", in: app)
        XCTAssertTrue(waitForElementHittable(snap, timeout: transcriptOpenTimeout))
        XCTAssertLessThanOrEqual(
            snap.frame.maxY,
            miniPlayer.frame.minY,
            "The follow button must sit above, not behind, the mini-player."
        )
        snap.tap()

        let disappeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: snap
        )
        XCTAssertEqual(XCTWaiter().wait(for: [disappeared], timeout: transcriptOpenTimeout), .completed)

        guard let snappedIndex = activeWordIndex(in: app) else {
            XCTFail("The active word index must remain available after snapping.")
            return
        }
        let snappedWord = element("transcript.word_\(snappedIndex)", in: app)
        XCTAssertTrue(
            waitUntil(timeout: transcriptOpenTimeout) {
                isVisible(snappedWord, in: transcript, above: miniPlayer)
            },
            "Snapping must return the current active word to the viewport."
        )

        let nextBlockStart = ((snappedIndex / 4) + 1) * 4
        XCTAssertTrue(
            waitUntil(timeout: 8) {
                guard let liveIndex = activeWordIndex(in: app) else { return false }
                return liveIndex >= nextBlockStart
            },
            "Live playback must advance into the next transcript render block."
        )
        XCTAssertFalse(snap.exists, "Following must remain on at the next render-block boundary.")

        guard let followedIndex = activeWordIndex(in: app) else {
            XCTFail("The active word index must advance with live playback.")
            return
        }
        XCTAssertTrue(
            isVisible(
                element("transcript.word_\(followedIndex)", in: app),
                in: transcript,
                above: miniPlayer
            ),
            "The live active word must remain visible after following into the next block."
        )
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
    func testParagraphTimestampDoesNotOverlapTranscriptWords() throws {
        let app = launchTranscriptFixtureApp()
        openTranscriptFromEpisodeRow(app)

        let timestamp = element("transcript.paragraph_0.timestamp", in: app)
        let firstWord = element("transcript.word_0", in: app)
        XCTAssertTrue(timestamp.waitForExistence(timeout: transcriptOpenTimeout))
        XCTAssertTrue(firstWord.waitForExistence(timeout: transcriptOpenTimeout))
        XCTAssertLessThanOrEqual(
            timestamp.frame.maxY,
            firstWord.frame.minY,
            "The first transcript row must start below its paragraph timestamp."
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

        XCTAssertTrue(
            waitUntil(timeout: backfillAffordanceTimeout) {
                let refreshedCell = app.cells["episodeCell_0"]
                let viewTranscript = refreshedCell.descendants(matching: .any)["episode.viewTranscript"]
                return viewTranscript.exists && viewTranscript.isHittable
            },
            "episode.viewTranscript must become hittable within \(backfillAffordanceTimeout)s after backfill"
        )
    }

    // MARK: - AC9

    @MainActor
    func testTranscriptHiddenWhilePlaybackPrepares() throws {
        let app = launchPreparationFixtureApp()
        navigateToEpisodeList(app)
        ensureChannelCleaningOn(in: app)

        let episodeCell = app.cells["episodeCell_0"]
        XCTAssertTrue(episodeCell.waitForExistence(timeout: fixtureTimeout))
        episodeCell.tap()

        let preparing = element("miniPlayer.preparing", in: app)
        XCTAssertTrue(
            preparing.waitForExistence(timeout: fixtureTimeout),
            "terminal preparation must be visible before playback starts"
        )

        assertTranscriptAffordanceAbsent("episode.viewTranscript", scopedToRow: 0, in: app)
    }

    // MARK: - Task 029

    @MainActor
    func testMiniPlayerVisibleWhileTranscriptOpen() throws {
        let app = launchTranscriptFixtureApp()
        startPlaybackAndOpenTranscript(app)

        let transcriptView = element("transcript.view", in: app)
        XCTAssertTrue(
            transcriptView.waitForExistence(timeout: transcriptOpenTimeout),
            "transcript.view must appear within \(transcriptOpenTimeout)s"
        )

        let miniPlayer = element("miniPlayer", in: app)
        XCTAssertTrue(
            miniPlayer.waitForExistence(timeout: transcriptOpenTimeout),
            "miniPlayer must exist within \(transcriptOpenTimeout)s while transcript is open"
        )
        XCTAssertTrue(
            waitForElementHittable(miniPlayer, timeout: transcriptOpenTimeout),
            "miniPlayer must be hittable within \(transcriptOpenTimeout)s while transcript is open"
        )
    }

    @MainActor
    func testMiniPlayerPlayPauseHittableWhileTranscriptOpen() throws {
        let app = launchTranscriptFixtureApp()
        startPlaybackAndOpenTranscript(app)

        let transcriptView = element("transcript.view", in: app)
        XCTAssertTrue(
            transcriptView.waitForExistence(timeout: transcriptOpenTimeout),
            "transcript.view must appear within \(transcriptOpenTimeout)s"
        )

        let playPause = element("miniPlayerPlayPause", in: app)
        XCTAssertTrue(
            waitForElementHittable(playPause, timeout: transcriptOpenTimeout),
            "miniPlayerPlayPause must be hittable within \(transcriptOpenTimeout)s while transcript is open"
        )

        startMiniPlaybackIfNeeded(app)
        waitForAccessibilityValue(
            "playing",
            identifier: "miniPlayerPlayPause",
            in: app,
            timeout: transcriptOpenTimeout,
            message: "miniPlayerPlayPause must report playing before toggle while transcript is open"
        )

        playPause.tap()
        waitForAccessibilityValue(
            "paused",
            identifier: "miniPlayerPlayPause",
            in: app,
            timeout: transcriptOpenTimeout,
            message: "miniPlayerPlayPause must report paused within \(transcriptOpenTimeout)s after toggle"
        )

        playPause.tap()
        waitForAccessibilityValue(
            "playing",
            identifier: "miniPlayerPlayPause",
            in: app,
            timeout: transcriptOpenTimeout,
            message: "miniPlayerPlayPause must report playing within \(transcriptOpenTimeout)s after second toggle"
        )
    }

    @MainActor
    func testMiniPlayerExpandFromTranscriptOpensFullPlayer() throws {
        let app = launchTranscriptFixtureApp()
        startPlaybackAndOpenTranscript(app)

        let transcriptView = element("transcript.view", in: app)
        XCTAssertTrue(
            transcriptView.waitForExistence(timeout: transcriptOpenTimeout),
            "transcript.view must appear within \(transcriptOpenTimeout)s"
        )

        let miniPlayer = element("miniPlayer", in: app)
        XCTAssertTrue(
            waitForElementHittable(miniPlayer, timeout: transcriptOpenTimeout),
            "miniPlayer must be hittable before expand tap while transcript is open"
        )

        tapMiniPlayerExpandTarget(app)

        let fullPlayPause = element("playback.playPause", in: app)
        let fullSeekBar = element("playback.superSeekBar", in: app)
        let opened = fullPlayPause.waitForExistence(timeout: miniPlayerExpandFromTranscriptTimeout)
            || fullSeekBar.waitForExistence(timeout: miniPlayerExpandFromTranscriptTimeout)
        XCTAssertTrue(
            opened,
            "Tap miniPlayer expand target must present full player within \(miniPlayerExpandFromTranscriptTimeout)s while transcript was open"
        )
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
    private func launchLongFollowTranscriptFixtureApp() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments.append(Self.longFollowFixtureArg)
        app.launch()
        return app
    }

    @MainActor
    private func launchScrollFollowTranscriptFixtureApp() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments.append(Self.scrollFollowFixtureArg)
        app.launch()
        return app
    }

    @MainActor
    private func launchPreparationFixtureApp() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments.append(Self.transcriptNoCacheArg)
        app.launchArguments.append("-UITestFixtureLibraryAnalysisTimeline")
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
    private func startPlaybackAndOpenTranscript(_ app: XCUIApplication) {
        navigateToEpisodeList(app)

        let episodeCell = app.cells["episodeCell_0"]
        XCTAssertTrue(episodeCell.waitForExistence(timeout: fixtureTimeout))
        episodeCell.tap()

        let miniPlayer = element("miniPlayer", in: app)
        XCTAssertTrue(
            miniPlayer.waitForExistence(timeout: fixtureTimeout),
            "miniPlayer must appear after starting playback"
        )
        startMiniPlaybackIfNeeded(app)

        tapEpisodeViewTranscript(onRow: 0, in: app)
    }

    @MainActor
    private func startMiniPlaybackIfNeeded(_ app: XCUIApplication) {
        let playPause = element("miniPlayerPlayPause", in: app)
        if accessibilityValue(for: "miniPlayerPlayPause", in: app) != "playing" {
            playPause.tap()
        }
    }

    @MainActor
    private func tapMiniPlayerExpandTarget(_ app: XCUIApplication) {
        let bar = element("miniPlayer", in: app)
        XCTAssertTrue(bar.waitForExistence(timeout: fixtureTimeout))
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
    }

    @MainActor
    private func activeWordIndex(in app: XCUIApplication) -> Int? {
        accessibilityValue(for: "transcript.activeWord", in: app).flatMap(Int.init)
    }

    @MainActor
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

    @MainActor
    private func isVisible(
        _ element: XCUIElement,
        in transcript: XCUIElement,
        above miniPlayer: XCUIElement
    ) -> Bool {
        guard element.exists else { return false }
        let visibleTop = transcript.frame.minY
        let visibleBottom = min(transcript.frame.maxY, miniPlayer.frame.minY)
        return element.frame.midY >= visibleTop && element.frame.midY <= visibleBottom
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
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
