//
//  ASRBenchmarkTests.swift
//  PodWashSlowTests
//
//  Slice 05 — On-device ASR spike (SLOW / nightly only — NOT a Done gate). Runs WhisperKit
//  live against the pinned local tiny.en model, regenerates benchmark-results.json (the AC2
//  execution evidence), and asserts the live run still meets drift/error thresholds. The
//  gitignored model means this target may only skip under the nightly VERIFY_ALLOW_SKIPS=1
//  job; it is excluded from the default fast verify.sh run (scheme skipped="YES").
//  See docs/adr/003-asr-stack-choice.md §3.4.
//

import XCTest
import AVFoundation
@testable import PodWash

final class ASRBenchmarkTests: XCTestCase {

    private let pinnedModelRevision = "97a5bf9bbc74c7d9c12c755d04dea59e672e3808"
    private let toleranceMs = 200.0
    private let maxWordErrors = 2

    /// `.../PodWash/PodWash/PodWashSlowTests/ASRBenchmarkTests.swift` → inner project dir = 2 up.
    private var innerProjectDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PodWashSlowTests
            .deletingLastPathComponent()   // PodWash (inner)
    }
    private var repoRoot: URL { innerProjectDir.deletingLastPathComponent() }
    private var asrFixturesDir: URL { innerProjectDir.appendingPathComponent("PodWashTests/Fixtures/asr") }

    @MainActor
    func testWhisperKitBenchmarkAndRegenerateArtifact() async throws {
        let modelFolder = repoRoot.appendingPathComponent("Models/whisperkit-coreml/openai_whisper-tiny.en")
        guard FileManager.default.fileExists(atPath: modelFolder.appendingPathComponent("AudioEncoder.mlmodelc").path) else {
            throw XCTSkip("Pinned WhisperKit model absent — run scripts/setup-asr-models.sh. Nightly-only regeneration path.")
        }

        let clipURL = asrFixturesDir.appendingPathComponent("speech-pangram.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: clipURL.path), "fixture clip missing at \(clipURL.path)")

        let audioSeconds = try Self.durationSeconds(of: clipURL)

        let transcriber = WhisperKitASRTranscriber(modelFolder: modelFolder)

        // The transcriber loads the model lazily inside transcribe(), so this measures
        // end-to-end cold time (Core ML compile + model load + decode). loadSeconds is left 0
        // and transcriptionSeconds carries the full wall time; these fields are informational
        // only (the fast Done gate recomputes accuracy from words and ignores timings).
        let start = Date()
        let words = try await transcriber.transcribe(fileURL: clipURL)
        let transcriptionSeconds = Date().timeIntervalSince(start)

        XCTAssertGreaterThan(words.count, 0, "WhisperKit produced no words on the simulator")

        let golden = try loadGolden()
        let score = ASRScoring.score(words: words, golden: golden, toleranceMs: toleranceMs)

        let benchmark = ASRBenchmark(
            engine: "WhisperKit",
            engineVersion: "1.0.0",
            model: "openai_whisper-tiny.en",
            modelRevision: pinnedModelRevision,
            computeUnits: "cpuOnly",
            device: Self.deviceDescription(),
            audioSeconds: (audioSeconds * 100).rounded() / 100,
            loadSeconds: 0,
            transcriptionSeconds: (transcriptionSeconds * 1000).rounded() / 1000,
            realTimeFactor: audioSeconds > 0 ? (transcriptionSeconds / audioSeconds * 1000).rounded() / 1000 : 0,
            wordCount: words.count,
            words: words.map { TimedWord(word: $0.word, start: ($0.start * 1000).rounded() / 1000, end: ($0.end * 1000).rounded() / 1000) },
            driftMaxMs: (score.driftMaxMs).rounded(),
            driftMeanMs: (score.driftMeanMs).rounded(),
            wordErrorCount: score.wordErrorCount
        )

        try writeBenchmark(benchmark)

        XCTAssertTrue(score.boundariesWithinTolerance, "live drift exceeded ±\(toleranceMs) ms (max \(score.driftMaxMs) ms)")
        XCTAssertLessThanOrEqual(score.wordErrorCount, maxWordErrors, "live word error count \(score.wordErrorCount) > \(maxWordErrors)")
    }

    // MARK: - Helpers

    private func loadGolden() throws -> [TimedWord] {
        let url = asrFixturesDir.appendingPathComponent("asr_fixture_expected.json")
        return try JSONDecoder().decode([TimedWord].self, from: try Data(contentsOf: url))
    }

    private func writeBenchmark(_ benchmark: ASRBenchmark) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(benchmark)
        let url = asrFixturesDir.appendingPathComponent("benchmark-results.json")
        try data.write(to: url, options: .atomic)
    }

    private static func durationSeconds(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private static func deviceDescription() -> String {
        let env = ProcessInfo.processInfo.environment
        let model = env["SIMULATOR_MODEL_IDENTIFIER"] ?? "Simulator"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return "\(model) / \(os)"
    }
}
