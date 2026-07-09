//
//  PlaybackCoordinator.swift
//  PodWash
//
//  Slice 08 — Wires cached/pipeline intervals into PlaybackEngine with a swappable
//  action setting (ADR-006). Action toggles re-apply the schedule only — no re-analysis.
//

import Foundation

/// Wires cached/pipeline intervals into the player with a swappable action setting.
@MainActor
final class PlaybackCoordinator {

    private let pipeline: any EpisodeAnalyzing
    private let engine: PlaybackEngine

    private(set) var cachedIntervals: [CensorInterval] = []
    private(set) var currentAction: CensorAction = .mute

    init(pipeline: any EpisodeAnalyzing, engine: PlaybackEngine) {
        self.pipeline = pipeline
        self.engine = engine
    }

    /// Runs `analyze` once (cache hit or miss), stores returned bounds, applies `action`.
    func preparePlayback(
        episode: EpisodeIdentity,
        audioURL: URL,
        targetWords: Set<String>,
        action: CensorAction = .mute,
        injectedTranscript: [TimedWord]? = nil
    ) async throws {
        let intervals = try await pipeline.analyze(
            episode: episode,
            audioURL: audioURL,
            targetWords: targetWords,
            injectedTranscript: injectedTranscript
        )
        cachedIntervals = intervals
        currentAction = action
        await applyCurrentSchedule()
    }

    /// Re-maps stored bounds to `action` and re-applies schedule. Does not call `analyze`.
    func setAction(_ action: CensorAction) async {
        guard action != currentAction else { return }
        currentAction = action
        await applyCurrentSchedule()
    }

    private func applyCurrentSchedule() async {
        let mapped = cachedIntervals.map {
            CensorInterval(start: $0.start, end: $0.end, action: currentAction)
        }
        await engine.applySchedule(IntervalSchedule(intervals: mapped))
    }
}
