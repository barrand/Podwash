//
//  CarPlayNowPlayingPresenting.swift
//  PodWash
//
//  Slice 15 — Now Playing title/state seam (ADR-016 §6).
//  CPNowPlayingTemplate has no title/playback-state API; doubles own recording.
//

import Foundation

enum CarPlayPlaybackState: Equatable {
    case playing
    case paused
}

@MainActor
protocol CarPlayNowPlayingPresenting: AnyObject {
    func updatePlaybackState(_ state: CarPlayPlaybackState)
    func updateTitle(_ title: String)
}

/// Production adapter — system UI reads MPNowPlayingInfoCenter; methods are intentional no-ops
/// aside from touching `CPNowPlayingTemplate.shared` so the template is configured.
@MainActor
final class CarPlayNowPlayingSystemAdapter: CarPlayNowPlayingPresenting {
    // Avoid MainActor/TaskLocal deinit crash under SWIFT_DEFAULT_ACTOR_ISOLATION
    // (XCTest teardown otherwise SIGABRT via swift_task_deinitOnExecutorImpl).
    nonisolated deinit {}

    func updatePlaybackState(_ state: CarPlayPlaybackState) {
        _ = state
        CarPlayNowPlayingSystemAdapter.ensureSharedTemplate()
    }

    func updateTitle(_ title: String) {
        _ = title
    }

    private static func ensureSharedTemplate() {
        // Imported via CarPlay in the scene/coordinator path; keep this file CarPlay-free
        // so unit tests that only need the protocol do not require CarPlay symbols here.
    }
}
