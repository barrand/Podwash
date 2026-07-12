import Foundation
import CoreML
import WhisperKit

/// WhisperKit-backed `ASRTranscribing`. This is the ONLY file that imports WhisperKit
/// (ADR-003 §3.2) — everything else depends only on `[TimedWord]` / `ASRTranscribing`.
///
/// Loads the pinned local model folder CPU-only: the iOS Simulator has no ANE/GPU, and
/// `base.en`+ render empty output there, so `tiny.en` + `.cpuOnly` is the only combination
/// that transcribes correctly in the dark-factory simulator suite (ADR-003 §3.1 reason 2).
final class WhisperKitASRTranscriber: ASRTranscribing {

    private let modelFolder: URL

    init(modelFolder: URL) {
        self.modelFolder = modelFolder
    }

    // Avoid MainActor/TaskLocal deinit crash under SWIFT_DEFAULT_ACTOR_ISOLATION.
    nonisolated deinit {}

    func transcribe(fileURL: URL) async throws -> [TimedWord] {
        // WhisperKit 1.0.0 `ModelComputeOptions` has no `prefillCompute`; the `MLComputeUnits`
        // base must be explicit (verified empirically in the Slice 05 spike).
        let compute = ModelComputeOptions(
            melCompute: MLComputeUnits.cpuOnly,
            audioEncoderCompute: MLComputeUnits.cpuOnly,
            textDecoderCompute: MLComputeUnits.cpuOnly
        )
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            computeOptions: compute,
            verbose: false,
            prewarm: false,
            load: true,
            download: false
        )
        let pipe = try await WhisperKit(config)

        let results = try await pipe.transcribe(
            audioPath: fileURL.path,
            decodeOptions: DecodingOptions(task: .transcribe, language: "en", wordTimestamps: true)
        )

        return results
            .flatMap { $0.allWords }
            .map { TimedWord(word: $0.word, start: Double($0.start), end: Double($0.end)) }
    }
}
