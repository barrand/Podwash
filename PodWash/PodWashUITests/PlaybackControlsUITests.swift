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
        assertSleepTimerPreset(
            sleepTimerButton,
            accessibilityValue: "off",
            visibleLabel: "Off",
            context: "at launch"
        )

        let armedSequence: [(accessibilityValue: String, visibleLabel: String)] = [
            ("900", "15m"),
            ("1800", "30m"),
            ("3600", "60m"),
        ]
        for expected in armedSequence {
            sleepTimerButton.tap()
            assertSleepTimerPreset(
                sleepTimerButton,
                accessibilityValue: expected.accessibilityValue,
                visibleLabel: expected.visibleLabel,
                context: "after tap to \(expected.accessibilityValue)"
            )
        }

        sleepTimerButton.tap()
        assertSleepTimerPreset(
            sleepTimerButton,
            accessibilityValue: "off",
            visibleLabel: "Off",
            context: "after fourth tap from 60m"
        )
    }

    private func assertSleepTimerPreset(
        _ button: XCUIElement,
        accessibilityValue: String,
        visibleLabel: String,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            button.value as? String,
            accessibilityValue,
            "sleepTimerButton accessibilityValue must be \(accessibilityValue) \(context)",
            file: file,
            line: line
        )
        // Assert visible preset text under the button (label or identifier).
        let labelText = button.staticTexts.matching(
            NSPredicate(
                format: "label == %@ OR identifier == %@",
                visibleLabel,
                visibleLabel
            )
        ).firstMatch
        XCTAssertTrue(
            labelText.waitForExistence(timeout: 2),
            "sleepTimerButton visible label must be \(visibleLabel) \(context)",
            file: file,
            line: line
        )
    }
}
