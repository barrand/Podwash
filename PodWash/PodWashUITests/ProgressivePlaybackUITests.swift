//
//  ProgressivePlaybackUITests.swift
//  PodWashUITests
//
//  Slice 25 — Progressive playback + super seek bar UI tests (slice-25-ux.md). AC3–AC6.
//  Launch fixture: -UITestFixtureProgressivePlayback (120.0 s stepped analyzer).
//
//  Until FixtureProgressivePlayback, playback.superSeekBar, and playback.remaining
//  exist (Engineer), these tests fail at compile or launch — intended TDD red state.
//

import XCTest

final class ProgressivePlaybackUITests: XCTestCase {

    private let fixtureTimeout: TimeInterval = 5
    private let libraryRootTimeout: TimeInterval = 10
    private let episodeDuration = 120
    private let durationSumMin = 118
    private let durationSumMax = 122

    private static let firstChunkTimelineValue = "ready:3,processing:1,pending:8"
    private static let midRunTimelineValue = "ready:6,processing:1,pending:5"
    private static let terminalTimelineValue = "ready:12,processing:0,pending:0"

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Sims often wake landscape (~402pt tall). PodcastDetail header + Up Next
        // then crush episodeList to ~0 height so episodeCell_* exists but is not hittable.
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: - AC3

    @MainActor
    func testPlaybackStartsWhileAnalysisInFlight() throws {
        let app = launchProgressiveFixtureApp()
        navigateToExpandedFullPlayer(app)
        startPlaybackIfNeeded(app)

        let playingExpectation = expectation(description: "playback.playPause playing")
        let timelineExpectation = expectation(description: "first-chunk super seek bar")
        playingExpectation.assertForOverFulfill = false
        timelineExpectation.assertForOverFulfill = false

        var sawPlaying = false
        var sawFirstChunk = false
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            let playValue = Self.accessibilityValue(for: "playback.playPause", in: app)
            let barValue = Self.accessibilityValue(for: "playback.superSeekBar", in: app)
            if !sawPlaying, playValue == "playing" {
                sawPlaying = true
                playingExpectation.fulfill()
            }
            if !sawFirstChunk, barValue == Self.firstChunkTimelineValue {
                sawFirstChunk = true
                timelineExpectation.fulfill()
            }
            if sawPlaying, sawFirstChunk {
                timer.invalidate()
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        defer { timer.invalidate() }

        wait(for: [playingExpectation, timelineExpectation], timeout: fixtureTimeout)

        XCTAssertNotEqual(
            Self.accessibilityValue(for: "playback.superSeekBar", in: app),
            Self.terminalTimelineValue,
            "First-chunk snapshot must not be terminal complete"
        )
    }

    // MARK: - AC4

    @MainActor
    func testSeekBarReachesTerminalAnalysisState() throws {
        let app = launchProgressiveFixtureApp()
        navigateToExpandedFullPlayer(app)
        startPlaybackIfNeeded(app)

        let terminalExpectation = expectation(description: "terminal super seek bar")
        terminalExpectation.assertForOverFulfill = false

        var sawTerminal = false
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            guard !sawTerminal,
                  Self.accessibilityValue(for: "playback.superSeekBar", in: app) == Self.terminalTimelineValue
            else { return }
            sawTerminal = true
            timer.invalidate()
            terminalExpectation.fulfill()
        }
        RunLoop.current.add(timer, forMode: .common)
        defer { timer.invalidate() }

        wait(for: [terminalExpectation], timeout: 10)
    }

    // MARK: - AC5

    @MainActor
    func testSeekClampsToProcessedFrontier() throws {
        let app = launchProgressiveFixtureApp(freezeAtProcessedEnd: 60)
        navigateToExpandedFullPlayer(app)
        startPlaybackIfNeeded(app)

        waitForSuperSeekBarValue(Self.midRunTimelineValue, in: app, timeout: fixtureTimeout)

        let bar = element("playback.superSeekBar", in: app)
        XCTAssertTrue(bar.waitForExistence(timeout: fixtureTimeout))
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()

        let elapsedExpectation = expectation(description: "elapsed clamped to frontier")
        elapsedExpectation.assertForOverFulfill = false

        var satisfied = false
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            guard let elapsed = Self.elapsedSeconds(in: app) else { return }
            if elapsed >= 55, elapsed <= 60 {
                satisfied = true
                timer.invalidate()
                elapsedExpectation.fulfill()
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        defer { timer.invalidate() }

        wait(for: [elapsedExpectation], timeout: 2)
        XCTAssertTrue(satisfied, "playback.elapsed must clamp to frontier Int 55–60 after tap at 90 s")
    }

    // MARK: - AC6

    @MainActor
    func testElapsedAndRemainingSumToDuration() throws {
        let app = launchProgressiveFixtureApp()
        navigateToExpandedFullPlayer(app)
        startPlaybackIfNeeded(app)

        let elapsedReady = expectation(description: "elapsed ≥ 10 s")
        elapsedReady.assertForOverFulfill = false

        var sawElapsed = false
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            guard let elapsed = Self.elapsedSeconds(in: app), elapsed >= 10 else { return }
            sawElapsed = true
            timer.invalidate()
            elapsedReady.fulfill()
        }
        RunLoop.current.add(timer, forMode: .common)
        defer { timer.invalidate() }

        wait(for: [elapsedReady], timeout: 15)

        let remaining = element("playback.remaining", in: app)
        XCTAssertTrue(
            remaining.waitForExistence(timeout: fixtureTimeout),
            "playback.remaining must exist on the super seek bar time row"
        )

        guard let elapsed = Self.elapsedSeconds(in: app),
              let remainingSeconds = Self.remainingSeconds(in: app) else {
            XCTFail("Could not parse elapsed/remaining accessibility values")
            return
        }

        let sum = elapsed + remainingSeconds
        XCTAssertGreaterThanOrEqual(
            sum,
            durationSumMin,
            "elapsed + remaining must be ≥ \(durationSumMin) for \(episodeDuration) s episode (±2 s)"
        )
        XCTAssertLessThanOrEqual(
            sum,
            durationSumMax,
            "elapsed + remaining must be ≤ \(durationSumMax) for \(episodeDuration) s episode (±2 s)"
        )
    }

    // MARK: - Launch + navigation (slice-25-ux.md)

    @MainActor
    private func launchProgressiveFixtureApp(freezeAtProcessedEnd: Double? = nil) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments.append("-UITestFixtureProgressivePlayback")
        if let freezeAtProcessedEnd {
            app.launchArguments.append(
                "-UITestFixtureProgressivePlaybackFreezeAt\(Int(freezeAtProcessedEnd))"
            )
        }
        app.launch()
        return app
    }

    @MainActor
    private func navigateToExpandedFullPlayer(_ app: XCUIApplication) {
        let root = element("libraryRoot", in: app)
        XCTAssertTrue(
            root.waitForExistence(timeout: libraryRootTimeout),
            "libraryRoot must appear within \(libraryRootTimeout)s"
        )

        let showCell = element("libraryCell_0", in: app)
        XCTAssertTrue(showCell.waitForExistence(timeout: fixtureTimeout))
        showCell.tap()

        let episodeList = element("episodeList", in: app)
        XCTAssertTrue(episodeList.waitForExistence(timeout: fixtureTimeout))

        ensureChannelCleaningOn(in: app)

        let episodeCell = element("episodeCell_0", in: app)
        XCTAssertTrue(episodeCell.waitForExistence(timeout: fixtureTimeout))
        let cellHittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: episodeCell
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [cellHittable], timeout: fixtureTimeout),
            .completed,
            "episodeCell_0 must be hittable (portrait list height); frame=\(episodeCell.frame)"
        )
        episodeCell.tap()

        let miniPlayer = element("miniPlayer", in: app)
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: fixtureTimeout))

        miniPlayer.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()

        let fullPlayPause = element("playback.playPause", in: app)
        XCTAssertTrue(fullPlayPause.waitForExistence(timeout: fixtureTimeout))
    }

    @MainActor
    private func startPlaybackIfNeeded(_ app: XCUIApplication) {
        let playPause = element("playback.playPause", in: app)
        // Queue play while analyzing, or start immediately once paused/ready.
        // Do not no-op on "paused" — episode tap leaves the session paused (slice-25-ux).
        let value = Self.accessibilityValue(for: "playback.playPause", in: app)
        if value != "playing" {
            playPause.tap()
        }
    }

    @MainActor
    private func ensureChannelCleaningOn(in app: XCUIApplication) {
        // PodcastDetailView pins accessibilityValue to "on"/"off" (not UIKit "1"/"0").
        // Checking != "1" incorrectly toggles an already-on fixture switch OFF and skips
        // progressive prepare — every AC3–AC6 expectation then times out.
        let channelToggle = app.switches["channelCleaningToggle"]
        guard channelToggle.waitForExistence(timeout: fixtureTimeout) else { return }
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: channelToggle
        )
        _ = XCTWaiter().wait(for: [hittable], timeout: 3)
        guard (channelToggle.value as? String) != "on" else { return }
        channelToggle.tap()
        let onExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "on"),
            object: channelToggle
        )
        _ = XCTWaiter().wait(for: [onExpectation], timeout: 2)
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

    private static func accessibilityValue(for identifier: String, in app: XCUIApplication) -> String? {
        let control = app.descendants(matching: .any)[identifier]
        guard control.exists else { return nil }
        if let string = control.value as? String { return string }
        if let nsString = control.value as? NSString { return nsString as String }
        return nil
    }

    private static func elapsedSeconds(in app: XCUIApplication) -> Int? {
        guard let raw = accessibilityValue(for: "playback.elapsed", in: app) else { return nil }
        return Int(raw)
    }

    private static func remainingSeconds(in app: XCUIApplication) -> Int? {
        guard let raw = accessibilityValue(for: "playback.remaining", in: app) else { return nil }
        return Int(raw)
    }
}
