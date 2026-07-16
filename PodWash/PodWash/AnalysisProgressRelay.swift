//
//  AnalysisProgressRelay.swift
//  PodWash
//
//  Multiplexes analyzer progress so AppShellModel and AnalysisUIViewModel can
//  both observe without overwriting a single onMainActorProgress handler.
//

import Foundation

/// Fan-out for `onMainActorProgress` / `onProgress` on progress-capable analyzers.
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

    // Avoid MainActor/TaskLocal deinit crash under SWIFT_DEFAULT_ACTOR_ISOLATION
    // (XCTest teardown otherwise SIGABRT via swift_task_deinitOnExecutorImpl).
    nonisolated deinit {}

    /// Installs this relay as the sole `onMainActorProgress` sink on supported analyzers.
    /// Leaves `onProgress` alone so non-UI observers are not double-fired (analyzers invoke both).
    static func install(on analyzer: any EpisodeAnalyzing) -> AnalysisProgressRelay {
        let relay = AnalysisProgressRelay()
        // Weak capture: analyzer must not keep the relay alive past AppShellModel teardown.
        let mainActorSink: MainActorAnalysisProgressHandler = { [weak relay] snapshot in
            relay?.publish(snapshot)
        }

        if let stepped = analyzer as? SteppedEpisodeAnalyzer {
            stepped.onMainActorProgress = mainActorSink
        }
        if let instant = analyzer as? InstantEpisodeAnalyzer {
            instant.onMainActorProgress = mainActorSink
        }
        if let pipeline = analyzer as? AnalysisPipeline {
            pipeline.onMainActorProgress = mainActorSink
        }
        return relay
    }
}
