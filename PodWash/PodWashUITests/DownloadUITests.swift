//
//  DownloadUITests.swift
//  PodWashUITests
//
//  Slice 10 — Download/delete button UI tests (slice-10-downloads-ux.md). AC5.
//

import XCTest

final class DownloadUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDownloadAndDeleteButtonFlow() throws {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-UITestFixtureFeed", "-UITestFixtureDownload"])
        app.launch()

        let episodeList = app.descendants(matching: .any)["episodeList"]
        XCTAssertTrue(episodeList.waitForExistence(timeout: 10))

        let downloadButton = app.buttons["downloadButton_0"]
        XCTAssertTrue(downloadButton.waitForExistence(timeout: 5))
        XCTAssertEqual(downloadButton.value as? String, "notDownloaded")
        XCTAssertFalse(app.descendants(matching: .any)["downloadProgress_0"].exists)

        downloadButton.tap()

        let downloadedExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "downloaded"),
            object: downloadButton
        )
        XCTAssertEqual(XCTWaiter().wait(for: [downloadedExpectation], timeout: 5), .completed)
        XCTAssertFalse(app.descendants(matching: .any)["downloadProgress_0"].exists)

        downloadButton.tap()

        let notDownloadedExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "notDownloaded"),
            object: downloadButton
        )
        XCTAssertEqual(XCTWaiter().wait(for: [notDownloadedExpectation], timeout: 2), .completed)
    }
}
