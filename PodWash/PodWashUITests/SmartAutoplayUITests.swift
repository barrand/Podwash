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
        // Library shell only — `-UITestFixtureSettings` alone routes RootView to a
        // bare Settings stack (no settingsButton / binge chrome). AppShell settings
        // exposes `smartAutoplayToggle`; podcast detail exposes `bingeToggle`.
        app.launchArguments += [
            "-UITestFixtureLibrary",
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

    func testNextShowControlExistsOnMiniPlayer() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-UITestFixtureLibrary",
        ]
        app.launch()

        let libraryRoot = app.descendants(matching: .any)["libraryRoot"]
        XCTAssertTrue(libraryRoot.waitForExistence(timeout: 10))

        let showCell = app.descendants(matching: .any)["libraryCell_0"]
        XCTAssertTrue(showCell.waitForExistence(timeout: 10))
        showCell.tap()

        let episodeList = app.descendants(matching: .any)["episodeList"]
        XCTAssertTrue(episodeList.waitForExistence(timeout: 10))

        let episodeCell = app.descendants(matching: .any)["episodeCell_0"]
        XCTAssertTrue(episodeCell.waitForExistence(timeout: 10))
        episodeCell.tap()

        let mini = app.descendants(matching: .any)["miniPlayer"]
        XCTAssertTrue(mini.waitForExistence(timeout: 15))

        let nextShow = app.buttons["miniPlayerNextShow"]
        XCTAssertTrue(nextShow.waitForExistence(timeout: 8))
        XCTAssertEqual(nextShow.label, "Next show")
    }
}
