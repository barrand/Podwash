//
//  SuperSeekBarAdBandTests.swift
//  PodWashTests
//
//  Slice 33 — Timestamp-proportional ad bands on super seek bar (ADR-030 §3). AC1–AC3.
//
//  Golden normalized values hand-computed from slice-33 AC pins (30/3600, two-band
//  mid-episode spans) — not from implementation under test.
//
//  Until SuperSeekBarModel.adBands and AdBand exist (Engineer), this file fails to
//  compile — intended TDD red state.
//

import XCTest
@testable import PodWash

final class SuperSeekBarAdBandTests: XCTestCase {

    private let normalizationTolerance = 0.002
    private let prerollDuration = 3600.0
    private let prerollSkipEnd = 30.0

    // MARK: - AC1

    func testPrerollYellowWidthMatchesTimestampFraction() {
        let intervals = [
            CensorInterval(
                start: 0.0,
                end: prerollSkipEnd,
                action: .skip,
                source: .unrelatedContent
            ),
        ]

        let bands = SuperSeekBarModel.adBands(from: intervals, duration: prerollDuration)

        XCTAssertEqual(bands.count, 1, "Single preroll skip must yield exactly one ad band")
        XCTAssertEqual(
            bands[0].startNormalized,
            0.0,
            accuracy: normalizationTolerance,
            "Preroll band must start at normalized 0"
        )
        XCTAssertEqual(
            bands[0].endNormalized,
            prerollSkipEnd / prerollDuration,
            accuracy: normalizationTolerance,
            "Preroll band end must be 30/3600 ± \(normalizationTolerance)"
        )
    }

    // MARK: - AC2

    func testTwoAdBandsNoSpuriousCoverage() {
        let duration = 3600.0
        let intervals = [
            CensorInterval(start: 0.0, end: 30.0, action: .skip, source: .unrelatedContent),
            CensorInterval(start: 1800.0, end: 1860.0, action: .skip, source: .unrelatedContent),
        ]

        let bands = SuperSeekBarModel.adBands(from: intervals, duration: duration)

        XCTAssertEqual(bands.count, 2, "Two unrelated skips must yield exactly two ad bands")
        XCTAssertEqual(bands[0].startNormalized, 0.0, accuracy: normalizationTolerance)
        XCTAssertEqual(bands[0].endNormalized, 30.0 / duration, accuracy: normalizationTolerance)
        XCTAssertEqual(bands[1].startNormalized, 1800.0 / duration, accuracy: normalizationTolerance)
        XCTAssertEqual(bands[1].endNormalized, 1860.0 / duration, accuracy: normalizationTolerance)

        XCTAssertLessThan(
            bands[0].endNormalized,
            bands[1].startNormalized,
            "Intervening content must have no yellow coverage between bands"
        )

        let gapMidpoint = (bands[0].endNormalized + bands[1].startNormalized) / 2
        let gapCovered = bands.contains { band in
            gapMidpoint >= band.startNormalized && gapMidpoint < band.endNormalized
        }
        XCTAssertFalse(gapCovered, "Mid-episode gap must not fall inside any ad band")
    }

    // MARK: - AC3

    func testYellowBandsMatchTranscriptSkippedAdIntervals() {
        let duration = 3600.0
        let intervals = [
            CensorInterval(start: 0.0, end: 30.0, action: .skip, source: .unrelatedContent),
            CensorInterval(start: 1800.0, end: 1860.0, action: .skip, source: .unrelatedContent),
            CensorInterval(start: 100.0, end: 110.0, action: .mute, source: .unrelatedContent),
            CensorInterval(start: 200.0, end: 210.0, action: .mute, source: .profanity),
        ]
        let transcript: [TimedWord] = [
            TimedWord(word: "preroll", start: 5.0, end: 10.0),
            TimedWord(word: "content", start: 500.0, end: 510.0),
            TimedWord(word: "midad", start: 1810.0, end: 1820.0),
            TimedWord(word: "tail", start: 3500.0, end: 3510.0),
        ]

        let bands = SuperSeekBarModel.adBands(from: intervals, duration: duration)
        let viewModel = TranscriptViewModel.make(
            transcript: transcript,
            intervals: intervals,
            playbackPosition: 0
        )

        for display in viewModel.words where display.skippedAd {
            let wordStartNorm = display.word.start / duration
            let wordEndNorm = display.word.end / duration
            let overlapsBand = bands.contains { band in
                wordStartNorm < band.endNormalized && wordEndNorm > band.startNormalized
            }
            XCTAssertTrue(
                overlapsBand,
                "skippedAd word \(display.index) must overlap at least one yellow ad band"
            )
        }

        let skipIntervals = intervals.filter {
            $0.source == .unrelatedContent && $0.action == .skip
        }
        for band in bands {
            let bandStart = band.startNormalized * duration
            let bandEnd = band.endNormalized * duration
            let insideSkipUnion = skipIntervals.contains { skip in
                bandStart >= skip.start - normalizationTolerance * duration
                    && bandEnd <= skip.end + normalizationTolerance * duration
            }
            XCTAssertTrue(
                insideSkipUnion,
                "Ad band [\(band.startNormalized), \(band.endNormalized)) must lie inside unrelated skip union"
            )
        }
    }
}
