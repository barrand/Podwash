//
//  SuperSeekBarMuteMarkerTests.swift
//  PodWashTests
//
//  Slice 27 — Super seek bar mute marker model (ADR-023 §3, AC1–AC2).
//  Golden normalized values hand-computed from slice-27 AC pins (duration 120.0 s,
//  interval [10.0, 11.0) → 10/120 and 11/120) — not from implementation under test.
//
//  Until SuperSeekBarModel.muteMarkers and MuteMarker exist (Engineer), this file
//  fails to compile — intended TDD red state.
//

import XCTest
@testable import PodWash

final class SuperSeekBarMuteMarkerTests: XCTestCase {

    private let episodeDuration = 120.0
    private let normalizationTolerance = 0.001

    // MARK: - AC1: single mute interval normalized

    func testSingleMuteMarkerNormalized() {
        let intervals = [
            CensorInterval(start: 10.0, end: 11.0, action: .mute, source: .profanity),
        ]

        let markers = SuperSeekBarModel.muteMarkers(from: intervals, duration: episodeDuration)

        XCTAssertEqual(markers.count, 1, "One profanity mute interval must yield exactly one marker")

        let marker = markers[0]
        XCTAssertEqual(
            marker.startNormalized,
            10.0 / episodeDuration,
            accuracy: normalizationTolerance,
            "startNormalized must be 10/120 ± \(normalizationTolerance)"
        )
        XCTAssertEqual(
            marker.endNormalized,
            11.0 / episodeDuration,
            accuracy: normalizationTolerance,
            "endNormalized must be 11/120 ± \(normalizationTolerance)"
        )
    }

    // MARK: - AC2: count filter ignores ads and non-mute profanity

    func testMuteMarkerCountIgnoresAds() {
        let twoMutes = [
            CensorInterval(start: 1.0, end: 2.0, action: .mute, source: .profanity),
            CensorInterval(start: 5.0, end: 6.0, action: .mute, source: .profanity),
        ]
        XCTAssertEqual(
            SuperSeekBarModel.muteMarkers(from: twoMutes, duration: episodeDuration).count,
            2,
            "Two profanity mute intervals must yield count 2"
        )

        XCTAssertEqual(
            SuperSeekBarModel.muteMarkers(from: [], duration: episodeDuration).count,
            0,
            "Zero intervals must yield count 0"
        )

        let adsOnly = [
            CensorInterval(start: 35.0, end: 42.5, action: .skip, source: .unrelatedContent),
        ]
        XCTAssertEqual(
            SuperSeekBarModel.muteMarkers(from: adsOnly, duration: episodeDuration).count,
            0,
            "Unrelated-content skip intervals alone must not create mute markers"
        )

        let skipProfanity = [
            CensorInterval(start: 8.0, end: 9.0, action: .skip, source: .profanity),
        ]
        XCTAssertEqual(
            SuperSeekBarModel.muteMarkers(from: skipProfanity, duration: episodeDuration).count,
            0,
            "Profanity skip intervals are out of scope — count must be 0"
        )
    }
}
