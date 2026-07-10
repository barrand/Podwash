//
//  RemoteCommandHandling.swift
//  PodWash
//
//  Slice 14 — Injectable MPRemoteCommandCenter seam (ADR-011 §3).
//

import Foundation
import MediaPlayer

@MainActor
protocol RemoteCommandHandling: AnyObject {
    func installPlayHandler(_ handler: @escaping () -> MPRemoteCommandHandlerStatus)
    func installPauseHandler(_ handler: @escaping () -> MPRemoteCommandHandlerStatus)
    func installSkipForwardHandler(
        interval: TimeInterval,
        _ handler: @escaping () -> MPRemoteCommandHandlerStatus
    )
    func installSkipBackwardHandler(
        interval: TimeInterval,
        _ handler: @escaping () -> MPRemoteCommandHandlerStatus
    )
    func installChangePlaybackPositionHandler(
        _ handler: @escaping (_ position: TimeInterval) -> MPRemoteCommandHandlerStatus
    )
}

/// Production adapter targeting `MPRemoteCommandCenter.shared()`.
@MainActor
final class MPRemoteCommandCenterAdapter: RemoteCommandHandling {
    // nonisolated(unsafe): avoid MainActor TaskLocal hop when releasing in deinit
    // (XCTest teardown otherwise hits BUG_IN_CLIENT_OF_LIBMALLOC via swift_task_deinitOnExecutorImpl).
    nonisolated(unsafe) private let center: MPRemoteCommandCenter

    init(center: MPRemoteCommandCenter = .shared()) {
        self.center = center
    }

    // Avoid MainActor/TaskLocal deinit crash (same pattern as QueueCoordinator).
    nonisolated deinit {}

    func installPlayHandler(_ handler: @escaping () -> MPRemoteCommandHandlerStatus) {
        center.playCommand.isEnabled = true
        center.playCommand.removeTarget(nil)
        center.playCommand.addTarget { _ in handler() }
    }

    func installPauseHandler(_ handler: @escaping () -> MPRemoteCommandHandlerStatus) {
        center.pauseCommand.isEnabled = true
        center.pauseCommand.removeTarget(nil)
        center.pauseCommand.addTarget { _ in handler() }
    }

    func installSkipForwardHandler(
        interval: TimeInterval,
        _ handler: @escaping () -> MPRemoteCommandHandlerStatus
    ) {
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: interval)]
        center.skipForwardCommand.removeTarget(nil)
        center.skipForwardCommand.addTarget { _ in handler() }
    }

    func installSkipBackwardHandler(
        interval: TimeInterval,
        _ handler: @escaping () -> MPRemoteCommandHandlerStatus
    ) {
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: interval)]
        center.skipBackwardCommand.removeTarget(nil)
        center.skipBackwardCommand.addTarget { _ in handler() }
    }

    func installChangePlaybackPositionHandler(
        _ handler: @escaping (TimeInterval) -> MPRemoteCommandHandlerStatus
    ) {
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.addTarget { event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            return handler(positionEvent.positionTime)
        }
    }
}
