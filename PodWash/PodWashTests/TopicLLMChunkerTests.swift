//
//  TopicLLMChunkerTests.swift
//  PodWashTests
//
//  topic-llm-v1 — deterministic chunker + stitcher / unsure resolution.
//

import XCTest
@testable import PodWash

final class TopicLLMChunkerTests: XCTestCase {

    func testWindowsPackNearTwentySecondsOnSentenceEnds() {
        var words: [TimedWord] = []
        var t = 0.0
        // ~60 s of 1-second "words" with sentence ends every 5 s
        for i in 0..<60 {
            let punct = (i + 1) % 5 == 0 ? "." : ""
            words.append(TimedWord(word: "w\(i)\(punct)", start: t, end: t + 0.9))
            t += 1.0
        }
        let windows = TranscriptWindowChunker.windows(from: words)
        XCTAssertFalse(windows.isEmpty)
        for w in windows {
            let dur = w.end - w.start
            XCTAssertLessThanOrEqual(dur, 28.0 + 0.01, "window \(w.id) dur \(dur)")
            XCTAssertGreaterThan(dur, 0)
        }
        // Cover full span
        XCTAssertEqual(windows.first?.start ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(windows.last?.end ?? -1, words.last!.end, accuracy: 0.01)
    }

    func testMergeConsecutiveAdsDropsShortPods() {
        let labeled: [(start: Double, end: Double, label: ChunkAdLabel)] = [
            (0, 3, .ad), // too short — dropped
            (3, 10, .content),
            (10, 40, .ad),
            (40, 55, .ad),
            (55, 80, .content),
            (100, 130, .ad),
        ]
        let segs = AdSpanStitcher.mergeAdSpans(windows: labeled)
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].start, 10, accuracy: 0.01)
        XCTAssertEqual(segs[0].end, 55, accuracy: 0.01)
        XCTAssertEqual(segs[1].start, 100, accuracy: 0.01)
        XCTAssertEqual(segs[1].end, 130, accuracy: 0.01)
    }

    func testUnsureStaysAdWhenPreviousAdAndSellContinues() {
        let resolved = AdSpanStitcher.resolveUnsure(
            label: .unsure,
            text: "Member FDIC. Terms apply.",
            previousResolved: .ad,
            nextText: "Visit ondeck.com for details."
        )
        XCTAssertEqual(resolved, .ad)
    }

    func testUnsureExitsWhenPreviousAdAndWelcomeBack() {
        let resolved = AdSpanStitcher.resolveUnsure(
            label: .unsure,
            text: "Welcome back to the show. Today we talk recruiting.",
            previousResolved: .ad,
            nextText: nil
        )
        XCTAssertEqual(resolved, .content)
    }

    func testUnsureEntersAdFromContentWhenSellClear() {
        let resolved = AdSpanStitcher.resolveUnsure(
            label: .unsure,
            text: "Brought to you by Sleep Number. Visit sleepnumber.com today.",
            previousResolved: .content,
            nextText: nil
        )
        XCTAssertEqual(resolved, .ad)
    }

    func testShowResumeForcesContentInMerge() {
        let w1 = TranscriptWindow(
            id: 1, start: 0, end: 20,
            text: "This message comes from Capital One. Learn more at capitalone.com.",
            words: []
        )
        let w2 = TranscriptWindow(
            id: 2, start: 20, end: 40,
            text: "It's American life. Act One. The trial begins.",
            words: []
        )
        let segs = AdSpanStitcher.mergeAdSpans(labeled: [
            (w1, .ad),
            (w2, .ad), // would wrongly stay ad without resume cut
        ])
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].end, 20, accuracy: 0.01)
    }

    func testTopicLLMSegmenterFallsBackWhenModelUnavailable() async {
        let segmenter = TopicLLMSegmenter()
        let words = [
            TimedWord(word: "This", start: 0, end: 0.3),
            TimedWord(word: "message", start: 0.3, end: 0.7),
            TimedWord(word: "comes", start: 0.7, end: 1.0),
            TimedWord(word: "from", start: 1.0, end: 1.3),
            TimedWord(word: "Acme.", start: 1.3, end: 1.8),
            TimedWord(word: "Visit", start: 2.0, end: 2.3),
            TimedWord(word: "acme.com", start: 2.3, end: 3.0),
            TimedWord(word: "slash", start: 3.0, end: 3.3),
            TimedWord(word: "deal.", start: 3.3, end: 4.0),
            TimedWord(word: "More", start: 4.2, end: 4.5),
            TimedWord(word: "pitch", start: 4.5, end: 4.9),
            TimedWord(word: "here.", start: 4.9, end: 5.5),
            TimedWord(word: "Okay", start: 10, end: 10.3),
            TimedWord(word: "so", start: 10.3, end: 10.5),
            TimedWord(word: "the", start: 10.5, end: 10.7),
            TimedWord(word: "story", start: 10.7, end: 11.2),
            TimedWord(word: "continues.", start: 11.2, end: 12.0),
        ]
        let segs = await segmenter.segments(in: words, context: .empty)
        // With AI off: heuristic fallback. With AI on: LLM path. Either must return.
        XCTAssertNotNil(segs)
        if !segmenter.isModelAvailable {
            XCTAssertFalse(segs.isEmpty, "heuristic fallback should detect sponsor-like span ≥5s")
        }
    }
}
