//
//  BrandingUITests.swift
//  PodWashUITests
//
//  Slice 21 — Visual identity UI tests (slice-21-ux.md). AC5–AC8.
//
//  Launch fixture: -UITestFixtureBranding only (exclusive; no network/RSS/tab bar).
//  Accessibility contracts per ADR-019 §4: brandWordmark, themePrimaryAccent,
//  themePrimarySurface, settingsButton — playback.playPause transport ids unchanged.
//
//  Until FixtureBranding routing and BrandingChromeView exist (Engineer),
//  these tests fail at runtime — intended TDD red state after compile.
//

import XCTest

final class BrandingUITests: XCTestCase {

    private let fixtureTimeout: TimeInterval = 10

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Launch helpers

    private func launchBrandingApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("-UITestFixtureBranding")
        app.launch()
        return app
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    // MARK: - AC5: brandWordmark label

    @MainActor
    func testBrandWordmarkLabelMatchesDisplayName() throws {
        let app = launchBrandingApp()
        let wordmark = element("brandWordmark", in: app)
        XCTAssertTrue(
            wordmark.waitForExistence(timeout: fixtureTimeout),
            "brandWordmark must appear within \(fixtureTimeout)s"
        )
        XCTAssertEqual(
            wordmark.label,
            "PodWash",
            "brandWordmark accessibilityLabel must equal approved display name (exact, case-sensitive)"
        )
    }

    // MARK: - AC6: themePrimaryAccent sentinel (transport ids unchanged)

    @MainActor
    func testPrimaryPlayControlUsesBrandAccent() throws {
        let app = launchBrandingApp()

        let playPause = app.buttons["playback.playPause"]
        XCTAssertTrue(
            playPause.waitForExistence(timeout: fixtureTimeout),
            "playback.playPause must appear within \(fixtureTimeout)s"
        )

        let accentSentinel = element("themePrimaryAccent", in: app)
        XCTAssertTrue(accentSentinel.exists, "themePrimaryAccent sentinel must exist")
        XCTAssertEqual(
            accentSentinel.value as? String,
            "brandPrimary",
            "themePrimaryAccent must expose brandPrimary accessibilityValue"
        )

        let transportValue = playPause.value as? String ?? ""
        XCTAssertTrue(
            transportValue == "paused" || transportValue == "playing",
            "playback.playPause must report transport state (paused/playing), not brandPrimary; got \(transportValue)"
        )
    }

    // MARK: - AC7: themePrimarySurface sentinel

    @MainActor
    func testRootChromeSurfaceTokenApplied() throws {
        let app = launchBrandingApp()
        let surface = element("themePrimarySurface", in: app)
        XCTAssertTrue(
            surface.waitForExistence(timeout: fixtureTimeout),
            "themePrimarySurface must appear within \(fixtureTimeout)s"
        )
        XCTAssertEqual(
            surface.value as? String,
            "1",
            "themePrimarySurface must report 1 when BrandTheme.surface is applied"
        )
    }

    // MARK: - AC8: settings entry hittable

    @MainActor
    func testSettingsEntryReachable() throws {
        let app = launchBrandingApp()
        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(
            settings.waitForExistence(timeout: fixtureTimeout),
            "settingsButton must appear within \(fixtureTimeout)s"
        )

        let predicate = NSPredicate(format: "isHittable == true")
        let hittableExpectation = XCTNSPredicateExpectation(predicate: predicate, object: settings)
        let result = XCTWaiter().wait(for: [hittableExpectation], timeout: fixtureTimeout)
        XCTAssertEqual(
            result,
            .completed,
            "settingsButton must be hittable in branding fixture"
        )
        XCTAssertTrue(settings.isHittable, "settingsButton must remain hittable after chrome pass")
    }
}
