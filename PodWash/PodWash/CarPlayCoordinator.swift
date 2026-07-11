//
//  CarPlayCoordinator.swift
//  PodWash
//
//  Slice 15 — Wires CarPlay list models to EpisodePlaying + optional list double (ADR-016 §5).
//

import CarPlay
import Foundation

@MainActor
final class CarPlayCoordinator {
    // nonisolated(unsafe): avoid MainActor TaskLocal hop when releasing in deinit
    // (XCTest teardown otherwise SIGABRT via swift_task_deinitOnExecutorImpl).
    nonisolated(unsafe) private let builder: any CarPlayTemplateBuilding
    nonisolated(unsafe) private let player: any EpisodePlaying
    nonisolated(unsafe) private let nowPlaying: CarPlayNowPlayingUpdater
    nonisolated(unsafe) private let listRecorder: (any CarPlayListPresenting)?

    private weak var interfaceController: CPInterfaceController?

    init(
        builder: any CarPlayTemplateBuilding,
        player: any EpisodePlaying,
        nowPlaying: CarPlayNowPlayingUpdater,
        listRecorder: (any CarPlayListPresenting)? = nil
    ) {
        self.builder = builder
        self.player = player
        self.nowPlaying = nowPlaying
        self.listRecorder = listRecorder
    }

    // Avoid MainActor/TaskLocal deinit crash under SWIFT_DEFAULT_ACTOR_ISOLATION
    // (XCTest teardown otherwise SIGABRT via swift_task_deinitOnExecutorImpl).
    nonisolated deinit {}

    /// Install root tab templates (or record them on the list double).
    func activateRoot(interfaceController: CPInterfaceController? = nil) {
        nowPlaying.attach()
        self.interfaceController = interfaceController

        let libraryItems = builder.libraryListItems()
        let queueItems = builder.queueListItems()

        if let listRecorder {
            listRecorder.setItems(libraryItems, listKey: "carPlay.libraryList")
            for index in libraryItems.indices {
                listRecorder.setSelectionHandler(listKey: "carPlay.libraryList", at: index) { [weak self] in
                    self?.pushShowList(subscriptionIndex: index)
                }
            }

            listRecorder.setItems(queueItems, listKey: "carPlay.queueList")
            for index in queueItems.indices {
                listRecorder.setSelectionHandler(listKey: "carPlay.queueList", at: index) { [weak self] in
                    self?.selectQueueItem(at: index)
                }
            }
        }

        guard let interfaceController else { return }

        let libraryTemplate = makeListTemplate(
            title: "Library",
            items: libraryItems,
            isLibrary: true
        )
        let queueTemplate = makeListTemplate(
            title: "Queue",
            items: queueItems,
            isLibrary: false
        )
        let tabBar = CPTabBarTemplate(templates: [libraryTemplate, queueTemplate])
        interfaceController.setRootTemplate(tabBar, animated: false) { _, _ in }
    }

    func clearInterfaceController() {
        interfaceController = nil
    }

    /// Programmatic selection for tests / handler body (AC4).
    func selectQueueItem(at index: Int) {
        let items = builder.queueListItems()
        guard items.indices.contains(index), let episodeID = items[index].episodeID else { return }
        player.play(episodeID: episodeID)
    }

    func selectShowEpisode(subscriptionIndex: Int, episodeIndex: Int) {
        let items = builder.showListItems(subscriptionIndex: subscriptionIndex)
        guard items.indices.contains(episodeIndex), let episodeID = items[episodeIndex].episodeID else {
            return
        }
        player.play(episodeID: episodeID)
    }

    private func pushShowList(subscriptionIndex: Int) {
        let items = builder.showListItems(subscriptionIndex: subscriptionIndex)

        if let listRecorder {
            listRecorder.setItems(items, listKey: "carPlay.showList")
            for index in items.indices {
                listRecorder.setSelectionHandler(listKey: "carPlay.showList", at: index) { [weak self] in
                    self?.selectShowEpisode(subscriptionIndex: subscriptionIndex, episodeIndex: index)
                }
            }
        }

        guard let interfaceController else { return }
        let showTemplate = makeShowListTemplate(
            subscriptionIndex: subscriptionIndex,
            items: items
        )
        interfaceController.pushTemplate(showTemplate, animated: true) { _, _ in }
    }

    private func makeListTemplate(
        title: String,
        items: [CarPlayListItemModel],
        isLibrary: Bool
    ) -> CPListTemplate {
        let cpItems: [CPListItem] = items.enumerated().map { index, model in
            let item = CPListItem(text: model.text, detailText: nil, image: model.image)
            if isLibrary {
                item.accessoryType = .disclosureIndicator
                item.handler = { [weak self] _, completion in
                    self?.pushShowList(subscriptionIndex: index)
                    completion()
                }
            } else {
                item.handler = { [weak self] _, completion in
                    self?.selectQueueItem(at: index)
                    completion()
                }
            }
            if let episodeID = model.episodeID {
                item.userInfo = episodeID
            } else if let subscriptionIndex = model.subscriptionIndex {
                item.userInfo = String(subscriptionIndex)
            }
            return item
        }

        let section = CPListSection(items: cpItems)
        return CPListTemplate(title: title, sections: [section])
    }

    private func makeShowListTemplate(
        subscriptionIndex: Int,
        items: [CarPlayListItemModel]
    ) -> CPListTemplate {
        let cpItems: [CPListItem] = items.enumerated().map { index, model in
            let item = CPListItem(text: model.text, detailText: nil, image: model.image)
            if let episodeID = model.episodeID {
                item.userInfo = episodeID
            }
            item.handler = { [weak self] _, completion in
                self?.selectShowEpisode(subscriptionIndex: subscriptionIndex, episodeIndex: index)
                completion()
            }
            return item
        }
        let section = CPListSection(items: cpItems)
        return CPListTemplate(title: "Episodes", sections: [section])
    }
}
