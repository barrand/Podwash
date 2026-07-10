//
//  InMemoryDownloadStateStore.swift
//  PodWash
//
//  Slice 10 — In-memory download UI state (ADR-008 §5; Slice 11 persists).
//

import Foundation

enum DownloadError: Error, Equatable {
    case missingRemoteURL
    case transportFailure
    case cancelled
    case noResumeData
}

enum DownloadState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case failed
}

@MainActor
final class InMemoryDownloadStateStore {
    private var states: [String: DownloadState] = [:]

    func state(for episodeID: String) -> DownloadState {
        states[episodeID] ?? .notDownloaded
    }

    func setState(_ state: DownloadState, for episodeID: String) {
        states[episodeID] = state
    }

    func clear() {
        states.removeAll()
    }
}
