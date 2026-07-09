//
//  PodWashUITests.swift
//  PodWashUITests
//
//  Slice 01 — Foundation. A single fast launch test. The template
//  `testLaunchPerformance` (XCTApplicationLaunchMetric) was dropped: it
//  relaunches the app several times and adds ~2 min per run for no
//  functional signal. Total UI test wall time must stay well under 120 s.
//

import XCTest

final class PodWashUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 30),
            "PodWash should reach the foreground after launch"
        )
    }
}
