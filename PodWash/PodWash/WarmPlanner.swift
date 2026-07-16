//
//  WarmPlanner.swift
//  PodWash
//
//  ADR-029 — Pre-warm next 2–3 autoplay episodes (download + analyze), cap 5.
//

import Foundation

/// Tracks which episode IDs currently count toward the warm pool.
@MainActor
final class WarmPlanner {
    static let peekCount = 3
    static let warmCap = 5

    private let downloadManager: DownloadManager
    private let analyzer: any EpisodeAnalyzing
    private let settingsStore: SettingsStore
    private let intervalCache: IntervalCache
    private let cleaningStore: CleaningToggleStore
    private let podcastStore: PodcastStore

    private var warmGeneration = 0
    private(set) var warmingEpisodeIDs: Set<String> = []
    private(set) var warmedEpisodeIDs: Set<String> = []

    init(
        downloadManager: DownloadManager,
        analyzer: any EpisodeAnalyzing,
        settingsStore: SettingsStore,
        intervalCache: IntervalCache,
        cleaningStore: CleaningToggleStore,
        podcastStore: PodcastStore
    ) {
        self.downloadManager = downloadManager
        self.analyzer = analyzer
        self.settingsStore = settingsStore
        self.intervalCache = intervalCache
        self.cleaningStore = cleaningStore
        self.podcastStore = podcastStore
    }

    nonisolated deinit {}

    /// Cancel in-flight warm work and start warming `items` (up to peek / cap).
    func reaim(at items: [ComingUpItem]) {
        warmGeneration += 1
        let generation = warmGeneration
        let limited = Array(items.prefix(Self.peekCount))
        Task { @MainActor [weak self] in
            guard let self else { return }
            for item in limited {
                guard generation == self.warmGeneration else { return }
                await self.warmOne(item, generation: generation)
            }
        }
    }

    func cancel() {
        warmGeneration += 1
        warmingEpisodeIDs.removeAll()
    }

    /// True when cleaning is off for the channel, or interval cache already has a hit.
    func isAnalysisReady(episodeID: String, feedURL: URL) -> Bool {
        let cleaningOn = cleaningStore.isChannelCleaningEnabled(forFeedURL: feedURL)
        if !cleaningOn { return true }
        let targets = settingsStore.activeNormalizedTargetSet()
        return intervalCache.load(episodeID: episodeID, targetWords: targets) != nil
    }

    func isLocallyDownloaded(episodeID: String) -> Bool {
        downloadManager.localFileURL(for: episodeID) != nil
    }

    func isReadyForSeamlessPlay(episodeID: String, feedURL: URL) -> Bool {
        let cleaningOn = cleaningStore.isChannelCleaningEnabled(forFeedURL: feedURL)
        if !cleaningOn { return true }
        return isLocallyDownloaded(episodeID: episodeID)
            && isAnalysisReady(episodeID: episodeID, feedURL: feedURL)
    }

    private func warmOne(_ item: ComingUpItem, generation: Int) async {
        guard generation == warmGeneration else { return }
        if warmedEpisodeIDs.count >= Self.warmCap,
           !warmedEpisodeIDs.contains(item.episodeID) {
            return
        }
        guard let lookup = podcastStore.episodeLookup(id: item.episodeID) else { return }

        let cleaningOn = cleaningStore.isChannelCleaningEnabled(forFeedURL: item.feedURL)
        if !cleaningOn {
            warmedEpisodeIDs.insert(item.episodeID)
            return
        }

        if isAnalysisReady(episodeID: item.episodeID, feedURL: item.feedURL),
           isLocallyDownloaded(episodeID: item.episodeID) {
            warmedEpisodeIDs.insert(item.episodeID)
            return
        }

        warmingEpisodeIDs.insert(item.episodeID)
        defer { warmingEpisodeIDs.remove(item.episodeID) }

        guard let remote = lookup.episode.audioURL else { return }
        do {
            let localURL = try await downloadManager.download(
                episodeID: item.episodeID,
                from: remote
            ) { _ in }
            guard generation == warmGeneration else { return }

            if intervalCache.load(
                episodeID: item.episodeID,
                targetWords: settingsStore.activeNormalizedTargetSet()
            ) == nil {
                let targets = settingsStore.activeNormalizedTargetSet()
                let unrelated = UnrelatedContentOptions(
                    enabled: settingsStore.unrelatedContentEnabled
                        && cleaningStore.isChannelUnrelatedContentEnabled(forFeedURL: item.feedURL),
                    action: settingsStore.unrelatedCensorAction()
                )
                let intervals = try await Self.analyzeWithOneRetry(
                    analyzer: analyzer,
                    episodeID: item.episodeID,
                    audioURL: localURL,
                    targetWords: targets,
                    profanityAction: settingsStore.censorAction(),
                    unrelatedContent: unrelated
                )
                try intervalCache.store(
                    intervals,
                    episodeID: item.episodeID,
                    targetWords: targets
                )
            }
            guard generation == warmGeneration else { return }
            if warmedEpisodeIDs.count < Self.warmCap
                || warmedEpisodeIDs.contains(item.episodeID) {
                warmedEpisodeIDs.insert(item.episodeID)
            }
            while warmedEpisodeIDs.count > Self.warmCap {
                if let victim = warmedEpisodeIDs.first(where: { $0 != item.episodeID }) {
                    warmedEpisodeIDs.remove(victim)
                } else {
                    break
                }
            }
        } catch {
            PlaybackDiagnostics.error(
                "WarmPlanner failed episodeID=\(item.episodeID) error=\(error.localizedDescription)"
            )
        }
    }

    /// ADR-029: retry analysis once, then surface failure to caller.
    private static func analyzeWithOneRetry(
        analyzer: any EpisodeAnalyzing,
        episodeID: String,
        audioURL: URL,
        targetWords: Set<String>,
        profanityAction: CensorAction,
        unrelatedContent: UnrelatedContentOptions
    ) async throws -> [CensorInterval] {
        do {
            return try await analyzer.analyze(
                episode: EpisodeIdentity(id: episodeID),
                audioURL: audioURL,
                targetWords: targetWords,
                injectedTranscript: nil,
                profanityAction: profanityAction,
                unrelatedContent: unrelatedContent
            )
        } catch {
            return try await analyzer.analyze(
                episode: EpisodeIdentity(id: episodeID),
                audioURL: audioURL,
                targetWords: targetWords,
                injectedTranscript: nil,
                profanityAction: profanityAction,
                unrelatedContent: unrelatedContent
            )
        }
    }
}
