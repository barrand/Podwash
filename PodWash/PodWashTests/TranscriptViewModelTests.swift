//
//  TranscriptViewModelTests.swift
//  PodWashTests
//
//  Slice 26 — Episode transcript viewer. AC3: listened / skipped-ad classification.
//
//  Synthetic fixture provenance (hand-computed per slice-26 fixture table + ADR-022 §2):
//  10 words, 2.0 s each → word[i] spans [2i, 2i+2) over 0.0–20.0 s.
//  playbackPosition = 12.0 → listenedCount 6 (end ≤ 12, not skipped-ad).
//  unrelated skip 12.0–18.0 s → skippedAdCount 3 (indices 6–8 overlap).
//  Until TranscriptViewModel exists (Engineer), this file fails to compile — TDD red.
//

import XCTest
@testable import PodWash

final class TranscriptViewModelTests: XCTestCase {

    private let playbackPosition: TimeInterval = 12.0
    private let unrelatedSkipStart: Double = 12.0
    private let unrelatedSkipEnd: Double = 18.0

    // MARK: - AC3

    func testListenedAndSkippedAdWordFlags() {
        let transcript = Self.syntheticTenWordTranscript()
        let intervals = [
            CensorInterval(
                start: unrelatedSkipStart,
                end: unrelatedSkipEnd,
                action: .skip,
                source: .unrelatedContent
            ),
        ]

        let viewModel = TranscriptViewModel.make(
            transcript: transcript,
            intervals: intervals,
            playbackPosition: playbackPosition
        )

        XCTAssertEqual(viewModel.wordCount, 10)
        XCTAssertEqual(viewModel.listenedCount, 6, "words with end ≤ 12.0 s, excluding skipped-ad")
        XCTAssertEqual(viewModel.skippedAdCount, 3, "words overlapping unrelated skip 12.0–18.0 s")

        for display in viewModel.words {
            XCTAssertFalse(
                display.listened && display.skippedAd,
                "word \(display.index) must not be both listened and skippedAd"
            )
        }

        let skippedIndices = Set(viewModel.words.filter(\.skippedAd).map(\.index))
        XCTAssertEqual(skippedIndices, [6, 7, 8])

        let listenedIndices = Set(viewModel.words.filter(\.listened).map(\.index))
        XCTAssertEqual(listenedIndices, [0, 1, 2, 3, 4, 5])
    }

    // MARK: - Task 021

    func testParagraphsSplitAfterSentenceEndingPunctuation() {
        let transcript: [TimedWord] = [
            TimedWord(word: "Hello", start: 0, end: 1),
            TimedWord(word: "there.", start: 1, end: 2),
            TimedWord(word: "Next", start: 2, end: 3),
            TimedWord(word: "bit.", start: 3, end: 4),
            TimedWord(word: "End", start: 4, end: 5),
        ]

        let paragraphs = TranscriptViewModel.paragraphs(from: transcript)

        XCTAssertEqual(paragraphs.count, 3)
        XCTAssertEqual(paragraphs[0].firstWordIndex, 0)
        XCTAssertEqual(paragraphs[0].lastWordIndex, 1)
        XCTAssertEqual(paragraphs[1].firstWordIndex, 2)
        XCTAssertEqual(paragraphs[1].lastWordIndex, 3)
        XCTAssertEqual(paragraphs[2].firstWordIndex, 4)
        XCTAssertEqual(paragraphs[2].lastWordIndex, 4)
    }

    func testParagraphTimestampUsesFirstWordStartWholeSeconds() {
        let transcript = [
            TimedWord(word: "Intro.", start: 12.7, end: 13.7),
        ]

        let paragraphs = TranscriptViewModel.paragraphs(from: transcript)

        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertEqual(paragraphs[0].startSeconds, 12, "floor first word start to whole seconds")
        XCTAssertEqual(paragraphs[0].formattedStartTimestamp, "0:12")
    }

    func testNoPunctuationYieldsSingleParagraph() {
        let transcript: [TimedWord] = [
            TimedWord(word: "One", start: 0, end: 1),
            TimedWord(word: "Two", start: 1, end: 2),
            TimedWord(word: "Three", start: 2, end: 3),
            TimedWord(word: "Four", start: 3, end: 4),
        ]

        let paragraphs = TranscriptViewModel.paragraphs(from: transcript)

        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertEqual(paragraphs[0].firstWordIndex, 0)
        XCTAssertEqual(paragraphs[0].lastWordIndex, 3)
    }

    // MARK: - Synthetic fixture (slice-26 fixture table)

    /// 10 words, 2.0 s each: word[i] = [2i, 2i+2) seconds.
    private static func syntheticTenWordTranscript() -> [TimedWord] {
        (0 ..< 10).map { index in
            let start = Double(index) * 2.0
            return TimedWord(word: "w\(index)", start: start, end: start + 2.0)
        }
    }
}
