//
//  CleaningSummaryModelTests.swift
//  PodWashTests
//
//  Slice 29 — Episode cleaning summary model (ADR-025 §3–§4). AC1–AC3.
//  Golden values hand-computed from docs/slices/slice-29-episode-cleaning-summary.md
//  pinned interval table and Fixtures/cleaning/cleaning-summary-provenance.md —
//  not generated from implementation under test.
//
//  Until CleaningSummaryModel / EpisodeCleaningSummary exist (Engineer), this file
//  fails to compile — intended TDD red state.
//

import XCTest
@testable import PodWash

final class CleaningSummaryModelTests: XCTestCase {

    private let durationTolerance = 0.001

    /// Pinned fixture intervals (slice-29 AC1 / ADR-025 §3).
    private var pinnedFixtureIntervals: [CensorInterval] {
        [
            CensorInterval(start: 10.0, end: 11.0, action: .mute, source: .profanity),
            CensorInterval(start: 20.0, end: 21.5, action: .mute, source: .profanity),
            CensorInterval(start: 30.0, end: 90.0, action: .skip, source: .unrelatedContent),
            CensorInterval(start: 100.0, end: 130.0, action: .skip, source: .unrelatedContent),
        ]
    }

    // MARK: - AC1

    func testPinnedFixtureCountsAndFormattedMinutes() {
        let summary = CleaningSummaryModel.summary(from: pinnedFixtureIntervals)

        XCTAssertEqual(summary.profanitySectionCount, 2)
        XCTAssertEqual(summary.adSectionCount, 2)
        XCTAssertEqual(
            summary.adDurationSeconds,
            90.0,
            accuracy: durationTolerance,
            "ad duration = (90−30) + (130−100) = 90.0 s"
        )
        XCTAssertEqual(summary.formattedAdMinutes, "1.5 min")
        XCTAssertEqual(
            CleaningSummaryModel.accessibilityValue(from: summary),
            "profanity:2,ads:2,adMinutes:1.5"
        )
    }

    // MARK: - AC2

    func testEmptyAndSourceFilters() {
        let emptySummary = CleaningSummaryModel.summary(from: [])
        XCTAssertEqual(emptySummary.profanitySectionCount, 0)
        XCTAssertEqual(emptySummary.adSectionCount, 0)
        XCTAssertEqual(emptySummary.adDurationSeconds, 0.0, accuracy: durationTolerance)
        XCTAssertEqual(emptySummary.formattedAdMinutes, "0.0 min")
        XCTAssertEqual(
            CleaningSummaryModel.accessibilityValue(from: emptySummary),
            "profanity:0,ads:0,adMinutes:0.0"
        )

        let skipOnlyProfanity = [
            CensorInterval(start: 5.0, end: 6.0, action: .skip, source: .profanity),
        ]
        let profanitySummary = CleaningSummaryModel.summary(from: skipOnlyProfanity)
        XCTAssertEqual(
            profanitySummary.profanitySectionCount,
            1,
            "skip-only profanity intervals still count as cleaned profanity sections"
        )
        XCTAssertEqual(profanitySummary.adSectionCount, 0)
        XCTAssertEqual(profanitySummary.adDurationSeconds, 0.0, accuracy: durationTolerance)

        let adsOnly = [
            CensorInterval(start: 10.0, end: 25.0, action: .skip, source: .unrelatedContent),
        ]
        let adsSummary = CleaningSummaryModel.summary(from: adsOnly)
        XCTAssertEqual(
            adsSummary.profanitySectionCount,
            0,
            ".unrelatedContent alone must not increment profanity count"
        )
        XCTAssertEqual(adsSummary.adSectionCount, 1)
        XCTAssertEqual(adsSummary.adDurationSeconds, 15.0, accuracy: durationTolerance)
    }

    // MARK: - AC3

    func testAdMinutesRoundsHalfUpToOneDecimal() {
        XCTAssertEqual(
            CleaningSummaryModel.formattedAdMinutes(adDurationSeconds: 45.0),
            "0.8 min",
            "45/60 = 0.75 → round half up to one decimal → 0.8 min (ADR-025 §4)"
        )

        let summary = CleaningSummaryModel.summary(from: [
            CensorInterval(start: 0.0, end: 45.0, action: .skip, source: .unrelatedContent),
        ])
        XCTAssertEqual(summary.formattedAdMinutes, "0.8 min")
        XCTAssertEqual(
            CleaningSummaryModel.accessibilityValue(from: summary),
            "profanity:0,ads:1,adMinutes:0.8"
        )
    }
}
