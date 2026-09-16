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

        // Browsing CarPlay works before the listener starts an episode. Playback state is
        // supplied by MPNowPlayingInfoCenter once a real engine becomes active; never create
        // a silent placeholder engine that can own an audio session or go stale.
        let updater = CarPlayNowPlayingUpdater(
            engine: nil,
            presenting: presenting
        )
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
        _ = interfaceController
    }
}
