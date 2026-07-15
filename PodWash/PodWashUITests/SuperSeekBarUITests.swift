//
//  SuperSeekBarUITests.swift
//  PodWashUITests
//
//  Slice 27 — Super seek bar mute marker UI tests (slice-27-ux.md). AC3–AC4.
//  Launch fixtures: -UITestFixtureMuteMarkers, -UITestFixtureMuteMarkersAdsOnly.
//
//  Until FixtureMuteMarkers and muteMarkers AX suffix exist (Engineer), these tests
//  fail at compile or launch — intended TDD red state.
//

import XCTest

final class SuperSeekBarUITests: XCTestCase {

    private let fixtureTimeout: TimeInterval = 5
    private let libraryRootTimeout: TimeInterval = 10
    private let progressiveTerminalTimeout: TimeInterval = 10

    private static let progressiveMidRunValue = "ready:3,processing:1,pending:8"
    private static let progressiveTerminalValue = "ready:12,processing:0,pending:0,muteMarkers:2"
    private static let muteMarkersPinnedValue = "ready:12,processing:0,pending:0,muteMarkers:2"
    private static let adsOnlyTerminalValue = "ready:12,processing:0,pending:0,muteMarkers:0"

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: - AC3

    @MainActor
    func testMuteMarkersExposedWhenProfanityMutePresent() throws {
        let app = launchFixtureApp("-UITestFixtureMuteMarkers")
        navigateToExpandedFullPlayer(app)
        startPlaybackIfNeeded(app)

        let barValue = waitForSuperSeekBarValue(matching: { value in
            (Self.muteMarkerCount(from: value) ?? -1) >= 1
        }, in: app, timeout: fixtureTimeout)

        // 3-element tuples are not Equatable; assert components (Swift arity limit).
        let muteCounts = Self.segmentCounts(from: barValue)
        XCTAssertEqual(muteCounts?.ready, 12, "Complete fixture ready count; got \(barValue)")
        XCTAssertEqual(muteCounts?.processing, 0, "Complete fixture processing count; got \(barValue)")
        XCTAssertEqual(muteCounts?.pending, 0, "Complete fixture pending count; got \(barValue)")
        XCTAssertGreaterThanOrEqual(
            Self.muteMarkerCount(from: barValue) ?? -1,
            1,
            "muteMarkers count must be ≥ 1 when profanity mute intervals are cached"
        )
        XCTAssertEqual(
            barValue,
            Self.muteMarkersPinnedValue,
            "Pinned mute-markers fixture must expose exact terminal AX string"
        )
        XCTAssertNotEqual(
            barValue,
            Self.progressiveMidRunValue,
            "Complete snapshot must not report in-flight segment triple"
        )
    }

    // MARK: - AC4

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

        // 3-element tuples are not Equatable; assert components (Swift arity limit).
        let adsCounts = Self.segmentCounts(from: barValue)
        XCTAssertEqual(adsCounts?.ready, 12, "Ad-only fixture ready count; got \(barValue)")
        XCTAssertEqual(adsCounts?.processing, 0, "Ad-only fixture processing count; got \(barValue)")
        XCTAssertEqual(adsCounts?.pending, 0, "Ad-only fixture pending count; got \(barValue)")
        XCTAssertEqual(Self.muteMarkerCount(from: barValue), 0)

        let bar = element("playback.superSeekBar", in: app)
        XCTAssertTrue(bar.exists, "playback.superSeekBar must exist on ads-only complete fixture")
        XCTAssertTrue(
            element("playback.elapsed", in: app).waitForExistence(timeout: fixtureTimeout),
            "playback.elapsed must remain present — no regression to cleaning-on chrome"
        )
    }

    // MARK: - UX regression (slice-27-ux.md)

    @MainActor
    func testProgressiveMidRunOmitsMuteMarkersKey() throws {
        let app = launchFixtureApp("-UITestFixtureProgressivePlayback")
        navigateToExpandedFullPlayer(app)
        startPlaybackIfNeeded(app)

        let barValue = waitForSuperSeekBarValue(
            equalTo: Self.progressiveMidRunValue,
            in: app,
            timeout: fixtureTimeout
        )
        XCTAssertFalse(
            barValue.contains("muteMarkers:"),
            "In-flight progressive bar must omit muteMarkers key"
        )
    }

    @MainActor
    func testProgressiveTerminalIncludesMuteMarkers() throws {
        let app = launchFixtureApp("-UITestFixtureProgressivePlayback")
        navigateToExpandedFullPlayer(app)
        startPlaybackIfNeeded(app)

        let barValue = waitForSuperSeekBarValue(
            equalTo: Self.progressiveTerminalValue,
            in: app,
            timeout: progressiveTerminalTimeout
        )
        XCTAssertEqual(Self.muteMarkerCount(from: barValue), 2)
    }

    @MainActor
    func testCleaningOffOmitsTimelineAndMarkers() throws {
        let app = launchFixtureApp("-UITestFixtureMuteMarkers")
        navigateToEpisodeList(app)
        ensureChannelCleaningOff(in: app)

        let episodeCell = element("episodeCell_0", in: app)
        XCTAssertTrue(episodeCell.waitForExistence(timeout: fixtureTimeout))
        episodeCell.tap()

        let miniPlayer = element("miniPlayer", in: app)
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: fixtureTimeout))
        miniPlayer.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()

        let bar = element("playback.superSeekBar", in: app)
        XCTAssertTrue(bar.waitForExistence(timeout: fixtureTimeout))

        if let value = Self.accessibilityValue(for: "playback.superSeekBar", in: app) {
            XCTAssertFalse(value.contains("ready:"), "Cleaning off must omit timeline AX")
            XCTAssertFalse(value.contains("muteMarkers:"), "Cleaning off must omit muteMarkers AX")
        }
    }

    // MARK: - Launch + navigation (slice-27-ux.md)

    @MainActor
    private func launchFixtureApp(_ argument: String) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments.append(argument)
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
        let channelToggle = app.switches["channelCleaningToggle"]
        guard channelToggle.waitForExistence(timeout: fixtureTimeout) else { return }
        guard (channelToggle.value as? String) != "on" else { return }
        channelToggle.tap()
        let onExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "on"),
            object: channelToggle
        )
        _ = XCTWaiter().wait(for: [onExpectation], timeout: 2)
    }

    @MainActor
    private func ensureChannelCleaningOff(in app: XCUIApplication) {
        let channelToggle = app.switches["channelCleaningToggle"]
        guard channelToggle.waitForExistence(timeout: fixtureTimeout) else { return }
        guard (channelToggle.value as? String) == "on" else { return }
        channelToggle.tap()
        let offExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "off"),
            object: channelToggle
        )
        _ = XCTWaiter().wait(for: [offExpectation], timeout: 2)
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
