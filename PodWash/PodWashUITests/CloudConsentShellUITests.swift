//
//  CloudConsentShellUITests.swift
//  PodWashUITests
//
//  Regression coverage for the Settings-owned Jev ad-skip consent flow.
//

import XCTest

final class CloudConsentShellUITests: XCTestCase {
    func testPresetPickerDefaultsToObviousAndLabelsExperimentalChoices() throws {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments += ["-UITestFixtureLibrary", "-UITestResetSettings"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["libraryRoot"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Settings"].tap()
        let settings = app.descendants(matching: .any)["settingsRoot"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))

        let picker = app.descendants(matching: .any)["skipPresetPicker"]
        for _ in 0..<4 where !picker.exists { settings.swipeUp() }
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue((picker.value as? String)?.contains("Default") == true)
        picker.tap()

        XCTAssertTrue(app.descendants(matching: .any)["skipPresetSelection"].waitForExistence(timeout: 5))
        let obvious = app.buttons["skipPreset_obvious"]
        let more = app.buttons["skipPreset_more"]
        let most = app.buttons["skipPreset_most"]
        XCTAssertTrue(obvious.exists)
        XCTAssertTrue(more.exists)
        XCTAssertTrue(most.exists)
        XCTAssertTrue((obvious.value as? String)?.contains("Selected") == true)
        XCTAssertTrue((more.value as? String)?.contains("Experimental") == true)
        XCTAssertTrue((most.value as? String)?.contains("Experimental") == true)

        more.tap()
        XCTAssertTrue((more.value as? String)?.contains("Selected") == true)
    }

    func testFirstManualDownloadContinuesWhenConsentIsDeclined() throws {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments += [
            "-UITestFixtureLibrary",
            "-UITestFixtureDownload",
            "-UITestResetSettings"
        ]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["libraryRoot"].waitForExistence(timeout: 10))
        let show = app.descendants(matching: .any)["libraryCell_0"]
        XCTAssertTrue(show.waitForExistence(timeout: 5))
        show.tap()

        let download = app.buttons["episodePrimary_lib-0-fixture-ep-001"]
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        download.tap()
        XCTAssertTrue(app.descendants(matching: .any)["cloudTranscriptConsentSheet"].waitForExistence(timeout: 5))
        app.buttons["cloudConsentDeclineButton"].tap()

        let downloaded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label == %@", "Play"),
            object: download
        )
        XCTAssertEqual(XCTWaiter().wait(for: [downloaded], timeout: 5), .completed)
    }

    func testFirstManualDownloadPresentsConsentAndContinuesAfterAcceptance() throws {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments += [
            "-UITestFixtureLibrary",
            "-UITestFixtureDownload",
            "-UITestResetSettings"
        ]
        app.launch()

        let library = app.descendants(matching: .any)["libraryRoot"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        let show = app.descendants(matching: .any)["libraryCell_0"]
        XCTAssertTrue(show.waitForExistence(timeout: 5))
        show.tap()

        let download = app.buttons["episodePrimary_lib-0-fixture-ep-001"]
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        XCTAssertEqual(download.label, "Download")
        download.tap()

        let consent = app.descendants(matching: .any)["cloudTranscriptConsentSheet"]
        XCTAssertTrue(consent.waitForExistence(timeout: 5), "First download must show the ad-skip disclosure")
        app.buttons["cloudConsentEnableButton"].tap()
        XCTAssertFalse(consent.waitForExistence(timeout: 2))

        let downloaded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label == %@", "Play"),
            object: download
        )
        XCTAssertEqual(XCTWaiter().wait(for: [downloaded], timeout: 5), .completed)
    }

    func testAcceptingAdSkipsConsentInLibraryShellEnablesBothSettings() throws {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments += [
            "-UITestFixtureLibrary",
            "-UITestResetSettings"
        ]
        app.launch()

        let library = app.descendants(matching: .any)["libraryRoot"]
        XCTAssertTrue(library.waitForExistence(timeout: 10), "Seeded Library shell must launch")

        let settingsButton = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.tap()

        let skipAds = app.switches["unrelatedContentToggle"]
        XCTAssertTrue(skipAds.waitForExistence(timeout: 10))
        XCTAssertEqual(skipAds.value as? String, "0", "Reset fixture must start with Skip ads off")
        skipAds.tap()

        let consent = app.descendants(matching: .any)["cloudTranscriptConsentSheet"]
        XCTAssertTrue(consent.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["cloudConsentExplanation"].exists)

        app.buttons["cloudConsentEnableButton"].tap()
        XCTAssertFalse(consent.waitForExistence(timeout: 2), "Acceptance must dismiss the consent sheet")
        XCTAssertEqual(app.switches["unrelatedContentToggle"].value as? String, "1")
        XCTAssertEqual(app.switches["cloudTranscriptProcessingToggle"].value as? String, "1")

        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(library.waitForExistence(timeout: 5), "Library shell must remain usable after dismissal")
    }
}
