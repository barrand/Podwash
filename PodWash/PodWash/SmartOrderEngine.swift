//
//  SmartOrderEngine.swift
//  PodWash
//
//  ADR-029 — Pure smart-autoplay ordering (binge + LRP rotation).
//

import Foundation

/// Snapshot of one episode for ordering decisions.
nonisolated struct SmartOrderEpisode: Equatable, Sendable {
    let id: String
    let title: String
    let pubDate: Date
    let isPlayed: Bool
    let playbackPosition: TimeInterval
    let dismissedFromAutoplay: Bool
}

/// Snapshot of one subscribed show.
nonisolated struct SmartOrderShow: Equatable, Sendable {
    let feedURL: URL
    let title: String
    let isBinge: Bool
    let lastHeardAt: Date?
    let episodes: [SmartOrderEpisode]
}

/// Peek row for Coming up UI.
nonisolated struct ComingUpItem: Equatable, Sendable {
    let episodeID: String
    let episodeTitle: String
    let podcastTitle: String
    let feedURL: URL
    let isBinge: Bool
}

/// Pure smart-order logic (ADR-029). No Core Data / networking.
nonisolated struct SmartOrderEngine: Sendable {
    /// When true and `activeBingeFeedURL` is set, next picks stay in that show.
    var activeBingeFeedURL: URL?

    /// Eligible = not played, not dismissed. Unfinished (position > 0) allowed.
    static func isEligible(_ episode: SmartOrderEpisode) -> Bool {
        !episode.isPlayed && !episode.dismissedFromAutoplay
    }

    /// Oldest-first eligible episodes for a binge show.
    static func bingeQueue(for show: SmartOrderShow) -> [SmartOrderEpisode] {
        show.episodes
            .filter(isEligible)
            .sorted { lhs, rhs in
                if lhs.pubDate != rhs.pubDate { return lhs.pubDate < rhs.pubDate }
                return lhs.id < rhs.id
            }
    }

    /// Newest eligible episode for a non-binge show (nil if none).
    static func latestEligible(for show: SmartOrderShow) -> SmartOrderEpisode? {
        show.episodes
            .filter(isEligible)
            .max { lhs, rhs in
                if lhs.pubDate != rhs.pubDate { return lhs.pubDate < rhs.pubDate }
                return lhs.id < rhs.id
            }
    }

    /// Shows ordered by least-recently-heard (nil lastHeardAt sorts first), then title.
    static func showsByLeastRecentlyHeard(_ shows: [SmartOrderShow]) -> [SmartOrderShow] {
        shows.sorted { lhs, rhs in
            switch (lhs.lastHeardAt, rhs.lastHeardAt) {
            case (nil, nil):
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            case (nil, _):
                return true
            case (_, nil):
                return false
            case let (l?, r?):
                if l != r { return l < r }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
    }

    /// Next episode after `currentEpisodeID` ends (or nil if nothing left).
    /// - Parameter skipToNextShow: when true (Skip control), exit active binge and
    ///   pick the next show in LRP rotation (not the next episode in-show).
    func nextEpisode(
        shows: [SmartOrderShow],
        currentEpisodeID: String?,
        currentFeedURL: URL?,
        skipToNextShow: Bool = false
    ) -> ComingUpItem? {
        peek(
            count: 1,
            shows: shows,
            currentEpisodeID: currentEpisodeID,
            currentFeedURL: currentFeedURL,
            skipToNextShow: skipToNextShow
        ).first
    }

    /// Predicted upcoming episodes (does not mutate state).
    func peek(
        count: Int,
        shows: [SmartOrderShow],
        currentEpisodeID: String?,
        currentFeedURL: URL?,
        skipToNextShow: Bool = false
    ) -> [ComingUpItem] {
        guard count > 0 else { return [] }

        var working = shows
        var bingeURL = activeBingeFeedURL
        var results: [ComingUpItem] = []
        var excludeIDs = Set<String>()
        if let currentEpisodeID {
            excludeIDs.insert(currentEpisodeID)
        }

        // Simulate dismiss of current when skipping to next show.
        if skipToNextShow, let currentEpisodeID {
            working = Self.markDismissed(episodeID: currentEpisodeID, in: working)
            bingeURL = nil
        }

        // Enter binge if current show is binge and we're not skipping away.
        if !skipToNextShow,
           let feedURL = currentFeedURL,
           let show = working.first(where: { $0.feedURL == feedURL }),
           show.isBinge {
            bingeURL = feedURL
        }

        var guardRails = 0
        while results.count < count, guardRails < 64 {
            guardRails += 1
            if let activeBinge = bingeURL,
               let show = working.first(where: { $0.feedURL == activeBinge }),
               show.isBinge {
                let queue = Self.bingeQueue(for: show).filter { !excludeIDs.contains($0.id) }
                if let next = queue.first {
                    results.append(Self.item(episode: next, show: show))
                    excludeIDs.insert(next.id)
                    continue
                }
                // Binge exhausted — fall through to global rotation.
                bingeURL = nil
            }

            let ordered = Self.showsByLeastRecentlyHeard(working)
            var picked: ComingUpItem?
            for show in ordered {
                if show.isBinge {
                    let queue = Self.bingeQueue(for: show).filter { !excludeIDs.contains($0.id) }
                    if let next = queue.first {
                        picked = Self.item(episode: next, show: show)
                        bingeURL = show.feedURL
                        break
                    }
                } else if let latest = Self.latestEligible(for: show),
                          !excludeIDs.contains(latest.id) {
                    picked = Self.item(episode: latest, show: show)
                    break
                }
            }
            guard let picked else { break }
            results.append(picked)
            excludeIDs.insert(picked.episodeID)
            // After picking a non-binge show episode for peek continuity, mark that
            // show as "just heard" so subsequent peek slots rotate fairly.
            working = Self.touchLastHeard(feedURL: picked.feedURL, in: working, at: Date())
            if picked.isBinge {
                // Stay in binge for subsequent peek slots.
            } else {
                bingeURL = nil
            }
        }
        return results
    }

    /// Feed URL to treat as active binge after playing `item` (nil if non-binge).
    static func activeBingeURL(afterPlaying item: ComingUpItem) -> URL? {
        item.isBinge ? item.feedURL : nil
    }

    // MARK: - Helpers

    private static func item(episode: SmartOrderEpisode, show: SmartOrderShow) -> ComingUpItem {
        ComingUpItem(
            episodeID: episode.id,
            episodeTitle: episode.title,
            podcastTitle: show.title,
            feedURL: show.feedURL,
            isBinge: show.isBinge
        )
    }

    private static func markDismissed(episodeID: String, in shows: [SmartOrderShow]) -> [SmartOrderShow] {
        shows.map { show in
            var copy = show
            copy = SmartOrderShow(
                feedURL: show.feedURL,
                title: show.title,
                isBinge: show.isBinge,
                lastHeardAt: show.lastHeardAt,
                episodes: show.episodes.map { ep in
                    guard ep.id == episodeID else { return ep }
                    return SmartOrderEpisode(
                        id: ep.id,
                        title: ep.title,
                        pubDate: ep.pubDate,
                        isPlayed: ep.isPlayed,
                        playbackPosition: ep.playbackPosition,
                        dismissedFromAutoplay: true
                    )
                }
            )
            return copy
        }
    }

    private static func touchLastHeard(
        feedURL: URL,
        in shows: [SmartOrderShow],
        at date: Date
    ) -> [SmartOrderShow] {
        shows.map { show in
            guard show.feedURL == feedURL else { return show }
            return SmartOrderShow(
                feedURL: show.feedURL,
                title: show.title,
                isBinge: show.isBinge,
                lastHeardAt: date,
                episodes: show.episodes
            )
        }
    }
}
