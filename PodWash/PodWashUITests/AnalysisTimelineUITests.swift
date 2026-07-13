//
//  AnalysisTimelineUITests.swift
//  PodWashUITests
//
//  Slice 20 — Analysis timeline UI tests (slice-20-ux.md). AC3–AC5.
//  Launch fixture: -UITestFixtureAnalysisTimeline (implies feed; stepped analyzer).
//

import XCTest

final class AnalysisTimelineUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - AC3

    @MainActor
    func testTimelineAppearsWithFirstSnapshot() throws {
        let app = launchTimelineFixtureApp()
        let expected = "ready:3,processing:1,pending:8"
        let firstSnapshot = expectation(description: "first timeline snapshot \(expected)")
        firstSnapshot.assertForOverFulfill = false

        // Poll on `.common` so we observe AX updates during XCUIElement.tap()'s
        // idle wait (default RunLoop.mode timers do not fire there). Predicates
        // registered via expectation(for:) only evaluate during explicit waits,
        // so ready:3 that appears solely inside tap() was previously missed.
        var sawFirst = false
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            guard !sawFirst, Self.timelineAccessibilityValue(in: app) == expected else { return }
            sawFirst = true
            timer.invalidate()
            firstSnapshot.fulfill()
        }
        RunLoop.current.add(timer, forMode: .common)

        enableChannelCleaning(in: app)

        defer { timer.invalidate() }
        wait(for: [firstSnapshot], timeout: 2)
        XCTAssertTrue(Self.analysisTimelineElement(in: app).exists)
    }

    // MARK: - AC4

    @MainActor
    func testTimelineCompletesAndRetiresProgress() throws {
        let app = launchTimelineFixtureApp()
        let expected = "ready:12,processing:0,pending:0"
        let terminalSnapshot = expectation(description: "terminal timeline snapshot")
        terminalSnapshot.assertForOverFulfill = false

        var sawTerminal = false
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            guard !sawTerminal, Self.timelineAccessibilityValue(in: app) == expected else { return }
            sawTerminal = true
            timer.invalidate()
            terminalSnapshot.fulfill()
        }
        RunLoop.current.add(timer, forMode: .common)

        enableChannelCleaning(in: app)

        defer { timer.invalidate() }
        wait(for: [terminalSnapshot], timeout: 5)

        XCTAssertFalse(app.descendants(matching: .any)["analysisProgress"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["cleaningBadge_episodeOn"].exists)
    }

    // MARK: - AC5

    @MainActor
    func testTimelineMidRunSnapshot() throws {
        let app = launchTimelineFixtureApp()
        let midExpected = "ready:6,processing:1,pending:5"
        let terminalExpected = "ready:12,processing:0,pending:0"
        let midRunSnapshot = expectation(description: "mid-run timeline snapshot")
        let terminalSnapshot = expectation(description: "terminal timeline snapshot")
        midRunSnapshot.assertForOverFulfill = false
        terminalSnapshot.assertForOverFulfill = false

        var sawMid = false
        var sawTerminal = false
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            let value = Self.timelineAccessibilityValue(in: app)
            if !sawMid, value == midExpected {
                sawMid = true
                midRunSnapshot.fulfill()
            }
            if !sawTerminal, value == terminalExpected {
                sawTerminal = true
                timer.invalidate()
                terminalSnapshot.fulfill()
            }
        }
        RunLoop.current.add(timer, forMode: .common)

        enableChannelCleaning(in: app)

        defer { timer.invalidate() }
        wait(for: [midRunSnapshot], timeout: 5)
        wait(for: [terminalSnapshot], timeout: 5)
    }

    // MARK: - Launch + interaction

    @MainActor
    private func launchTimelineFixtureApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("-UITestFixtureAnalysisTimeline")
        app.launch()

        let episodeList = app.descendants(matching: .any)["episodeList"]
        XCTAssertTrue(episodeList.waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func enableChannelCleaning(in app: XCUIApplication) {
        let channelToggle = app.switches["channelCleaningToggle"]
        XCTAssertTrue(channelToggle.waitForExistence(timeout: 5))

        let toggleHittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: channelToggle
        )
        // Hittable is usually false until after launch settle — safe for XCTWaiter.
        XCTAssertEqual(XCTWaiter().wait(for: [toggleHittable], timeout: 3), .completed)

        channelToggle.tap()
    }

    /// Current `analysisTimeline` accessibilityValue, or nil if missing.
    private static func timelineAccessibilityValue(in app: XCUIApplication) -> String? {
        let timeline = analysisTimelineElement(in: app)
        guard timeline.exists else { return nil }
        if let string = timeline.value as? String {
            return string
        }
        if let nsString = timeline.value as? NSString {
            return nsString as String
        }
        return nil
    }

    /// Slice-20 UX: prefer row-0 scope; fall back to global id / label.
    private static func analysisTimelineElement(in app: XCUIApplication) -> XCUIElement {
        let cell = app.cells["episodeCell_0"]
        let scoped = cell.descendants(matching: .any)["analysisTimeline"]
        if scoped.exists {
            return scoped
        }
        let global = app.descendants(matching: .any)["analysisTimeline"]
        if global.exists {
            return global
        }
        let scopedLabel = cell.descendants(matching: .any)["Analysis timeline"]
        if scopedLabel.exists {
            return scopedLabel
        }
        return app.descendants(matching: .any)["Analysis timeline"]
    }
}
