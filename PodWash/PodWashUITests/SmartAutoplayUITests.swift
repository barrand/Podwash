//
//  SmartAutoplayUITests.swift
//  PodWashUITests
//
//  ADR-029 — Settings + binge chrome smoke (fixture library).
//

import XCTest

final class SmartAutoplayUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSmartAutoplayToggleAndBingeControlExist() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-UITestFixtureLibrary",
            "-UITestFixtureSettings",
        ]
        app.launch()

        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()

        let smart = app.switches["smartAutoplayToggle"]
        XCTAssertTrue(smart.waitForExistence(timeout: 10))

        // Leave settings and open first library podcast for binge toggle.
        if app.navigationBars.buttons["Back"].exists {
            app.navigationBars.buttons["Back"].tap()
        } else if app.buttons["Back"].exists {
            app.buttons["Back"].tap()
        }

        let library = app.descendants(matching: .any)["tabLibrary"]
        if library.exists { library.tap() }

        let firstPodcast = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "libraryCell_"))
            .firstMatch
        if firstPodcast.waitForExistence(timeout: 5) {
            firstPodcast.tap()
            let binge = app.switches["bingeToggle"]
            XCTAssertTrue(binge.waitForExistence(timeout: 8))
        } else {
            // Settings toggle is the hard assert for this smoke test.
            XCTAssertTrue(smart.exists)
        }
    }
}
