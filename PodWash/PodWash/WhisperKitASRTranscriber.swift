import Foundation
import CoreML
import WhisperKit

/// Compute preference for WhisperKit — framework types stay inside this file (ADR-024).
enum ASRComputePreference: Equatable, Sendable {
    /// Force mel / encoder / decoder `.cpuOnly` (simulator Done path).
    case cpuOnly
    /// `ModelComputeOptions()` — ANE-capable on device; WhisperKit itself
    /// auto-forces cpuOnly when running on the simulator (defense in depth).
    case whisperKitDefault
}

/// WhisperKit-backed `ASRTranscribing`. This is the ONLY file that imports WhisperKit
/// (ADR-003 §3.2) — everything else depends only on `[TimedWord]` / `ASRTranscribing`.
///
/// Simulator production path uses `tiny.en` + `.cpuOnly` (ADR-003 / ADR-024).
/// Device production path uses `base.en` + WhisperKit defaults (ANE-capable).
final class WhisperKitASRTranscriber: ASRTranscribing {

    private let modelFolder: URL
    private let compute: ASRComputePreference

    init(modelFolder: URL, compute: ASRComputePreference = .cpuOnly) {
        self.modelFolder = modelFolder
        self.compute = compute
    }

    // Avoid MainActor/TaskLocal deinit crash under SWIFT_DEFAULT_ACTOR_ISOLATION.
    nonisolated deinit {}

    func transcribe(fileURL: URL) async throws -> [TimedWord] {
        // WhisperKit 1.0.0 `ModelComputeOptions` has no `prefillCompute`; the `MLComputeUnits`
        // base must be explicit for cpuOnly (verified empirically in the Slice 05 spike).
        let computeOptions: ModelComputeOptions
        switch compute {
        case .cpuOnly:
            computeOptions = ModelComputeOptions(
                melCompute: MLComputeUnits.cpuOnly,
                audioEncoderCompute: MLComputeUnits.cpuOnly,
                textDecoderCompute: MLComputeUnits.cpuOnly
            )
        case .whisperKitDefault:
            computeOptions = ModelComputeOptions()
        }
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            computeOptions: computeOptions,
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
