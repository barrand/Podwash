//
//  FullPipelineSlowTests.swift
//  PodWashSlowTests
//
//  Slice 07 — Full ASR-inclusive pipeline (SLOW / nightly only — NOT a Done gate).
//  Live WhisperKit → AnalysisPipeline → intervals cover hand-computed golden within
//  ±200 ms. See docs/adr/005-analysis-pipeline.md §4–§5.
//

import XCTest
@testable import PodWash

final class FullPipelineSlowTests: XCTestCase {

    private let toleranceMs = 200.0
    private let slowTargetSet: Set<String> = ["quick", "fox", "dog"]

    private var innerProjectDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
    private var repoRoot: URL { innerProjectDir.deletingLastPathComponent() }
    private var asrFixturesDir: URL { innerProjectDir.appendingPathComponent("PodWashTests/Fixtures/asr") }
    private var analysisFixturesDir: URL { innerProjectDir.appendingPathComponent("PodWashTests/Fixtures/analysis") }

    @MainActor
    func testFullASRPipelineCoversGoldenTimestamps() async throws {
        let modelFolder = repoRoot.appendingPathComponent("Models/whisperkit-coreml/openai_whisper-tiny.en")
        guard FileManager.default.fileExists(atPath: modelFolder.appendingPathComponent("AudioEncoder.mlmodelc").path) else {
            throw XCTSkip("Pinned WhisperKit model absent — run scripts/setup-asr-models.sh. Nightly-only path.")
        }

        let clipURL = asrFixturesDir.appendingPathComponent("speech-pangram.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: clipURL.path))

        let golden = try loadSlowGolden()
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SlowPipeline-\(UUID().uuidString)", isDirectory: true)
        defer { try? IntervalCache(baseDirectory: cacheDir).clear() }

        let transcriber = WhisperKitASRTranscriber(modelFolder: modelFolder)
        let pipeline = AnalysisPipeline(
            transcriber: transcriber,
            cache: IntervalCache(baseDirectory: cacheDir)
        )

        let intervals = try await pipeline.analyze(
            episode: EpisodeIdentity(id: "slow-pangram"),
            audioURL: clipURL,
            targetWords: slowTargetSet
        )

        XCTAssertGreaterThanOrEqual(intervals.count, 1)
        assertCoverage(pipeline: intervals, golden: golden, toleranceMs: toleranceMs)
    }

    // MARK: - Helpers

    private struct GoldenInterval: Decodable {
        let start: Double
        let end: Double
    }

    private func loadSlowGolden() throws -> [GoldenInterval] {
        let url = analysisFixturesDir.appendingPathComponent("slow_pipeline_intervals.json")
        return try JSONDecoder().decode([GoldenInterval].self, from: try Data(contentsOf: url))
    }

    private func assertCoverage(
        pipeline: [CensorInterval],
        golden: [GoldenInterval],
        toleranceMs: Double
    ) {
        let toleranceSec = toleranceMs / 1000.0
        for (index, g) in golden.enumerated() {
            let covered = pipeline.contains { p in
                abs(p.start - g.start) <= toleranceSec && abs(p.end - g.end) <= toleranceSec
            }
            XCTAssertTrue(
                covered,
                "No pipeline interval covers golden[\(index)] [\(g.start), \(g.end)] within ±\(toleranceMs) ms"
            )
        }
    }
}
