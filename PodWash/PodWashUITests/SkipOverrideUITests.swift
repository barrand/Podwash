//
//  SkipOverrideUITests.swift
//  PodWashUITests
//
//  Slice 19 — Skip-override banner + unrelated-content toggle UI tests
//  (slice-19-ux.md). AC4–AC5.
//
//  Until FixtureSkipOverride routing, skipOverrideBanner, unrelatedContentToggle,
//  and channelUnrelatedContentToggle exist (Engineer, later effort), these tests
//  fail at runtime — intended TDD red state after compile.
//

import XCTest

final class SkipOverrideUITests: XCTestCase {

    private let bannerRoundingTolerance = 1

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: arguments)
        app.launch()
        return app
    }

    private func bannerValueContainsExpectedSeconds(_ value: String?, expected: Int) -> Bool {
        guard let value else { return false }
        for offset in -bannerRoundingTolerance...bannerRoundingTolerance {
            if value.contains("\(expected + offset)") {
                return true
            }
        }
        return false
    }

    // MARK: - AC4: skip-override banner appears and tap replays segment

    @MainActor
    func testOverrideBannerAppearsAndReplay() throws {
        let app = launchApp(arguments: ["-UITestFixtureSkipOverride"])

        let playPause = app.descendants(matching: .any)["playback.playPause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 10), "Fixture must auto-play via playback.playPause")

        let banner = app.descendants(matching: .any)["skipOverrideBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 5), "skipOverrideBanner must appear within 5s of stubbed skip")

        let bannerValue = banner.value as? String
        XCTAssertTrue(
            bannerValueContainsExpectedSeconds(bannerValue, expected: 3),
            "Banner accessibilityValue must contain rounded skip seconds (~3); got: \(bannerValue ?? "nil")"
        )

        banner.tap()

        let elapsed = app.descendants(matching: .any)["playback.elapsed"]
        let replayed = XCTNSPredicateExpectation(
            predicate: NSPredicate(block: { _, _ in
                let seconds = Int(elapsed.value as? String ?? "0") ?? 0
                return seconds >= 2 && seconds <= 5
            }),
            object: elapsed
        )
        XCTAssertEqual(XCTWaiter().wait(for: [replayed], timeout: 3), .completed)

        XCTAssertEqual(playPause.value as? String, "playing", "Playback must remain playing after override tap")
    }

    // MARK: - AC5: global unrelated-content toggle default off

    @MainActor
    func testUnrelatedContentGlobalDefaultOff() throws {
        let app = launchApp(arguments: ["-UITestFixtureSettings"])

        let root = app.descendants(matching: .any)["settingsRoot"]
        XCTAssertTrue(root.waitForExistence(timeout: 10))

        let globalToggle = app.descendants(matching: .any)["unrelatedContentToggle"]
        XCTAssertTrue(globalToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(globalToggle.value as? String, "0", "Fresh store: unrelatedContentToggle must be off")
    }

    // MARK: - AC5: per-channel unrelated-content toggle hidden (task-023)

    @MainActor
    func testChannelToggleDefaultOff() throws {
        let app = launchApp(arguments: ["-UITestFixtureFeed"])

        let episodeList = app.descendants(matching: .any)["episodeList"]
        XCTAssertTrue(episodeList.waitForExistence(timeout: 10))

        let channelToggle = app.descendants(matching: .any)["channelUnrelatedContentToggle"]
        XCTAssertFalse(
            channelToggle.waitForExistence(timeout: 5),
            "channelUnrelatedContentToggle must not appear on podcast detail"
        )
        XCTAssertFalse(channelToggle.exists)
    }
}
