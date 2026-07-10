//
//  RemoteCommandCoordinator.swift
//  PodWash
//
//  Slice 14 — Registers lock-screen / Control Center transport handlers (ADR-011 §4).
//

import Foundation
import MediaPlayer

@MainActor
final class RemoteCommandCoordinator {
    // nonisolated(unsafe): avoid MainActor TaskLocal hop when releasing these in deinit
    // (XCTest teardown otherwise hits BUG_IN_CLIENT_OF_LIBMALLOC via swift_task_deinitOnExecutorImpl).
    nonisolated(unsafe) private let commands: any RemoteCommandHandling
    nonisolated(unsafe) private weak var transport: (any PlaybackTransporting)?
    nonisolated(unsafe) private var didActivate = false

    private static let skipInterval: TimeInterval = 15

    init(commands: any RemoteCommandHandling) {
        self.commands = commands
    }

    // Avoid MainActor/TaskLocal deinit crash (same pattern as QueueCoordinator).
    nonisolated deinit {}

    /// Registers handlers once on the command-center seam.
    func activate() {
        guard !didActivate else { return }
        didActivate = true

        commands.installPlayHandler { [weak self] in
            guard let transport = self?.transport else {
                return .noActionableNowPlayingItem
            }
            transport.play()
            return .success
        }

        commands.installPauseHandler { [weak self] in
            guard let transport = self?.transport else {
                return .noActionableNowPlayingItem
            }
            transport.pause()
            return .success
        }

        commands.installSkipForwardHandler(interval: Self.skipInterval) { [weak self] in
            guard let transport = self?.transport else {
                return .noActionableNowPlayingItem
            }
            transport.seek(by: Self.skipInterval)
            return .success
        }

        commands.installSkipBackwardHandler(interval: Self.skipInterval) { [weak self] in
            guard let transport = self?.transport else {
                return .noActionableNowPlayingItem
            }
            transport.seek(by: -Self.skipInterval)
            return .success
        }

        commands.installChangePlaybackPositionHandler { [weak self] position in
            guard let transport = self?.transport else {
                return .noActionableNowPlayingItem
            }
            transport.seek(to: position, completion: nil)
            return .success
        }
    }

    /// Bind/rebind the active engine (or spy). Handlers no-op with
    /// `.noActionableNowPlayingItem` when unbound.
    func bind(_ transport: (any PlaybackTransporting)?) {
        self.transport = transport
    }
}
