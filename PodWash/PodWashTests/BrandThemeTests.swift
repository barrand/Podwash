//
//  BrandThemeTests.swift
//  PodWashTests
//
//  Slice 21 — Visual identity & branding (ADR-019). AC1–AC4.
//
//  Fixture provenance:
//  - sRGB components pinned in docs/slices/slice-21-visual-identity.md (user 2026-07-10);
//    hand-transcribed from product decisions — not generated from BrandTheme implementation.
//  - CFBundleDisplayName "PodWash" — same slice pin (exact, case-sensitive).
//  - AppIcon ios-marketing contract — Apple asset-catalog rules + slice AC4 structural gate.
//
//  Until BrandTheme.swift, AccentColor catalog values, CFBundleDisplayName, and App Icon
//  marketing PNG exist (Engineer), these tests fail to compile or at runtime — intended TDD.
//

import UIKit
import XCTest
@testable import PodWash

final class BrandThemeTests: XCTestCase {

    /// Per-channel tolerance from slice AC1 / AC2 (± 0.001).
    private let componentTolerance = 0.001

    // MARK: - Helpers

    private func assertComponent(
        _ actual: Double,
        _ expected: Double,
        name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            actual,
            expected,
            accuracy: componentTolerance,
            "\(name) sRGB component",
            file: file,
            line: line
        )
    }

    /// Resolves `PodWash/Assets.xcassets/AppIcon.appiconset` relative to the test source tree.
    private func appIconAppiconsetURL(file: StaticString = #filePath, line: UInt = #line) -> URL {
        let testFile = URL(fileURLWithPath: String(describing: file))
        let podWashProjectDir = testFile
            .deletingLastPathComponent() // PodWashTests
            .deletingLastPathComponent() // PodWash (xcodeproj parent)
        return podWashProjectDir
            .appendingPathComponent("PodWash/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
    }

    // MARK: - AC1: semantic token sRGB components

    func testSemanticTokensMatchApprovedSRGB() {
        assertComponent(BrandTheme.primaryRed, 0.165, name: "primary.red")
        assertComponent(BrandTheme.primaryGreen, 0.616, name: "primary.green")
        assertComponent(BrandTheme.primaryBlue, 0.561, name: "primary.blue")

        assertComponent(BrandTheme.accentRed, 0.914, name: "accent.red")
        assertComponent(BrandTheme.accentGreen, 0.769, name: "accent.green")
        assertComponent(BrandTheme.accentBlue, 0.416, name: "accent.blue")

        assertComponent(BrandTheme.surfaceRed, 0.059, name: "surface.red")
        assertComponent(BrandTheme.surfaceGreen, 0.078, name: "surface.green")
        assertComponent(BrandTheme.surfaceBlue, 0.098, name: "surface.blue")

        assertComponent(BrandTheme.onPrimaryRed, 1.0, name: "onPrimary.red")
        assertComponent(BrandTheme.onPrimaryGreen, 1.0, name: "onPrimary.green")
        assertComponent(BrandTheme.onPrimaryBlue, 1.0, name: "onPrimary.blue")

        assertComponent(BrandTheme.onSurfaceRed, 0.910, name: "onSurface.red")
        assertComponent(BrandTheme.onSurfaceGreen, 0.918, name: "onSurface.green")
        assertComponent(BrandTheme.onSurfaceBlue, 0.929, name: "onSurface.blue")
    }

    // MARK: - AC2: AccentColor asset matches BrandTheme.primary

    func testAccentColorAssetMatchesPrimary() {
        guard let accent = UIColor(named: "AccentColor", in: Bundle.main, compatibleWith: nil) else {
            XCTFail("AccentColor asset missing from app catalog")
            return
        }

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard accent.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            XCTFail("AccentColor must resolve to sRGB color space")
            return
        }

        assertComponent(Double(red), BrandTheme.primaryRed, name: "AccentColor.red")
        assertComponent(Double(green), BrandTheme.primaryGreen, name: "AccentColor.green")
        assertComponent(Double(blue), BrandTheme.primaryBlue, name: "AccentColor.blue")
    }

    // MARK: - AC3: bundle display name matches approved string

    func testBundleDisplayNameMatchesApproved() {
        let bundleDisplayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        XCTAssertEqual(
            bundleDisplayName,
            "PodWash",
            "CFBundleDisplayName must equal approved display name (exact, case-sensitive)"
        )
        XCTAssertEqual(
            BrandTheme.approvedDisplayName,
            "PodWash",
            "BrandTheme.approvedDisplayName must equal CFBundleDisplayName"
        )
    }

    // MARK: - AC4: App Icon ios-marketing 1024 PNG on disk

    func testAppIconMarketingAssetPresent() {
        let appiconsetURL = appIconAppiconsetURL()
        let contentsURL = appiconsetURL.appendingPathComponent("Contents.json")

        guard FileManager.default.fileExists(atPath: contentsURL.path) else {
            XCTFail("AppIcon.appiconset/Contents.json missing at \(contentsURL.path)")
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: contentsURL)
        } catch {
            XCTFail("Could not read AppIcon Contents.json: \(error)")
            return
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let images = json["images"] as? [[String: Any]]
        else {
            XCTFail("AppIcon Contents.json must decode images array")
            return
        }

        let marketingEntry = images.first { entry in
            (entry["idiom"] as? String) == "ios-marketing"
                && (entry["size"] as? String) == "1024x1024"
        }

        guard let marketingEntry else {
            XCTFail("AppIcon Contents.json must list ios-marketing 1024x1024 entry")
            return
        }

        guard let filename = marketingEntry["filename"] as? String, !filename.isEmpty else {
            XCTFail("ios-marketing entry must name a committed PNG filename")
            return
        }

        let pngURL = appiconsetURL.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: pngURL.path) else {
            XCTFail("App Icon marketing PNG missing at \(pngURL.path)")
            return
        }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: pngURL.path)
        } catch {
            XCTFail("Could not read App Icon PNG attributes: \(error)")
            return
        }

        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(
            byteCount,
            1024,
            "App Icon marketing PNG must be > 1024 bytes (guards empty placeholder); got \(byteCount)"
        )
    }
}
