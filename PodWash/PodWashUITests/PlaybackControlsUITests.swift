//
//  PlaybackControlsUITests.swift
//  PodWashUITests
//
//  Slice 03 — Player shell UI tests (see slice-03-ux.md).
//

import XCTest

final class PlaybackControlsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPlayPauseSeekButtons() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-UITestFixtureAudio")
        app.launch()

        let playPause = app.buttons["playback.playPause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 10))

        XCTAssertEqual(playPause.value as? String, "paused")

        playPause.tap()
        XCTAssertEqual(playPause.value as? String, "playing")

        playPause.tap()
        XCTAssertEqual(playPause.value as? String, "paused")

        let elapsed = app.staticTexts["playback.elapsed"]
        XCTAssertTrue(elapsed.waitForExistence(timeout: 5))
        let beforeSeek = Int(elapsed.value as? String ?? "0") ?? 0

        app.buttons["playback.seekForward15"].tap()

        let afterSeekExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(block: { _, _ in
                let current = Int(elapsed.value as? String ?? "0") ?? 0
                return current >= beforeSeek + 15
            }),
            object: elapsed
        )
        wait(for: [afterSeekExpectation], timeout: 5)
    }
}
