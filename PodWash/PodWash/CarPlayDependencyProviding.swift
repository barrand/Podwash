//
//  CarPlayDependencyProviding.swift
//  PodWash
//
//  Slice 15 — App-launch registration of stores / player for CarPlay scene (ADR-016 §7).
//

import Foundation

@MainActor
protocol CarPlayDependencyProviding: AnyObject {
    var podcastStore: PodcastStore { get }
    var queueStore: QueueStore { get }
    var carPlayEpisodePlayer: (any EpisodePlaying)? { get }
    var carPlayPlaybackEngine: PlaybackEngine? { get }
}

@MainActor
enum CarPlayDependencies {
    private(set) static weak var provider: (any CarPlayDependencyProviding)?

    static func register(_ provider: any CarPlayDependencyProviding) {
        self.provider = provider
    }

    static func unregister(_ provider: any CarPlayDependencyProviding) {
        if self.provider === provider {
            self.provider = nil
        }
    }
}
