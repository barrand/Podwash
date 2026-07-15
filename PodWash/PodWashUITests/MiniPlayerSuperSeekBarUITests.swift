//
//  MiniPlayerSuperSeekBarUITests.swift
//  PodWashUITests
//
//  Slice 30 — Mini-player super seek bar parity (slice-30-ux.md). AC1–AC5.
//  Launch fixtures: -UITestFixtureMuteMarkers, -UITestFixtureMuteMarkersAdsOnly,
//  -UITestFixtureProgressivePlayback.
//
//  Until MiniPlayerBar hosts SuperSeekBarView with miniPlayer.superSeekBar (Engineer),
//  these tests fail at compile or launch — intended TDD red state.
//

import XCTest

final class MiniPlayerSuperSeekBarUITests: XCTestCase {

    private let fixtureTimeout: TimeInterval = 5
    private let libraryRootTimeout: TimeInterval = 10
    private let elapsedClampTimeout: TimeInterval = 2
    /// Mid-run sync under FreezeAt — must cover pacing past the first chunk (not the
    /// 7 s firstSnapshotHold used by non-freeze progressive tests).
    private let progressiveMidRunTimeout: TimeInterval = 10

    private static let muteMarkersPinnedValue = "ready:12,processing:0,pending:0,muteMarkers:2"
    private static let adsOnlyTerminalValue = "ready:12,processing:0,pending:0,muteMarkers:0"
    private static let progressiveMidRunValue = "ready:6,processing:1,pending:5"

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: - AC1

    @MainActor
    func testMiniPlayerExposesMuteMarkersWhenProfanityMutePresent() throws {
        let app = launchFixtureApp("-UITestFixtureMuteMarkers")
        navigateToMiniPlayer(app)
        startMiniPlaybackIfNeeded(app)

        let barValue = waitForMiniSuperSeekBarValue(matching: { value in
            (Self.muteMarkerCount(from: value) ?? -1) >= 1
        }, in: app, timeout: fixtureTimeout)

        let segments = Self.segmentCounts(from: barValue)
        XCTAssertEqual(segments?.ready, 12, "Complete fixture ready count; got \(barValue)")
        XCTAssertEqual(segments?.processing, 0, "Complete fixture processing count; got \(barValue)")
        XCTAssertEqual(segments?.pending, 0, "Complete fixture pending count; got \(barValue)")
        XCTAssertGreaterThanOrEqual(
            Self.muteMarkerCount(from: barValue) ?? -1,
            1,
            "muteMarkers count must be ≥ 1 when profanity mute intervals are cached"
        )
        XCTAssertEqual(
            barValue,
            Self.muteMarkersPinnedValue,
            "Pinned mute-markers fixture must expose exact terminal AX string on mini host"
        )
        XCTAssertFalse(
            element("miniPlayerAnalysisTimeline", in: app).exists,
            "Retired miniPlayerAnalysisTimeline must not appear after slice-30 migration"
        )
    }

    // MARK: - AC2

    @MainActor
    func testMiniAndFullPlayerMuteMarkersParity() throws {
        let app = launchFixtureApp("-UITestFixtureMuteMarkers")
        navigateToMiniPlayer(app)
        startMiniPlaybackIfNeeded(app)

        let miniValue = waitForMiniSuperSeekBarValue(matching: { value in
            (Self.muteMarkerCount(from: value) ?? -1) >= 1
        }, in: app, timeout: fixtureTimeout)

        tapMiniPlayerExpandTarget(app)

        let fullValue = waitForFullSuperSeekBarValue(matching: { value in
            (Self.muteMarkerCount(from: value) ?? -1) >= 1
        }, in: app, timeout: fixtureTimeout)

        XCTAssertEqual(
            Self.muteMarkerCount(from: miniValue),
            Self.muteMarkerCount(from: fullValue),
            "Mini and full muteMarkers counts must match for the same episode"
        )
        let miniSegments = Self.segmentCounts(from: miniValue)
        let fullSegments = Self.segmentCounts(from: fullValue)
        XCTAssertEqual(
            miniSegments?.ready,
            fullSegments?.ready,
            "Mini and full ready counts must match; mini=\(miniValue) full=\(fullValue)"
        )
        XCTAssertEqual(
            miniSegments?.processing,
            fullSegments?.processing,
            "Mini and full processing counts must match; mini=\(miniValue) full=\(fullValue)"
        )
        XCTAssertEqual(
            miniSegments?.pending,
            fullSegments?.pending,
            "Mini and full pending counts must match; mini=\(miniValue) full=\(fullValue)"
        )
    }

    // MARK: - AC3

    @MainActor
    func testMiniPlayerMuteMarkersZeroForAdsOnly() throws {
        let app = launchFixtureApp("-UITestFixtureMuteMarkersAdsOnly")
        navigateToMiniPlayer(app)
        startMiniPlaybackIfNeeded(app)

        let barValue = waitForMiniSuperSeekBarValue(
            equalTo: Self.adsOnlyTerminalValue,
            in: app,
            timeout: fixtureTimeout
        )

        let segments = Self.segmentCounts(from: barValue)
        XCTAssertEqual(segments?.ready, 12, "Ad-only fixture ready count; got \(barValue)")
        XCTAssertEqual(segments?.processing, 0, "Ad-only fixture processing count; got \(barValue)")
        XCTAssertEqual(segments?.pending, 0, "Ad-only fixture pending count; got \(barValue)")
        XCTAssertEqual(Self.muteMarkerCount(from: barValue), 0)
        XCTAssertEqual(segments!.ready + segments!.processing + segments!.pending, 12)
    }

    // MARK: - AC4

    @MainActor
    func testMiniPlayerSeekClampsToProcessedFrontier() throws {
        let app = launchProgressiveFixtureApp(freezeAtProcessedEnd: 60)
        navigateToMiniPlayer(app)
        startMiniPlaybackIfNeeded(app)

        waitForMiniSuperSeekBarValue(
            equalTo: Self.progressiveMidRunValue,
            in: app,
            timeout: progressiveMidRunTimeout
        )

        let bar = element("miniPlayer.superSeekBar", in: app)
        XCTAssertTrue(bar.waitForExistence(timeout: fixtureTimeout))
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()

        tapMiniPlayerExpandTarget(app)

        let elapsedExpectation = expectation(description: "elapsed clamped to frontier")
        elapsedExpectation.assertForOverFulfill = false

        var satisfied = false
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            guard let elapsed = Self.elapsedSeconds(in: app) else { return }
            if elapsed >= 55, elapsed <= 65 {
                satisfied = true
                timer.invalidate()
                elapsedExpectation.fulfill()
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        defer { timer.invalidate() }

        wait(for: [elapsedExpectation], timeout: elapsedClampTimeout)
        XCTAssertTrue(
            satisfied,
            "playback.elapsed must clamp to processedEnd 60.0 s within ±0.5 s (Int 55–65) after mini seek tap at 90 s"
        )
    }

    // MARK: - AC5

    @MainActor
    func testMiniPlayerExpandStillOpensFullPlayer() throws {
        let app = launchFixtureApp("-UITestFixtureMuteMarkers")
        navigateToMiniPlayer(app)
        startMiniPlaybackIfNeeded(app)

        let miniSeekBar = element("miniPlayer.superSeekBar", in: app)
        XCTAssertTrue(
            miniSeekBar.waitForExistence(timeout: fixtureTimeout),
            "miniPlayer.superSeekBar must exist before expand tap"
        )
        XCTAssertFalse(
            element("playback.playPause", in: app).exists,
            "Full player must not already be open before expand tap"
        )

        tapMiniPlayerExpandTarget(app)

        let fullPlayPause = element("playback.playPause", in: app)
        let fullSeekBar = element("playback.superSeekBar", in: app)
        let opened = fullPlayPause.waitForExistence(timeout: fixtureTimeout)
            || fullSeekBar.waitForExistence(timeout: fixtureTimeout)
        XCTAssertTrue(
            opened,
            "Tap miniPlayer expand target must present full player within \(fixtureTimeout)s"
        )
    }

    // MARK: - Launch + navigation (slice-30-ux.md)

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
    private func launchProgressiveFixtureApp(freezeAtProcessedEnd: Double) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments.append("-UITestFixtureProgressivePlayback")
        app.launchArguments.append(
            "-UITestFixtureProgressivePlaybackFreezeAt\(Int(freezeAtProcessedEnd))"
        )
        app.launch()
        return app
    }

    @MainActor
    private func navigateToMiniPlayer(_ app: XCUIApplication) {
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
        XCTAssertTrue(
            miniPlayer.waitForExistence(timeout: fixtureTimeout),
            "miniPlayer must appear within \(fixtureTimeout)s"
        )
    }

    @MainActor
    private func startMiniPlaybackIfNeeded(_ app: XCUIApplication) {
        let playPause = element("miniPlayerPlayPause", in: app)
        if Self.accessibilityValue(for: "miniPlayerPlayPause", in: app) != "playing" {
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
    @discardableResult
    private func waitForMiniSuperSeekBarValue(
        equalTo expected: String,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> String {
        waitForMiniSuperSeekBarValue(matching: { $0 == expected }, in: app, timeout: timeout)
    }

    @MainActor
    @discardableResult
    private func waitForMiniSuperSeekBarValue(
        matching predicate: @escaping (String) -> Bool,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> String {
        waitForSuperSeekBarValue(
            identifier: "miniPlayer.superSeekBar",
            matching: predicate,
            in: app,
            timeout: timeout
        )
    }

    @MainActor
    @discardableResult
    private func waitForFullSuperSeekBarValue(
        matching predicate: @escaping (String) -> Bool,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> String {
        waitForSuperSeekBarValue(
            identifier: "playback.superSeekBar",
            matching: predicate,
            in: app,
            timeout: timeout
        )
    }

    @MainActor
    @discardableResult
    private func waitForSuperSeekBarValue(
        identifier: String,
        matching predicate: @escaping (String) -> Bool,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> String {
        let match = expectation(description: "\(identifier) value")
        match.assertForOverFulfill = false

        var resolved = ""
        var saw = false
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            guard let value = Self.accessibilityValue(for: identifier, in: app),
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
        XCTAssertTrue(saw, "\(identifier) must satisfy predicate within \(timeout)s")
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

    /// Parses muteMarkers suffix; returns nil when key absent (in-flight).
    static func muteMarkerCount(from barValue: String) -> Int? {
        guard let range = barValue.range(of: "muteMarkers:") else { return nil }
        let tail = barValue[range.upperBound...]
        let digits = tail.prefix(while: { $0.isNumber })
        return Int(digits)
    }

    /// Segment triple without mute suffix (complete bars).
    static func segmentCounts(from barValue: String) -> (ready: Int, processing: Int, pending: Int)? {
        let segmentPart = barValue.split(separator: ",").filter { !$0.hasPrefix("muteMarkers:") }
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
}
