import Foundation

/// Produces word-level timestamps from an audio file. Implementations wrap a concrete
/// engine (WhisperKit today); engine types never appear on this surface so test targets
/// and the Slice 07 pipeline depend only on `[TimedWord]` (ADR-000 §4, ADR-003 §3.2).
protocol ASRTranscribing {
    /// Transcribe a local audio file to timed words. Throws on load/transcription failure;
    /// callers treat a thrown error or an empty result as a setup/measurement failure
    /// (ADR-003 AC2 — never silently skipped).
    func transcribe(fileURL: URL) async throws -> [TimedWord]
}

/// Execution-evidence + accuracy record for one benchmark run (ADR-003 §3.5).
///
/// Codable → committed at `Fixtures/asr/benchmark-results.json`. The fast test decodes it
/// and recomputes accuracy against the independent golden; the slow test re-encodes it
/// after a live WhisperKit run. The drift/error fields are informational — the fast gate
/// recomputes them from `words` and does not trust them (ADR-003 §3.4).
nonisolated struct ASRBenchmark: Codable, Equatable {
    let engine: String
    let engineVersion: String
    let model: String
    let modelRevision: String
    let computeUnits: String
    let device: String
    let audioSeconds: Double
    let loadSeconds: Double
    let transcriptionSeconds: Double
    let realTimeFactor: Double
    let wordCount: Int
    let words: [TimedWord]
    let driftMaxMs: Double
    let driftMeanMs: Double
    let wordErrorCount: Int
}

/// Deterministic accuracy scoring shared by the fast gate (recompute-from-artifact) and the
/// slow live benchmark, so both use the identical rule (ADR-003 §3.4). Word comparison
/// normalizes to lowercase + strips non-alphanumerics; alignment is positional against the
/// golden and a length mismatch counts toward the word-error budget.
nonisolated enum ASRScoring {
    struct Score: Equatable {
        let driftMaxMs: Double
        let driftMeanMs: Double
        let wordErrorCount: Int
        let boundariesWithinTolerance: Bool
    }

    static func normalize(_ word: String) -> String {
        word.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }

    /// Score transcribed `words` against `golden`. `toleranceMs` is the ±per-boundary budget.
    static func score(words: [TimedWord], golden: [TimedWord], toleranceMs: Double) -> Score {
        let n = min(words.count, golden.count)
        var maxDrift = 0.0
        var sumDrift = 0.0
        var boundaries = 0
        var wordErrors = 0
        var allWithin = true

        for i in 0..<n {
            let w = words[i], g = golden[i]
            let dStart = abs(w.start - g.start) * 1000.0
            let dEnd = abs(w.end - g.end) * 1000.0
            maxDrift = max(maxDrift, max(dStart, dEnd))
            sumDrift += dStart + dEnd
            boundaries += 2
            if dStart > toleranceMs || dEnd > toleranceMs { allWithin = false }
            if normalize(w.word) != normalize(g.word) { wordErrors += 1 }
        }
        // A length mismatch is both a word error and a coverage failure.
        if words.count != golden.count {
            wordErrors += abs(words.count - golden.count)
            allWithin = false
        }

        return Score(
            driftMaxMs: maxDrift,
            driftMeanMs: boundaries > 0 ? sumDrift / Double(boundaries) : 0,
            wordErrorCount: wordErrors,
            boundariesWithinTolerance: allWithin
        )
    }
}
