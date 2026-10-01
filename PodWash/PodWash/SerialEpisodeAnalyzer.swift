import Foundation

/// All preparation owners share this gate. A cancelled caller still waits for
/// adapters that observe cancellation late before the next analysis may start.
@MainActor final class SerialEpisodeAnalyzer: EpisodeAnalyzing, @unchecked Sendable {
    private let underlying: any EpisodeAnalyzing
    private var tail: Task<Void, Never>?

    init(_ underlying: any EpisodeAnalyzing) { self.underlying = underlying }
    nonisolated deinit {}

    static func pipeline(for analyzer: any EpisodeAnalyzing) -> AnalysisPipeline? {
        if let serial = analyzer as? SerialEpisodeAnalyzer {
            return pipeline(for: serial.underlying)
        }
        if let pipeline = analyzer as? AnalysisPipeline { return pipeline }
        // Existing diagnostic/test adapters expose their wrapped pipeline as inner.
        return Mirror(reflecting: analyzer).children.first { $0.label == "inner" }?.value as? AnalysisPipeline
    }

    func analyze(episode: EpisodeIdentity, audioURL: URL, targetWords: Set<String>,
                 injectedTranscript: [TimedWord]?, profanityAction: CensorAction,
                 unrelatedContent: UnrelatedContentOptions) async throws -> [CensorInterval] {
        let predecessor = tail
        let analyzer = underlying
        let pipeline = Self.pipeline(for: analyzer)
        let segmentationContext = pipeline?.segmentationContext
        let request = Task { @MainActor in
            await predecessor?.value
            try Task.checkCancellation()
            if let segmentationContext { pipeline?.segmentationContext = segmentationContext }
            return try await analyzer.analyze(episode: episode, audioURL: audioURL,
                targetWords: targetWords, injectedTranscript: injectedTranscript,
                profanityAction: profanityAction, unrelatedContent: unrelatedContent)
        }
        tail = Task { _ = await request.result }
        return try await withTaskCancellationHandler {
            try await request.value
        } onCancel: { request.cancel() }
    }
}
