//
//  SegmentationSpikeTests.swift
//  PodWashTests
//
//  Slice 18 + 34 — Content segmentation spike (FAST / Done gate).
//  Slice 18: validates committed segmentation-benchmark-results.json vs hand-golden (IoU P/R).
//  Slice 34: heuristic-cue-v6 failure-mode fixtures (midroll end-bleed, question hook,
//  missed opener, single-sentence read) + opening / three-sponsor regression floors.
//  Benchmark artifact path is deterministic + CI-safe; slice-34 unit tests run HeuristicContentSegmenter.
//  See docs/adr/012-content-segmentation-approach.md and docs/slices/slice-34-ad-detection-v6.md.
//

import XCTest
@testable import PodWash

final class SegmentationSpikeTests: XCTestCase {

    private let precisionFloor = 0.700
    private let recallFloor = 0.500
    private let iouThreshold = 0.5
    private let adrNumericTolerance = 0.001
    private let benchmarkArtifactName = "segmentation-benchmark-results"

    // MARK: - Path helpers

    private var innerProjectDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var repoRoot: URL {
        innerProjectDir.deletingLastPathComponent()
    }

    private func segmentationFixtureURL(
        _ name: String,
        _ ext: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> URL {
        let bundle = Bundle(for: type(of: self))
        if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/segmentation")
            ?? bundle.url(forResource: name, withExtension: ext) {
            return url
        }
        let sourceURL = innerProjectDir
            .appendingPathComponent("PodWashTests/Fixtures/segmentation/\(name).\(ext)")
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            return sourceURL
        }
        XCTFail("Missing segmentation fixture '\(name).\(ext)' (not in test bundle nor at \(sourceURL.path))", file: file, line: line)
        throw CocoaError(.fileNoSuchFile)
    }

    private var regenerationHint: String {
        "Regenerate via PodWashSlowTests/SegmentationBenchmarkTests (VERIFY_ALLOW_SKIPS=1 scripts/verify.sh -only-testing:PodWashSlowTests/SegmentationBenchmarkTests)."
    }

    private func loadBenchmark(file: StaticString = #filePath, line: UInt = #line) throws -> SegmentationBenchmark {
        let url = try segmentationFixtureURL(benchmarkArtifactName, "json", file: file, line: line)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SegmentationBenchmark.self, from: data)
    }

    private func loadGolden() throws -> [GoldenSegment] {
        let url = try segmentationFixtureURL("golden_segments", "json")
        return try JSONDecoder().decode([GoldenSegment].self, from: try Data(contentsOf: url))
    }

    private func loadTranscript(named name: String) throws -> [TimedWord] {
        let url = try segmentationFixtureURL(name, "json")
        return try JSONDecoder().decode([TimedWord].self, from: Data(contentsOf: url))
    }

    private func loadThreeSponsorGolden() throws -> [GoldenSegment] {
        let url = try segmentationFixtureURL("three_sponsor_golden", "json")
        return try JSONDecoder().decode([GoldenSegment].self, from: Data(contentsOf: url))
    }

    private func overlapsOpening(_ segment: ContentSegment, openingEnd: Double = 180.0) -> Bool {
        max(0, min(segment.end, openingEnd) - max(segment.start, 0)) > 0
    }

    // MARK: - Slice 18 AC2 / Slice 34 AC7: execution evidence (fails, never skips)

    func testBenchmarkArtifactExistsAndNonEmpty() throws {
        let hint = regenerationHint

        let url: URL
        do {
            url = try segmentationFixtureURL(benchmarkArtifactName, "json")
        } catch {
            XCTFail("\(benchmarkArtifactName).json is missing — execution evidence absent. \(hint)")
            return
        }

        guard let data = try? Data(contentsOf: url) else {
            XCTFail("\(benchmarkArtifactName).json is unreadable at \(url.path). \(hint)")
            return
        }
        guard let benchmark = try? JSONDecoder().decode(SegmentationBenchmark.self, from: data) else {
            XCTFail("\(benchmarkArtifactName).json is unparsable as SegmentationBenchmark. \(hint)")
            return
        }
        XCTAssertGreaterThan(benchmark.segmentCount, 0, "benchmark segmentCount == 0 — spike produced no segments. \(hint)")
        XCTAssertEqual(benchmark.segmentCount, benchmark.segments.count, "segmentCount disagrees with segments.count")
        XCTAssertFalse(benchmark.segments.isEmpty, "benchmark.segments empty — no execution evidence. \(hint)")
    }

    // MARK: - Slice 18 AC1 / Slice 34 AC7: recomputed IoU precision/recall vs independent golden

    func testPrecisionRecallAgainstGolden() throws {
        let benchmark = try loadBenchmark()
        let golden = try loadGolden()

        XCTAssertEqual(
            benchmark.approach,
            "heuristic-cue-v6",
            "benchmark.approach must pin heuristic-cue-v6 (slice 34)"
        )
        XCTAssertGreaterThanOrEqual(benchmark.segments.count, 1, "benchmark.segments must have ≥ 1 entry")

        let predictions = benchmark.segments.map { ($0.start, $0.end) }
        let goldens = golden.map { ($0.start, $0.end) }
        let score = SegmentationMetrics.score(
            predictions: predictions,
            goldens: goldens,
            iouThreshold: iouThreshold
        )

        XCTAssertGreaterThanOrEqual(
            score.precision, precisionFloor,
            "recomputed precision \(score.precision) < \(precisionFloor) (TP=\(score.truePositives) FP=\(score.falsePositives))"
        )
        XCTAssertGreaterThanOrEqual(
            score.recall, recallFloor,
            "recomputed recall \(score.recall) < \(recallFloor) (TP=\(score.truePositives) FN=\(score.falseNegatives))"
        )
    }

    // MARK: - AC3: golden fixture integrity

    func testGoldenFixtureIntegrity() throws {
        let golden = try loadGolden()

        XCTAssertGreaterThanOrEqual(golden.count, 2, "golden must contain ≥ 2 positive segments")

        var totalPositiveDuration = 0.0
        for (index, segment) in golden.enumerated() {
            XCTAssertGreaterThan(segment.end, segment.start, "golden[\(index)] must have end > start")
            let duration = segment.duration
            XCTAssertGreaterThanOrEqual(duration, 5.0, "golden[\(index)] duration \(duration)s < 5.0 s")
            totalPositiveDuration += duration
        }

        XCTAssertGreaterThanOrEqual(
            totalPositiveDuration, 15.0,
            "total labeled positive duration \(totalPositiveDuration)s < 15.0 s"
        )
    }

    // MARK: - AC4: decision artifact cites committed benchmark numbers

    func testDecisionArtifactRecorded() throws {
        let benchmark = try loadBenchmark()

        let adrURL = repoRoot.appendingPathComponent("docs/adr/012-content-segmentation-approach.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: adrURL.path), "ADR-012 missing")
        let adr = try String(contentsOf: adrURL, encoding: .utf8)

        XCTAssertTrue(
            adr.contains(benchmark.approach),
            "ADR-012 must name the committed approach '\(benchmark.approach)'"
        )

        let score = SegmentationMetrics.score(
            predictions: benchmark.segments.map { ($0.start, $0.end) },
            goldens: try loadGolden().map { ($0.start, $0.end) },
            iouThreshold: iouThreshold
        )

        XCTAssertTrue(
            adrContainsNumber(adr, score.precision, label: "precision"),
            "ADR-012 must cite committed precision \(score.precision) within ±\(adrNumericTolerance)"
        )
        XCTAssertTrue(
            adrContainsNumber(adr, score.recall, label: "recall"),
            "ADR-012 must cite committed recall \(score.recall) within ±\(adrNumericTolerance)"
        )
    }

    // MARK: - Slice 34 AC5: opening density false positive (regression)

    func testOpeningWithoutSponsorAnchorProducesNoEarlySegment() throws {
        let transcript = try loadTranscript(named: "opening_no_sponsor_anchor_transcript")
        let segments = HeuristicContentSegmenter().segments(in: transcript)

        let earlySegments = segments.filter { overlapsOpening($0) }
        XCTAssertTrue(
            earlySegments.isEmpty,
            "Expected 0 segments overlapping [0, 180)s; got \(earlySegments.map { "[\($0.start), \($0.end)]" }.joined(separator: ", "))"
        )
    }

    // MARK: - Slice 34 AC6: three sponsor clusters (regression)

    func testThreeSponsorClustersMatchGoldenIoU() throws {
        let transcript = try loadTranscript(named: "three_sponsor_transcript")
        let golden = try loadThreeSponsorGolden()

        XCTAssertEqual(golden.count, 3, "Fixture must define exactly 3 hand-labeled sponsor clusters")

        let segments = HeuristicContentSegmenter().segments(in: transcript)
        XCTAssertEqual(
            segments.count,
            3,
            "Expected exactly 3 segments; got \(segments.count): \(segments.map { "[\($0.start), \($0.end)]" }.joined(separator: ", "))"
        )

        let predictions = segments.map { ($0.start, $0.end) }
        let goldens = golden.map { ($0.start, $0.end) }
        let score = SegmentationMetrics.score(
            predictions: predictions,
            goldens: goldens,
            iouThreshold: iouThreshold
        )

        XCTAssertEqual(score.falsePositives, 0, "Unmatched predicted segments at IoU ≥ \(iouThreshold)")
        XCTAssertEqual(score.falseNegatives, 0, "Unmatched golden clusters at IoU ≥ \(iouThreshold)")
        XCTAssertEqual(score.truePositives, 3)

        for (index, expected) in golden.enumerated() {
            let bestIoU = predictions.map {
                SegmentationMetrics.iou($0, (expected.start, expected.end))
            }.max() ?? 0
            XCTAssertGreaterThanOrEqual(
                bestIoU,
                iouThreshold,
                "Golden[\(index)] [\(expected.start), \(expected.end)] best IoU \(bestIoU) < \(iouThreshold)"
            )
        }
    }

    // MARK: - AC5: PodWashSlowTests scheme membership when present

    func testSlowTestTargetInSchemeIfPresent() throws {
        let schemeURL = innerProjectDir
            .appendingPathComponent("PodWash.xcodeproj/xcshareddata/xcschemes/PodWash.xcscheme")
        XCTAssertTrue(FileManager.default.fileExists(atPath: schemeURL.path), "PodWash.xcscheme missing")
        let scheme = try String(contentsOf: schemeURL, encoding: .utf8)

        guard scheme.contains("PodWashSlowTests") else {
            // No slow target in scheme — no-op pass per AC5.
            return
        }

        let chunks = scheme.components(separatedBy: "<TestableReference")
        let slowChunk = chunks.first { $0.contains("PodWashSlowTests") }
        XCTAssertNotNil(slowChunk, "PodWashSlowTests is not a member of the PodWash scheme test action")
        if let slowChunk {
            XCTAssertTrue(
                slowChunk.contains("skipped = \"YES\""),
                "PodWashSlowTests must be skipped=\"YES\" in the scheme (present for AC5 but excluded from the fast run for AC6)"
            )
        }
    }

    // MARK: - Slice 34 / heuristic-cue-v6 failure-mode fixtures (AC1–AC4)

    private let slice34FixtureBases = [
        "midroll_closer_resume",
        "question_hook_continuity",
        "missed_opener_recovery",
        "single_sentence_read",
    ]

    /// Structural integrity for hand-goldens (independent of segmenter output).
    func testSlice34FixtureGoldenIntegrity() throws {
        for base in slice34FixtureBases {
            let golden = try loadGoldenNamed("\(base)_golden")
            XCTAssertEqual(golden.count, 1, "\(base): expected exactly 1 golden segment")
            XCTAssertGreaterThan(golden[0].end, golden[0].start, "\(base): end must exceed start")

            let transcript = try loadTranscript(named: "\(base)_transcript")
            XCTAssertFalse(transcript.isEmpty, "\(base): transcript must be non-empty")

            let provenanceURL = try segmentationFixtureURL("\(base)_provenance", "md")
            let provenance = try String(contentsOf: provenanceURL, encoding: .utf8)
            XCTAssertTrue(
                provenance.localizedCaseInsensitiveContains("hand-scripted")
                    || provenance.localizedCaseInsensitiveContains("hand-labeled"),
                "\(base): provenance must document independent hand labeling"
            )
        }

        let singleGolden = try loadGoldenNamed("single_sentence_read_golden")
        XCTAssertGreaterThanOrEqual(
            singleGolden[0].duration,
            5.0,
            "single_sentence_read golden must span ≥ 5.0 s (AC4)"
        )

        let midrollTranscript = try loadTranscript(named: "midroll_closer_resume_transcript")
        let midrollGolden = try loadGoldenNamed("midroll_closer_resume_golden")
        let adStart = try XCTUnwrap(
            phraseStart(in: midrollTranscript, phrase: ["This", "message", "comes", "from"]),
            "midroll_closer_resume must contain sponsor opener"
        )
        let adEnd = try XCTUnwrap(
            phraseEnd(in: midrollTranscript, phrase: ["FDIC"]),
            "midroll_closer_resume must end ad copy at FDIC"
        )
        XCTAssertEqual(midrollGolden[0].start, adStart, accuracy: 0.01, "Golden start must snap to opener (AC1)")
        XCTAssertEqual(midrollGolden[0].end, adEnd, accuracy: 0.01, "Golden end must snap to FDIC (AC1)")
        let hostResumeStart = try XCTUnwrap(
            phraseStart(in: midrollTranscript, phrase: ["Okay"]),
            "midroll_closer_resume must anchor host resume at Okay"
        )
        XCTAssertEqual(hostResumeStart, 19.0, accuracy: 0.01, "Host resume must start at 19.0 s (AC1)")

        let questionTranscript = try loadTranscript(named: "question_hook_continuity_transcript")
        let questionGolden = try loadGoldenNamed("question_hook_continuity_golden")
        let hookStart = try XCTUnwrap(phraseStart(in: questionTranscript, phrase: ["Support"]))
        let ctaEnd = try XCTUnwrap(phraseEnd(in: questionTranscript, phrase: ["deal"]))
        XCTAssertEqual(questionGolden[0].start, hookStart, accuracy: 0.01, "Golden start must snap to Support (AC2)")
        XCTAssertEqual(questionGolden[0].end, ctaEnd, accuracy: 0.01, "Golden end must snap to CTA deal. (AC2)")

        let missedTranscript = try loadTranscript(named: "missed_opener_recovery_transcript")
        let missedGolden = try loadGoldenNamed("missed_opener_recovery_golden")
        let messageComesFromStart = try XCTUnwrap(
            phraseStart(in: missedTranscript, phrase: ["This", "message", "comes", "from"]),
            "missed_opener_recovery must contain \"This message comes from\" (AC3)"
        )
        let brandEnd = try XCTUnwrap(
            phraseEnd(in: missedTranscript, phrase: ["WholeMart"], matchFromEnd: true),
            "missed_opener_recovery must contain final WholeMart brand token"
        )
        XCTAssertEqual(missedGolden[0].start, messageComesFromStart, accuracy: 0.01, "Golden start must snap to opener (AC3)")
        XCTAssertEqual(missedGolden[0].end, brandEnd, accuracy: 0.01, "Golden end must snap to final WholeMart (AC3)")

        let singleTranscript = try loadTranscript(named: "single_sentence_read_transcript")
        let singleGoldenBounds = try loadGoldenNamed("single_sentence_read_golden")
        let readStart = try XCTUnwrap(phraseStart(in: singleTranscript, phrase: ["Support"]))
        let readEnd = try XCTUnwrap(phraseEnd(in: singleTranscript, phrase: ["FDIC"]))
        XCTAssertEqual(singleGoldenBounds[0].start, readStart, accuracy: 0.01, "Golden start must snap to Support (AC4)")
        XCTAssertEqual(singleGoldenBounds[0].end, readEnd, accuracy: 0.01, "Golden end must snap to FDIC (AC4)")
    }

    func testMidrollClosesBeforeHostResume() throws {
        let transcript = try loadTranscript(named: "midroll_closer_resume_transcript")
        let golden = try loadGoldenNamed("midroll_closer_resume_golden")
        let segments = HeuristicContentSegmenter().segments(in: transcript)
        XCTAssertEqual(segments.count, 1, "Expected exactly 1 midroll segment")
        let g = golden[0]
        XCTAssertEqual(segments[0].end, g.end, accuracy: 2.0, "End must be within ±2.0 s of golden")
        let iou = SegmentationMetrics.iou(
            (segments[0].start, segments[0].end),
            (g.start, g.end)
        )
        XCTAssertGreaterThanOrEqual(iou, iouThreshold, "Midroll segment IoU \(iou) < \(iouThreshold) (AC1)")
        let hostResumeStart = 19.0
        XCTAssertLessThanOrEqual(
            segments[0].end,
            hostResumeStart,
            "Segment must not extend past host resume at \(hostResumeStart)s (AC1)"
        )
    }

    func testQuestionHookContinuityKeepsAdBody() throws {
        let transcript = try loadTranscript(named: "question_hook_continuity_transcript")
        let golden = try loadGoldenNamed("question_hook_continuity_golden")
        let segments = HeuristicContentSegmenter().segments(in: transcript)
        XCTAssertEqual(segments.count, 1, "Expected exactly 1 segment spanning opener through CTA")
        let iou = SegmentationMetrics.iou(
            (segments[0].start, segments[0].end),
            (golden[0].start, golden[0].end)
        )
        XCTAssertGreaterThanOrEqual(iou, iouThreshold)
    }

    func testMissedOpenerRecoveryStartsAtMessageComesFrom() throws {
        let transcript = try loadTranscript(named: "missed_opener_recovery_transcript")
        let golden = try loadGoldenNamed("missed_opener_recovery_golden")
        let segments = HeuristicContentSegmenter().segments(in: transcript)
        XCTAssertEqual(segments.count, 1)
        let messageComesFromStart = try XCTUnwrap(
            phraseStart(in: transcript, phrase: ["This", "message", "comes", "from"]),
            "Fixture must contain opener phrase \"This message comes from\""
        )
        XCTAssertEqual(
            segments[0].start,
            messageComesFromStart,
            accuracy: 2.0,
            "Segment start must be within ±2.0 s of \"This message comes from\""
        )
        let iou = SegmentationMetrics.iou(
            (segments[0].start, segments[0].end),
            (golden[0].start, golden[0].end)
        )
        XCTAssertGreaterThanOrEqual(iou, iouThreshold)
    }

    func testSingleSentenceUnderwritingReadDetected() throws {
        let transcript = try loadTranscript(named: "single_sentence_read_transcript")
        let golden = try loadGoldenNamed("single_sentence_read_golden")
        XCTAssertGreaterThanOrEqual(
            golden[0].duration,
            5.0,
            "Fixture golden must label ≥ 5.0 s underwriting read"
        )
        let segments = HeuristicContentSegmenter().segments(in: transcript)
        XCTAssertEqual(segments.count, 1)
        let iou = SegmentationMetrics.iou(
            (segments[0].start, segments[0].end),
            (golden[0].start, golden[0].end)
        )
        XCTAssertGreaterThanOrEqual(iou, iouThreshold)
    }

    private func loadGoldenNamed(_ name: String) throws -> [GoldenSegment] {
        let url = try segmentationFixtureURL(name, "json")
        return try JSONDecoder().decode([GoldenSegment].self, from: Data(contentsOf: url))
    }

    /// First `TimedWord.start` where consecutive tokens match `phrase` (punctuation-insensitive).
    private func phraseStart(in transcript: [TimedWord], phrase: [String]) -> Double? {
        guard let index = phraseMatchIndex(in: transcript, phrase: phrase) else { return nil }
        return transcript[index].start
    }

    /// `TimedWord.end` of the last token in a consecutive `phrase` match.
    private func phraseEnd(
        in transcript: [TimedWord],
        phrase: [String],
        matchFromEnd: Bool = false
    ) -> Double? {
        guard let index = phraseMatchIndex(in: transcript, phrase: phrase, matchFromEnd: matchFromEnd) else {
            return nil
        }
        return transcript[index + phrase.count - 1].end
    }

    private func phraseMatchIndex(
        in transcript: [TimedWord],
        phrase: [String],
        matchFromEnd: Bool = false
    ) -> Int? {
        guard phrase.count <= transcript.count else { return nil }
        let normalizedPhrase = phrase.map(normalizeToken)
        let indices = Array(0...(transcript.count - phrase.count))
        let search: [Int] = matchFromEnd ? indices.reversed() : indices
        for index in search {
            let window = (index..<(index + phrase.count)).map { normalizeToken(transcript[$0].word) }
            if window == normalizedPhrase {
                return index
            }
        }
        return nil
    }

    private func normalizeToken(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
    }

    // MARK: - Helpers

    private func adrContainsNumber(_ adr: String, _ value: Double, label: String) -> Bool {
        let formatted = String(format: "%.3f", value)
        let variants = [
            formatted,
            String(format: "%.2f", value),
            String(format: "%.1f", value),
            String(value),
        ]
        return variants.contains { adr.contains($0) }
            || abs(extractFirstDouble(near: label, in: adr) - value) <= adrNumericTolerance
    }

    private func extractFirstDouble(near label: String, in text: String) -> Double {
        guard let range = text.range(of: label, options: .caseInsensitive) else { return -.infinity }
        let tail = String(text[range.upperBound...])
        guard let regex = try? NSRegularExpression(pattern: #"([0-9]+\.[0-9]+)"#) else { return -.infinity }
        let nsTail = tail as NSString
        guard let match = regex.firstMatch(in: tail, range: NSRange(location: 0, length: nsTail.length)),
              match.numberOfRanges > 1 else { return -.infinity }
        let number = nsTail.substring(with: match.range(at: 1))
        return Double(number) ?? -.infinity
    }
}
