//
//  CarPlayDoubles.swift
//  PodWashTests
//
//  Slice 15 — Injectable CarPlay template doubles (ADR-016 §5–§6).
//
//  CPListTemplateRecorder mirrors CPListItem rows and selection handlers without a
//  live CPTemplateApplicationScene. CPNowPlayingTemplateDouble records title/state
//  updates because CPNowPlayingTemplate.shared exposes no title or playback-state API
//  (ADR-016 §9 spike).
//
//  Seam keys follow slice-15-ux.md (carPlay.libraryList, carPlay.queueList, etc.).
//  Until CarPlayListPresenting / CarPlayNowPlayingPresenting exist in the app target
//  (Engineer), this file fails to compile — intended TDD red state.
//

import UIKit
import XCTest
@testable import PodWash

// MARK: - List seam keys (slice-15-ux.md)

enum CarPlayListKey {
    static let libraryList = "carPlay.libraryList"
    static let showList = "carPlay.showList"
    static let queueList = "carPlay.queueList"
    static let tabLibrary = "carPlay.tab.library"
    static let tabQueue = "carPlay.tab.queue"
}

// MARK: - CPListTemplateRecorder (ADR-016 §5)

/// Records list rows and per-index selection handlers for programmatic AC asserts.
@MainActor
final class CPListTemplateRecorder: CarPlayListPresenting {
    struct RecordedRow: Equatable {
        let text: String
        let imageIsNonNil: Bool
        let episodeID: String?
        let subscriptionIndex: Int?
    }

    private(set) var itemsByListKey: [String: [RecordedRow]] = [:]
    private var selectionHandlers: [String: [Int: () -> Void]] = [:]

    // Avoid MainActor/TaskLocal deinit crash under SWIFT_DEFAULT_ACTOR_ISOLATION
    // (XCTest teardown otherwise SIGABRT via swift_task_deinitOnExecutorImpl).
    nonisolated deinit {}

    func setItems(_ items: [CarPlayListItemModel], listKey: String) {
        itemsByListKey[listKey] = items.map { model in
            RecordedRow(
                text: model.text,
                imageIsNonNil: model.image != nil,
                episodeID: model.episodeID,
                subscriptionIndex: model.subscriptionIndex
            )
        }
        selectionHandlers[listKey] = [:]
    }

    func setSelectionHandler(listKey: String, at index: Int, handler: @escaping () -> Void) {
        var handlers = selectionHandlers[listKey] ?? [:]
        handlers[index] = handler
        selectionHandlers[listKey] = handlers
    }

    func recordedText(at index: Int, listKey: String) -> String? {
        guard let items = itemsByListKey[listKey], items.indices.contains(index) else {
            return nil
        }
        return items[index].text
    }

    func recordedEpisodeID(at index: Int, listKey: String) -> String? {
        guard let items = itemsByListKey[listKey], items.indices.contains(index) else {
            return nil
        }
        return items[index].episodeID
    }

    func recordedImageIsNonNil(at index: Int, listKey: String) -> Bool {
        guard let items = itemsByListKey[listKey], items.indices.contains(index) else {
            return false
        }
        return items[index].imageIsNonNil
    }

    /// Invokes the stored handler at `index`, mirroring CPListItem.handler + completion.
    func fireSelection(listKey: String, at index: Int, file: StaticString = #filePath, line: UInt = #line) {
        guard let handler = selectionHandlers[listKey]?[index] else {
            XCTFail(
                "No selection handler for listKey=\(listKey) index=\(index)",
                file: file,
                line: line
            )
            return
        }
        handler()
    }
}

// MARK: - CPNowPlayingTemplateDouble (ADR-016 §6)

/// Records CarPlayNowPlayingPresenting callbacks for AC5 without live Now Playing template APIs.
@MainActor
final class CPNowPlayingTemplateDouble: CarPlayNowPlayingPresenting {
    private(set) var playbackStateUpdates: [CarPlayPlaybackState] = []
    private(set) var lastTitle: String?

    // Avoid MainActor/TaskLocal deinit crash under SWIFT_DEFAULT_ACTOR_ISOLATION
    // (XCTest teardown otherwise SIGABRT via swift_task_deinitOnExecutorImpl).
    nonisolated deinit {}

    func updatePlaybackState(_ state: CarPlayPlaybackState) {
        playbackStateUpdates.append(state)
    }

    func updateTitle(_ title: String) {
        lastTitle = title
    }
}
