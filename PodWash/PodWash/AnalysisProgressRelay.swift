//
//  AnalysisProgressRelay.swift
//  PodWash
//
//  Multiplexes analyzer progress so AppShellModel and AnalysisUIViewModel can
//  both observe without overwriting a single onMainActorProgress handler.
//

import Foundation

/// Fan-out for `onMainActorProgress` / `onProgress` on progress-capable analyzers.
/// Also fans out progressive `onPartialIntervals` snapshots so player progress chrome
/// updates when an analyzer publishes chunk frontiers without a separate progress hook
/// (ADR-030 / Slice 33 — `processedEnd/duration` while in flight).
final class AnalysisProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    /// `nonisolated(unsafe)`: MainActor handler values must not destroy via TaskLocal hop in deinit.
    nonisolated(unsafe) private var handlers: [UUID: MainActorAnalysisProgressHandler] = [:]

    /// Registers a main-actor handler; call `removeHandler` on teardown.
    @discardableResult
    func addHandler(_ handler: @escaping MainActorAnalysisProgressHandler) -> UUID {
        let id = UUID()
        lock.lock()
        handlers[id] = handler
        lock.unlock()
        return id
    }

    func removeHandler(_ id: UUID) {
        lock.lock()
        handlers[id] = nil
        lock.unlock()
    }

    /// Invoked on the main actor from analyzer `MainActor.run` blocks.
    @MainActor
    func publish(_ snapshot: AnalysisProgressSnapshot) {
        lock.lock()
        let copy = Array(handlers.values)
        lock.unlock()
        for handler in copy {
            handler(snapshot)
        }
    }

    /// Publishes a progressive partial snapshot onto the main actor.
    /// Analyzers invoke `onPartialIntervals` from `MainActor.run`; keep sync on that
    /// path so `playbackAnalysisSnapshot` updates before chunk-ready / play gates.
    private func publishFromPartial(_ snapshot: AnalysisProgressSnapshot) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                publish(snapshot)
            }
        } else {
            Task { @MainActor [weak self] in
                self?.publish(snapshot)
            }
        }
    }

    // Avoid MainActor/TaskLocal deinit crash under SWIFT_DEFAULT_ACTOR_ISOLATION
    // (XCTest teardown otherwise SIGABRT via swift_task_deinitOnExecutorImpl).
    nonisolated deinit {}

    /// Installs this relay as the `onMainActorProgress` sink on supported analyzers,
    /// and chains `onPartialIntervals` so progressive chunk snapshots reach progress chrome.
    /// Leaves `onProgress` alone so non-UI observers are not double-fired (analyzers invoke both).
    static func install(on analyzer: any EpisodeAnalyzing) -> AnalysisProgressRelay {
        let relay = AnalysisProgressRelay()
        // Weak capture: analyzer must not keep the relay alive past AppShellModel teardown.
        let mainActorSink: MainActorAnalysisProgressHandler = { [weak relay] snapshot in
            relay?.publish(snapshot)
        }
        let partialSink: AnalysisPartialIntervalsHandler = { [weak relay] _, snapshot in
            relay?.publishFromPartial(snapshot)
        }

        if let stepped = analyzer as? SteppedEpisodeAnalyzer {
            stepped.onMainActorProgress = mainActorSink
            let previous = stepped.onPartialIntervals
            stepped.onPartialIntervals = { intervals, snapshot in
                previous?(intervals, snapshot)
                partialSink(intervals, snapshot)
            }
        } else if let instant = analyzer as? InstantEpisodeAnalyzer {
            instant.onMainActorProgress = mainActorSink
            let previous = instant.onPartialIntervals
            instant.onPartialIntervals = { intervals, snapshot in
                previous?(intervals, snapshot)
                partialSink(intervals, snapshot)
            }
        } else if let pipeline = analyzer as? AnalysisPipeline {
            pipeline.onMainActorProgress = mainActorSink
            let previous = pipeline.onPartialIntervals
            pipeline.onPartialIntervals = { intervals, snapshot in
                previous?(intervals, snapshot)
                partialSink(intervals, snapshot)
            }
        } else {
            // Test doubles with a real `onPartialIntervals` stored property
            // (e.g. ProgressiveSteppedTestAnalyzer) — same cast pattern as PlaybackCoordinator.
            let previous = analyzer.onPartialIntervals
            analyzer.onPartialIntervals = { intervals, snapshot in
                previous?(intervals, snapshot)
                partialSink(intervals, snapshot)
            }
        }
        return relay
    }
}
