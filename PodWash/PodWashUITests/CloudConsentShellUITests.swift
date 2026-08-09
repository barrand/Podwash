//
//  CloudConsentShellUITests.swift
//  PodWashUITests
//
//  Regression coverage for the Settings-owned Gemini ad-skip consent flow.
//

import XCTest

final class CloudConsentShellUITests: XCTestCase {
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

        let download = app.buttons["downloadButton_0"]
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        download.tap()
        XCTAssertTrue(app.descendants(matching: .any)["cloudTranscriptConsentSheet"].waitForExistence(timeout: 5))
        app.buttons["cloudConsentDeclineButton"].tap()

        let downloaded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "downloaded"),
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

        let download = app.buttons["downloadButton_0"]
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        XCTAssertEqual(download.value as? String, "notDownloaded")
        download.tap()

        let consent = app.descendants(matching: .any)["cloudTranscriptConsentSheet"]
        XCTAssertTrue(consent.waitForExistence(timeout: 5), "First download must show the ad-skip disclosure")
        app.buttons["cloudConsentEnableButton"].tap()
        XCTAssertFalse(consent.waitForExistence(timeout: 2))

        let downloaded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "downloaded"),
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

        let settingsButton = app.buttons["settingsButton"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.tap()

        let skipAds = app.switches["unrelatedContentToggle"]
        XCTAssertTrue(skipAds.waitForExistence(timeout: 10))
        XCTAssertEqual(skipAds.value as? String, "0", "Reset fixture must start with Skip ads off")
        skipAds.tap()

        let consent = app.descendants(matching: .any)["cloudTranscriptConsentSheet"]
        XCTAssertTrue(consent.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Do you want PodWash to automatically skip ads?"].exists)

        app.buttons["cloudConsentEnableButton"].tap()
        XCTAssertFalse(consent.waitForExistence(timeout: 2), "Acceptance must dismiss the consent sheet")
        XCTAssertEqual(app.switches["unrelatedContentToggle"].value as? String, "1")
        XCTAssertEqual(app.switches["cloudTranscriptProcessingToggle"].value as? String, "1")

        let back = app.navigationBars.buttons["Back"]
        if back.exists {
            back.tap()
        } else {
            app.buttons["Back"].tap()
        }
        XCTAssertTrue(library.waitForExistence(timeout: 5), "Library shell must remain usable after dismissal")
    }
}
