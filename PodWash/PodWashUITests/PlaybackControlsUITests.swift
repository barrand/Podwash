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

    // MARK: - Slice 12 — speed + sleep timer (AC4–AC5)

    @MainActor
    func testSpeedButtonCyclesRates() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-UITestFixtureAudio")
        app.launch()

        let speedButton = app.buttons["speedButton"]
        XCTAssertTrue(speedButton.waitForExistence(timeout: 10))
        XCTAssertEqual(speedButton.value as? String, "1.0", "Default rate must be 1.0")

        let expectedSequence = ["1.25", "1.5", "2.0", "3.0", "0.75", "1.0"]
        for expected in expectedSequence {
            speedButton.tap()
            XCTAssertEqual(
                speedButton.value as? String,
                expected,
                "speedButton must cycle to \(expected)"
            )
        }
    }

    @MainActor
    func testSleepTimerButtonCyclesPresets() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-UITestFixtureAudio")
        app.launch()

        let sleepTimerButton = app.buttons["sleepTimerButton"]
        XCTAssertTrue(sleepTimerButton.waitForExistence(timeout: 10))
        XCTAssertEqual(sleepTimerButton.value as? String, "off", "Sleep timer must start off")

        let expectedSequence = ["900", "1800", "3600"]
        for expected in expectedSequence {
            sleepTimerButton.tap()
            XCTAssertEqual(
                sleepTimerButton.value as? String,
                expected,
                "sleepTimerButton must cycle to \(expected)"
            )
        }
    }
}
