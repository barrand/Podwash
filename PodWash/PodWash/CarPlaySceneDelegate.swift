//
//  CarPlaySceneDelegate.swift
//  PodWash
//
//  Slice 15 — CPTemplateApplicationSceneDelegate adapter (ADR-016 §7).
//

import CarPlay
import Foundation

final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var coordinator: CarPlayCoordinator?
    private var nowPlayingUpdater: CarPlayNowPlayingUpdater?
    /// Retained when no live engine exists yet so coordinator init stays non-optional.
    private var idleEngine: PlaybackEngine?

    // Avoid MainActor/TaskLocal deinit crash under SWIFT_DEFAULT_ACTOR_ISOLATION
    // (same pattern as CarPlayCoordinator / LibraryViewModel).
    nonisolated deinit {}

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        guard let provider = CarPlayDependencies.provider else { return }
        guard let player = provider.carPlayEpisodePlayer else { return }

        let builder = CarPlayStoreBuilder(store: provider.podcastStore, queue: provider.queueStore)
        let presenting = CarPlayNowPlayingSystemAdapter()

        let engine: PlaybackEngine
        if let live = provider.carPlayPlaybackEngine {
            engine = live
            idleEngine = nil
        } else {
            // Lists work before phone playback; updater attaches to a silent idle engine.
            let idle = PlaybackEngine(
                url: FixtureAudio.bundledURL() ?? URL(fileURLWithPath: "/dev/null"),
                title: "",
                artist: "PodWash"
            )
            idleEngine = idle
            engine = idle
        }

        let updater = CarPlayNowPlayingUpdater(engine: engine, presenting: presenting)
        nowPlayingUpdater = updater

        let coordinator = CarPlayCoordinator(
            builder: builder,
            player: player,
            nowPlaying: updater
        )
        self.coordinator = coordinator
        coordinator.activateRoot(interfaceController: interfaceController)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        coordinator?.clearInterfaceController()
        coordinator = nil
        nowPlayingUpdater = nil
        idleEngine = nil
        _ = interfaceController
    }
}
