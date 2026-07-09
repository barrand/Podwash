//
//  ASRSpikeFixtureTests.swift
//  PodWashTests
//
//  Slice 05 — On-device ASR spike (FAST / Done gate). Validates the committed
//  benchmark-results.json execution-evidence artifact (produced by the WhisperKit slow
//  test) against the independent golden asr_fixture_expected.json. NO live ASR, no model
//  needed → deterministic + CI-safe. See docs/adr/003-asr-stack-choice.md §3.4.
//

import XCTest
@testable import PodWash

final class ASRSpikeFixtureTests: XCTestCase {

    // Pinned provenance (ADR-003 §3.6) — a hand-faked artifact with wrong provenance fails.
    private let pinnedEngine = "WhisperKit"
    private let pinnedEngineVersion = "1.0.0"
    private let pinnedModel = "openai_whisper-tiny.en"
    private let pinnedModelRevision = "97a5bf9bbc74c7d9c12c755d04dea59e672e3808"
    private let pinnedComputeUnits = "cpuOnly"

    private let toleranceMs = 200.0
    private let maxWordErrors = 2

    // MARK: - Path helpers (repo layout, relative to this source file)

    /// `.../PodWash/PodWash/PodWashTests/ASRSpikeFixtureTests.swift`
    /// inner project dir = 2 up (contains PodWash.xcodeproj); repo root = 3 up.
    private var innerProjectDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PodWashTests
            .deletingLastPathComponent()   // PodWash (inner)
    }
    private var repoRoot: URL {
        innerProjectDir.deletingLastPathComponent()
    }

    // MARK: - Fixture loading (bundle first, #filePath fallback; fails, never skips)

    private func asrFixtureURL(_ name: String, _ ext: String, file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let bundle = Bundle(for: type(of: self))
        if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/asr")
            ?? bundle.url(forResource: name, withExtension: ext) {
            return url
        }
        let sourceURL = innerProjectDir
            .appendingPathComponent("PodWashTests/Fixtures/asr/\(name).\(ext)")
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            return sourceURL
        }
        XCTFail("Missing ASR fixture '\(name).\(ext)' (not in test bundle nor at \(sourceURL.path))", file: file, line: line)
        throw CocoaError(.fileNoSuchFile)
    }

    private func loadBenchmark(file: StaticString = #filePath, line: UInt = #line) throws -> ASRBenchmark {
        let url = try asrFixtureURL("benchmark-results", "json", file: file, line: line)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ASRBenchmark.self, from: data)
    }

    private func loadGolden() throws -> [TimedWord] {
        let url = try asrFixtureURL("asr_fixture_expected", "json")
        return try JSONDecoder().decode([TimedWord].self, from: try Data(contentsOf: url))
    }

    // MARK: - AC2: execution evidence (fails, never skips)

    func testBenchmarkArtifactExistsAndNonEmpty() throws {
        let hint = "Regenerate via scripts/setup-asr-models.sh then the PodWashSlowTests live benchmark (VERIFY_ALLOW_SKIPS=1 scripts/verify.sh -only-testing:PodWashSlowTests)."

        let url: URL
        do {
            url = try asrFixtureURL("benchmark-results", "json")
        } catch {
            XCTFail("benchmark-results.json is missing — execution evidence absent. \(hint)")
            return
        }

        guard let data = try? Data(contentsOf: url) else {
            XCTFail("benchmark-results.json is unreadable at \(url.path). \(hint)")
            return
        }
        guard let benchmark = try? JSONDecoder().decode(ASRBenchmark.self, from: data) else {
            XCTFail("benchmark-results.json is unparsable as ASRBenchmark. \(hint)")
            return
        }
        XCTAssertGreaterThan(benchmark.wordCount, 0, "benchmark wordCount == 0 — spike produced no words. \(hint)")
        XCTAssertEqual(benchmark.wordCount, benchmark.words.count, "wordCount disagrees with words.count")
        XCTAssertFalse(benchmark.words.isEmpty, "benchmark.words empty — no execution evidence. \(hint)")
    }

    // MARK: - AC1: recomputed drift + word-error tolerance vs independent golden

    func testTranscriptionWithinDriftTolerance() throws {
        let benchmark = try loadBenchmark()
        let golden = try loadGolden()

        // Provenance must match the pinned stack (anti-forgery).
        XCTAssertEqual(benchmark.engine, pinnedEngine, "engine provenance mismatch")
        XCTAssertEqual(benchmark.engineVersion, pinnedEngineVersion, "engineVersion provenance mismatch")
        XCTAssertEqual(benchmark.model, pinnedModel, "model provenance mismatch")
        XCTAssertEqual(benchmark.modelRevision, pinnedModelRevision, "modelRevision provenance mismatch")
        XCTAssertEqual(benchmark.computeUnits, pinnedComputeUnits, "computeUnits provenance mismatch")

        // Recompute drift/errors from benchmark.words vs golden — do NOT trust embedded stats.
        let score = ASRScoring.score(words: benchmark.words, golden: golden, toleranceMs: toleranceMs)

        XCTAssertTrue(
            score.boundariesWithinTolerance,
            "some word boundary drifts > ±\(toleranceMs) ms (recomputed max \(score.driftMaxMs) ms)"
        )
        XCTAssertLessThanOrEqual(
            score.wordErrorCount, maxWordErrors,
            "recomputed word error count \(score.wordErrorCount) exceeds budget \(maxWordErrors)"
        )
    }

    // MARK: - AC3: setup script pins an exact revision + documented in the fixture README

    func testSetupModelsScriptPinsExactRevision() throws {
        let scriptURL = repoRoot.appendingPathComponent("scripts/setup-asr-models.sh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptURL.path), "scripts/setup-asr-models.sh missing")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertTrue(script.contains(pinnedModelRevision), "setup script does not pin the exact model revision")
        XCTAssertTrue(script.contains(pinnedModel), "setup script does not reference the pinned model name")

        let readmeURL = try asrFixtureURL("asr-README", "md")
        let readme = try String(contentsOf: readmeURL, encoding: .utf8)
        XCTAssertTrue(readme.contains(pinnedModelRevision), "fixture README does not document the pinned model revision")
        XCTAssertTrue(readme.contains("setup-asr-models.sh"), "fixture README does not document the setup script")
    }

    // MARK: - AC4: PodWashSlowTests is a member of the scheme test action

    func testSlowTestTargetInScheme() throws {
        let schemeURL = innerProjectDir
            .appendingPathComponent("PodWash.xcodeproj/xcshareddata/xcschemes/PodWash.xcscheme")
        XCTAssertTrue(FileManager.default.fileExists(atPath: schemeURL.path), "PodWash.xcscheme missing")
        let scheme = try String(contentsOf: schemeURL, encoding: .utf8)

        // The <TestableReference> chunk that names PodWashSlowTests must be present (AC4:
        // member of the scheme test action) AND carry skipped="YES" (AC6: excluded from the
        // default fast run so it contributes zero executed/skipped cases). Isolate the chunk
        // to avoid matching another target's skipped attribute.
        let chunks = scheme.components(separatedBy: "<TestableReference")
        let slowChunk = chunks.first { $0.contains("PodWashSlowTests") }
        XCTAssertNotNil(slowChunk, "PodWashSlowTests is not a member of the PodWash scheme test action")
        if let slowChunk {
            XCTAssertTrue(
                slowChunk.contains("skipped = \"YES\""),
                "PodWashSlowTests must be skipped=\"YES\" in the scheme (present for AC4 but excluded from the fast run for AC6)"
            )
        }
    }

    // MARK: - AC5: decision artifacts recorded (ADR-003 + PRD §11)

    func testDecisionArtifactsRecorded() throws {
        let adrURL = repoRoot.appendingPathComponent("docs/adr/003-asr-stack-choice.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: adrURL.path), "ADR-003 missing")
        let adr = try String(contentsOf: adrURL, encoding: .utf8)
        XCTAssertTrue(adr.contains("WhisperKit"), "ADR-003 does not name the chosen stack")
        XCTAssertTrue(adr.contains("tiny.en"), "ADR-003 does not record the chosen model")
        XCTAssertTrue(adr.contains("134"), "ADR-003 does not record the measured max-drift benchmark number")

        let prdURL = repoRoot.appendingPathComponent("docs/product-requirements.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: prdURL.path), "PRD missing")
        let prd = try String(contentsOf: prdURL, encoding: .utf8)
        XCTAssertTrue(prd.contains("WhisperKit"), "PRD does not record the ASR decision")
        XCTAssertTrue(prd.uppercased().contains("RESOLVED"), "PRD §11 does not mark the ASR decision resolved")
    }
}
