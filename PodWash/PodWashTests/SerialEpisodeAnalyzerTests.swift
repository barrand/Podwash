import XCTest
@testable import PodWash

@MainActor final class SerialEpisodeAnalyzerTests: XCTestCase {
    func testLateCancellationCannotOverlapNextOwner() async throws {
        let analyzer = LateCancellationAnalyzer()
        let gate = SerialEpisodeAnalyzer(analyzer)
        let first = Task { try await analyze(gate, id: "first") }
        while analyzer.calls == 0 { await Task.yield() }
        first.cancel()
        let second = Task { try await analyze(gate, id: "second") }
        _ = try await second.value
        _ = await first.result
        XCTAssertEqual(analyzer.maximumConcurrent, 1)
        XCTAssertEqual(analyzer.calls, 2)
    }

    func testCancelledWaitingOwnerNeverStartsAnalysis() async throws {
        let analyzer = LateCancellationAnalyzer()
        let gate = SerialEpisodeAnalyzer(analyzer)
        let first = Task { try await analyze(gate, id: "first") }
        while analyzer.calls == 0 { await Task.yield() }
        let waiting = Task { try await analyze(gate, id: "cancelled") }
        await Task.yield()
        waiting.cancel()
        _ = try await first.value
        do { _ = try await waiting.value; XCTFail("Expected cancelled waiter") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(analyzer.calls, 1)
    }

    private func analyze(_ gate: SerialEpisodeAnalyzer, id: String) async throws -> [CensorInterval] {
        try await gate.analyze(episode: EpisodeIdentity(id: id), audioURL: URL(fileURLWithPath: "/fixture.m4a"),
            targetWords: [], injectedTranscript: nil, profanityAction: .mute,
            unrelatedContent: UnrelatedContentOptions(enabled: false))
    }
}

@MainActor private final class LateCancellationAnalyzer: EpisodeAnalyzing, @unchecked Sendable {
    var calls = 0
    var active = 0
    var maximumConcurrent = 0
    nonisolated deinit {}
    func analyze(episode: EpisodeIdentity, audioURL: URL, targetWords: Set<String>,
                 injectedTranscript: [TimedWord]?, profanityAction: CensorAction,
                 unrelatedContent: UnrelatedContentOptions) async throws -> [CensorInterval] {
        calls += 1
        active += 1
        maximumConcurrent = max(maximumConcurrent, active)
        // Deliberately ignores cancellation, like a non-cooperative ASR adapter.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { continuation.resume() }
        }
        active -= 1
        return []
    }
}
