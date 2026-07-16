//
//  ProgressivePlaybackUITests.swift
//  PodWashUITests
//
//  Slice 25 — Progressive playback + super seek bar UI tests (slice-25-ux.md). AC3–AC6.
//  Slice 33 — Migrated in-flight segment triple → analysis progress AX (slice-33-ux.md).
//  Launch fixture: -UITestFixtureProgressivePlayback (120.0 s stepped analyzer).
//
//  Until playback.analysisProgress and adBands terminal AX exist (Engineer), migrated
//  assertions fail at launch — intended TDD red state.
//

import XCTest

final class ProgressivePlaybackUITests: XCTestCase {

    private let fixtureTimeout: TimeInterval = 5
    private let libraryRootTimeout: TimeInterval = 10
    private let episodeDuration = 120
    private let durationSumMin = 118
    private let durationSumMax = 122
    private let progressTolerance = 0.02

    private static let firstChunkProgressValue = 0.25
    private static let terminalBarValue = "adBands:0,muteMarkers:2"

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: - AC3 (slice-33 migration — progress AX, no segment triple)

    @MainActor
    func testPlaybackStartsWhileAnalysisInFlight() throws {
        let app = launchProgressiveFixtureApp(freezeAtProcessedEnd: 30)
        navigateToExpandedFullPlayer(app)
        startPlaybackIfNeeded(app)

        let playingExpectation = expectation(description: "playback.playPause playing")
        let progressExpectation = expectation(description: "first-chunk analysis progress")
        playingExpectation.assertForOverFulfill = false
        progressExpectation.assertForOverFulfill = false

        var sawPlaying = false
        var sawProgress = false
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            let playValue = Self.accessibilityValue(for: "playback.playPause", in: app)
            if !sawPlaying, playValue == "playing" {
                sawPlaying = true
                playingExpectation.fulfill()
            }
            if !sawProgress,
               let progressRaw = Self.accessibilityValue(for: "playback.analysisProgress", in: app),
               let fraction = Double(progressRaw),
               abs(fraction - Self.firstChunkProgressValue) <= 0.02 {
                sawProgress = true
                progressExpectation.fulfill()
            }
            if sawPlaying, sawProgress {
                timer.invalidate()
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        defer { timer.invalidate() }

        wait(for: [playingExpectation, progressExpectation], timeout: fixtureTimeout)

        let barValue = Self.accessibilityValue(for: "playback.superSeekBar", in: app)
        XCTAssertTrue(
            SuperSeekBarAXParsing.lacksSegmentTriple(barValue),
            "In-flight seek bar must not expose ready/processing/pending segment triple"
        )
        XCTAssertNotEqual(
            Self.accessibilityValue(for: "playback.superSeekBar", in: app),
            Self.terminalBarValue,
            "First-chunk snapshot must not be terminal complete"
        )
    }

    // MARK: - AC4 (slice-33 migration — adBands terminal)

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
                  Self.accessibilityValue(for: "playback.superSeekBar", in: app) == Self.terminalBarValue
            else { return }
            sawTerminal = true
            timer.invalidate()
            terminalExpectation.fulfill()
        }
        RunLoop.current.add(timer, forMode: .common)
        defer { timer.invalidate() }

        wait(for: [terminalExpectation], timeout: 10)
        XCTAssertFalse(
            element("playback.analysisProgress", in: app).exists,
            "Terminal complete must hide playback.analysisProgress"
        )
    }

    // MARK: - AC5 (slice-33 migration — frontier clamp without segment triple setup)

    @MainActor
    func testSeekClampsToProcessedFrontier() throws {
        let app = launchProgressiveFixtureApp(freezeAtProcessedEnd: 60)
        navigateToExpandedFullPlayer(app)
        startPlaybackIfNeeded(app)

        let progress = waitForAnalysisProgress(in: app, timeout: fixtureTimeout)
        guard let fraction = Double(progress) else {
            XCTFail("playback.analysisProgress must parse as Double; got \(progress)")
            return
        }
        XCTAssertEqual(fraction, 0.5, accuracy: progressTolerance)

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
        let value = Self.accessibilityValue(for: "playback.playPause", in: app)
        if value != "playing" {
            playPause.tap()
        }
    }

    @MainActor
    private func ensureChannelCleaningOn(in app: XCUIApplication) {
        // Task-023: channel cleaning defaults on; podcast detail no longer exposes the toggle.
    }

    @MainActor
    @discardableResult
    private func waitForAnalysisProgress(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> String {
        let match = expectation(description: "playback.analysisProgress")
        match.assertForOverFulfill = false

        var resolved = ""
        var saw = false
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            guard let value = Self.accessibilityValue(for: "playback.analysisProgress", in: app) else {
                return
            }
            saw = true
            resolved = value
            timer.invalidate()
            match.fulfill()
        }
        RunLoop.current.add(timer, forMode: .common)
        defer { timer.invalidate() }
        wait(for: [match], timeout: timeout)
        XCTAssertTrue(saw, "playback.analysisProgress must appear within \(timeout)s")
        return resolved
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
