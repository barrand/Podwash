//
//  SuperSeekBarUITests.swift
//  PodWashUITests
//
//  Slice 27 — Super seek bar mute marker UI tests (slice-27-ux.md). AC3–AC4.
//  Slice 33 — Timestamp ad bands + progress chrome migrations (slice-33-ux.md). AC6–AC7.
//  Launch fixtures: -UITestFixtureMuteMarkers, -UITestFixtureMuteMarkersAdsOnly,
//  -UITestFixturePrerollAdBands, -UITestFixturePrerollAdBandsWithMutes.
//
//  Until preroll fixtures and adBands AX grammar exist (Engineer), AC6–AC7 fail at
//  launch — intended TDD red state.
//

import XCTest

final class SuperSeekBarUITests: XCTestCase {

    private let fixtureTimeout: TimeInterval = 5
    private let libraryRootTimeout: TimeInterval = 10
    private let progressiveTerminalTimeout: TimeInterval = 10
    private let prerollDuration: Double = 600.0
    private let normalizationTolerance = 0.002
    private let wallTimeTolerance: Double = 1.0
    private let progressTolerance = 0.02

    private static let muteMarkersPinnedValue = "adBands:0,muteMarkers:2"
    private static let adsOnlyTerminalValue = "adBands:1,0.2917-0.3542,muteMarkers:0"
    private static let prerollPinnedValue = "adBands:1,0.0000-0.0500,muteMarkers:0"
    private static let prerollWithMutesPinnedValue = "adBands:1,0.0000-0.0500,muteMarkers:2"
    private static let progressiveTerminalValue = "adBands:0,muteMarkers:2"
    private static let progressiveFirstChunkProgress = 0.25

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: - Slice 27 AC3

    @MainActor
    func testMuteMarkersExposedWhenProfanityMutePresent() throws {
        let app = launchFixtureApp("-UITestFixtureMuteMarkers")
        navigateToExpandedFullPlayer(app)
        startPlaybackIfNeeded(app)

        let barValue = waitForSuperSeekBarValue(matching: { value in
            (SuperSeekBarAXParsing.muteMarkerCount(from: value) ?? -1) >= 1
        }, in: app, timeout: fixtureTimeout)

        XCTAssertGreaterThanOrEqual(
            SuperSeekBarAXParsing.muteMarkerCount(from: barValue) ?? -1,
            1,
            "muteMarkers count must be ≥ 1 when profanity mute intervals are cached"
        )
        XCTAssertEqual(
            barValue,
            Self.muteMarkersPinnedValue,
            "Pinned mute-markers fixture must expose exact terminal AX string"
        )
        XCTAssertTrue(
            SuperSeekBarAXParsing.lacksSegmentTriple(barValue),
            "Complete bar must not use legacy ready/processing/pending grammar"
        )
    }

    // MARK: - Slice 27 AC4

    @MainActor
    func testMuteMarkersAbsentForAdsOnly() throws {
        let app = launchFixtureApp("-UITestFixtureMuteMarkersAdsOnly")
        navigateToExpandedFullPlayer(app)
        startPlaybackIfNeeded(app)

        let barValue = waitForSuperSeekBarValue(
            equalTo: Self.adsOnlyTerminalValue,
            in: app,
            timeout: fixtureTimeout
        )

        XCTAssertEqual(SuperSeekBarAXParsing.muteMarkerCount(from: barValue), 0)
        guard let summary = SuperSeekBarAXParsing.adBandSummary(from: barValue) else {
            XCTFail("Complete ads-only bar must parse adBands grammar; got \(barValue)")
            return
        }
        XCTAssertEqual(summary.count, 1)
        XCTAssertEqual(summary.bands[0].start, 35.0 / 120.0, accuracy: normalizationTolerance)
        XCTAssertEqual(summary.bands[0].end, 42.5 / 120.0, accuracy: normalizationTolerance)

        let bar = element("playback.superSeekBar", in: app)
        XCTAssertTrue(bar.exists, "playback.superSeekBar must exist on ads-only complete fixture")
        XCTAssertTrue(
            element("playback.elapsed", in: app).waitForExistence(timeout: fixtureTimeout),
            "playback.elapsed must remain present — no regression to cleaning-on chrome"
        )
    }

    // MARK: - Slice 33 AC6

    @MainActor
    func testCompleteBarYellowMatchesPrerollSkipNotWholeBuckets() throws {
        let app = launchFixtureApp("-UITestFixturePrerollAdBands")
        navigateToExpandedFullPlayer(app)
        startPlaybackIfNeeded(app)

        let barValue = waitForSuperSeekBarValue(
            equalTo: Self.prerollPinnedValue,
            in: app,
            timeout: fixtureTimeout
        )

        guard let summary = SuperSeekBarAXParsing.adBandSummary(from: barValue) else {
            XCTFail("Preroll fixture must expose adBands grammar; got \(barValue)")
            return
        }
        XCTAssertEqual(summary.count, 1)
        XCTAssertEqual(summary.bands[0].start, 0.0, accuracy: normalizationTolerance)
        XCTAssertEqual(summary.bands[0].end, 0.05, accuracy: normalizationTolerance)

        guard let wallEnd = SuperSeekBarAXParsing.firstAdBandEndSeconds(
            from: barValue,
            duration: prerollDuration
        ) else {
            XCTFail("Could not denormalize first ad band end")
            return
        }
        XCTAssertGreaterThanOrEqual(wallEnd, 30.0 - wallTimeTolerance)
        XCTAssertLessThanOrEqual(wallEnd, 30.0 + wallTimeTolerance)

        XCTAssertTrue(SuperSeekBarAXParsing.lacksSegmentTriple(barValue))
        XCTAssertLessThanOrEqual(
            summary.bands[0].end,
            0.10,
            "30 s preroll on 600 s episode must not yellow a contiguous opening > 60 s (end ≤ 0.1000 normalized)"
        )
    }

    // MARK: - Slice 33 AC7

    @MainActor
    func testMuteMarkersRemainWithTimestampAdBands() throws {
        let app = launchFixtureApp("-UITestFixturePrerollAdBandsWithMutes")
        navigateToExpandedFullPlayer(app)
        startPlaybackIfNeeded(app)

        let barValue = waitForSuperSeekBarValue(
            equalTo: Self.prerollWithMutesPinnedValue,
            in: app,
            timeout: fixtureTimeout
        )

        guard let summary = SuperSeekBarAXParsing.adBandSummary(from: barValue) else {
            XCTFail("Preroll+mutes fixture must expose adBands grammar; got \(barValue)")
            return
        }
        XCTAssertEqual(summary.count, 1)
        XCTAssertEqual(summary.bands[0].start, 0.0, accuracy: normalizationTolerance)
        XCTAssertEqual(summary.bands[0].end, 0.05, accuracy: normalizationTolerance)
        XCTAssertGreaterThanOrEqual(summary.muteMarkers, 1)
        XCTAssertEqual(summary.muteMarkers, 2)
        XCTAssertTrue(SuperSeekBarAXParsing.lacksSegmentTriple(barValue))
    }

    // MARK: - UX regression (slice-33-ux.md migrations)

    @MainActor
    func testProgressiveMidRunShowsProgressHidesAdBands() throws {
        let app = launchFixtureApp(
            "-UITestFixtureProgressivePlayback",
            extraArguments: ["-UITestFixtureProgressivePlaybackFreezeAt30"]
        )
        navigateToExpandedFullPlayer(app)
        startPlaybackIfNeeded(app)

        let progress = waitForAnalysisProgress(in: app, timeout: fixtureTimeout)
        guard let fraction = Double(progress) else {
            XCTFail("playback.analysisProgress value must parse as Double; got \(progress)")
            return
        }
        XCTAssertEqual(
            fraction,
            Self.progressiveFirstChunkProgress,
            accuracy: progressTolerance,
            "First-chunk progress must be 30/120 ± \(progressTolerance)"
        )

        let barValue = Self.accessibilityValue(for: "playback.superSeekBar", in: app)
        XCTAssertTrue(
            SuperSeekBarAXParsing.lacksSegmentTriple(barValue),
            "In-flight seek bar must not expose ready/processing/pending"
        )
        if let barValue {
            XCTAssertFalse(barValue.contains("adBands:"))
            XCTAssertFalse(barValue.contains("muteMarkers:"))
        }
    }

    @MainActor
    func testProgressiveTerminalUsesAdBandsNotSegmentTriple() throws {
        let app = launchFixtureApp("-UITestFixtureProgressivePlayback")
        navigateToExpandedFullPlayer(app)
        startPlaybackIfNeeded(app)

        let barValue = waitForSuperSeekBarValue(
            equalTo: Self.progressiveTerminalValue,
            in: app,
            timeout: progressiveTerminalTimeout
        )
        XCTAssertTrue(SuperSeekBarAXParsing.lacksSegmentTriple(barValue))
        XCTAssertFalse(
            element("playback.analysisProgress", in: app).exists,
            "Terminal complete must hide playback.analysisProgress"
        )
    }

    @MainActor
    func testCleaningOffOmitsProgressAndAdBands() throws {
        let app = launchFixtureApp(
            "-UITestFixtureMuteMarkers",
            extraArguments: ["-UITestChannelCleaningOff"]
        )
        navigateToEpisodeList(app)

        let episodeCell = element("episodeCell_0", in: app)
        XCTAssertTrue(episodeCell.waitForExistence(timeout: fixtureTimeout))
        episodeCell.tap()

        let miniPlayer = element("miniPlayer", in: app)
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: fixtureTimeout))
        miniPlayer.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()

        let bar = element("playback.superSeekBar", in: app)
        XCTAssertTrue(bar.waitForExistence(timeout: fixtureTimeout))

        if let value = Self.accessibilityValue(for: "playback.superSeekBar", in: app) {
            XCTAssertTrue(SuperSeekBarAXParsing.lacksSegmentTriple(value))
            XCTAssertFalse(value.contains("adBands:"))
        }
        XCTAssertFalse(
            element("playback.analysisProgress", in: app).exists,
            "Cleaning off must omit playback.analysisProgress"
        )
    }

    // MARK: - Launch + navigation (slice-27-ux.md)

    @MainActor
    private func launchFixtureApp(
        _ argument: String,
        extraArguments: [String] = []
    ) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments.append(argument)
        app.launchArguments.append(contentsOf: extraArguments)
        app.launch()
        return app
    }

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
        XCTAssertTrue(episodeList.waitForExistence(timeout: fixtureTimeout))
    }

    @MainActor
    private func navigateToExpandedFullPlayer(_ app: XCUIApplication) {
        navigateToEpisodeList(app)
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
            "episodeCell_0 must be hittable"
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
        if Self.accessibilityValue(for: "playback.playPause", in: app) != "playing" {
            playPause.tap()
        }
    }

    @MainActor
    private func ensureChannelCleaningOn(in app: XCUIApplication) {
        // Task-023: channel cleaning defaults on; podcast detail no longer exposes the toggle.
    }

    @MainActor
    @discardableResult
    private func waitForSuperSeekBarValue(
        equalTo expected: String,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> String {
        waitForSuperSeekBarValue(matching: { $0 == expected }, in: app, timeout: timeout)
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

    @MainActor
    @discardableResult
    private func waitForSuperSeekBarValue(
        matching predicate: @escaping (String) -> Bool,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> String {
        let match = expectation(description: "superSeekBar value")
        match.assertForOverFulfill = false

        var resolved = ""
        var saw = false
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            guard let value = Self.accessibilityValue(for: "playback.superSeekBar", in: app),
                  predicate(value)
            else { return }
            saw = true
            resolved = value
            timer.invalidate()
            match.fulfill()
        }
        RunLoop.current.add(timer, forMode: .common)
        defer { timer.invalidate() }
        wait(for: [match], timeout: timeout)
        XCTAssertTrue(saw, "playback.superSeekBar must satisfy predicate within \(timeout)s")
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
}
