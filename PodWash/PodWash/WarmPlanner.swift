//
//  WarmPlanner.swift
//  PodWash
//
//  ADR-029 — Pre-warm next 2–3 autoplay episodes (download + analyze), cap 5.
//

import Foundation
import Observation

/// The single-worker preparation coordinator. It keeps the old `WarmPlanner` name
/// for source compatibility with ADR-029 tests, while exposing durable user-facing jobs.
@MainActor
@Observable final class WarmPlanner {
    /// Keep the selected next episode plus multiple likely follow-ons warm.
    static let peekCount = 4
    static let warmCap = 5

    private let downloadManager: DownloadManager
    private let analyzer: any EpisodeAnalyzing
    private let settingsStore: SettingsStore
    private let intervalCache: IntervalCache
    private let cleaningStore: CleaningToggleStore
    private let podcastStore: PodcastStore
    private let jobStore: AnalysisJobStore

    private var warmGeneration = 0
    private var workerTask: Task<Void, Never>?
    private(set) var warmingEpisodeIDs: Set<String> = []
    private(set) var warmedEpisodeIDs: Set<String> = []
    private(set) var jobs: [String: AnalysisJob]

    init(
        downloadManager: DownloadManager,
        analyzer: any EpisodeAnalyzing,
        settingsStore: SettingsStore,
        intervalCache: IntervalCache,
        cleaningStore: CleaningToggleStore,
        podcastStore: PodcastStore,
        jobStore: AnalysisJobStore = AnalysisJobStore()
    ) {
        self.downloadManager = downloadManager
        self.analyzer = analyzer
        self.settingsStore = settingsStore
        self.intervalCache = intervalCache
        self.cleaningStore = cleaningStore
        self.podcastStore = podcastStore
        self.jobStore = jobStore
        self.jobs = jobStore.load()
    }

    nonisolated deinit {}

    /// Cancel in-flight warm work and start warming `items` (up to peek / cap).
    func reaim(at items: [ComingUpItem]) {
        reaim(items: Array(items.prefix(Self.peekCount)), manualEpisodeIDs: [])
    }

    private func reaim(items: [ComingUpItem], manualEpisodeIDs: Set<String>) {
        warmGeneration += 1
        let generation = warmGeneration
        workerTask?.cancel()
        let previousTask = workerTask
        workerTask = Task { @MainActor [weak self, previousTask] in
            // Cancellation alone cannot stop every URLSession/ASR implementation.
            // Await the old worker before beginning a replacement so jobs remain
            // genuinely serial even when an adapter observes cancellation late.
            await previousTask?.value
            guard let self else { return }
            for item in items {
                guard generation == self.warmGeneration, !Task.isCancelled else { return }
                await self.warmOne(
                    item,
                    generation: generation,
                    isUserRequested: manualEpisodeIDs.contains(item.episodeID)
                )
            }
        }
    }

    /// Manual Up Next is always prepared before predictions. Duplicates retain the
    /// listener-visible manual ordering and the worker remains deliberately serial.
    func reaim(manualQueueIDs: [String], predicted: [ComingUpItem]) {
        let manual = manualQueueIDs.compactMap { id -> ComingUpItem? in
            guard let lookup = podcastStore.episodeLookup(id: id) else { return nil }
            return ComingUpItem(
                episodeID: id,
                episodeTitle: lookup.episode.title,
                podcastTitle: lookup.podcastTitle,
                feedURL: lookup.feedURL,
                isBinge: podcastStore.isBinge(feedURL: lookup.feedURL)
            )
        }
        var seen = Set<String>()
        let automatic = predicted.filter { !manualQueueIDs.contains($0.episodeID) }
        let ordered = manual + Array(automatic.prefix(Self.peekCount))
        reaim(items: ordered, manualEpisodeIDs: Set(manualQueueIDs))
    }

    func cancel() {
        warmGeneration += 1
        workerTask?.cancel()
        workerTask = nil
        warmingEpisodeIDs.removeAll()
    }

    func job(for episodeID: String) -> AnalysisJob? { jobs[episodeID] }

    var allJobs: [AnalysisJob] { jobs.values.sorted { $0.updatedAt > $1.updatedAt } }

    func removeJob(episodeID: String) {
        jobs.removeValue(forKey: episodeID)
        warmedEpisodeIDs.remove(episodeID)
        warmingEpisodeIDs.remove(episodeID)
        jobStore.save(jobs)
    }

    /// A listener-initiated retry must immediately retire stale failure copy while
    /// the serial worker is being re-aimed. The next attempt owns all subsequent
    /// progress and terminal state.
    func resetJobForRetry(episodeID: String) {
        guard var job = jobs[episodeID] else { return }
        job.stage = .queued
        job.estimate = AnalysisJobEstimate(secondsRemaining: nil, progress: nil)
        job.updatedAt = Date()
        job.retryAfter = nil
        job.detail = nil
        job.cloudFailure = nil
        job.retryCount = 0
        jobs[episodeID] = job
        jobStore.save(jobs)
    }

    /// True when cleaning is off for the channel, or interval cache already has a hit.
    func isAnalysisReady(episodeID: String, feedURL: URL) -> Bool {
        let cleaningOn = cleaningStore.isChannelCleaningEnabled(forFeedURL: feedURL)
        if !cleaningOn { return true }
        let targets = settingsStore.activeNormalizedTargetSet()
        // Cloud-off is a supported local-clean mode. A partial cache record proves
        // local transcription/profanity analysis completed even though no ad result
        // should be required for automatic playback.
        if !settingsStore.cloudTranscriptProcessingEnabled {
            return intervalCache.loadRecord(episodeID: episodeID, targetWords: targets) != nil
        }
        return intervalCache.isAnalysisCompleted(episodeID: episodeID, targetWords: targets)
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

    /// Listener-visible Ready to Play always means the episode is available offline.
    func isReadyOffline(episodeID: String, feedURL: URL) -> Bool {
        isLocallyDownloaded(episodeID: episodeID)
            && isAnalysisReady(episodeID: episodeID, feedURL: feedURL)
    }

    private func warmOne(
        _ item: ComingUpItem,
        generation: Int,
        isUserRequested: Bool = false
    ) async {
        guard generation == warmGeneration, !Task.isCancelled else { return }
        if !isUserRequested, warmedEpisodeIDs.count >= Self.warmCap,
           !warmedEpisodeIDs.contains(item.episodeID) {
            return
        }
        guard let lookup = podcastStore.episodeLookup(id: item.episodeID) else { return }

        let cleaningOn = cleaningStore.isChannelCleaningEnabled(forFeedURL: item.feedURL)
        if !cleaningOn {
            warmedEpisodeIDs.insert(item.episodeID)
            updateJob(item, stage: .ready, detail: "Cleaning is off", generation: generation)
            return
        }

        if isAnalysisReady(episodeID: item.episodeID, feedURL: item.feedURL),
           isLocallyDownloaded(episodeID: item.episodeID) {
            warmedEpisodeIDs.insert(item.episodeID)
            updateJob(item, stage: .ready, generation: generation)
            return
        }

        warmingEpisodeIDs.insert(item.episodeID)
        defer { warmingEpisodeIDs.remove(item.episodeID) }
        updateJob(item, stage: .queued, generation: generation)

        guard let remote = lookup.episode.audioURL else {
            updateJob(item, stage: .needsAttention, detail: "No downloadable audio", generation: generation)
            return
        }
        do {
            updateJob(item, stage: .downloading, estimate: AnalysisJobEstimate(secondsRemaining: nil, progress: 0), generation: generation)
            let localURL = try await downloadManager.download(
                episodeID: item.episodeID,
                from: remote
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.updateJob(
                        item,
                        stage: .downloading,
                        estimate: AnalysisJobEstimate(secondsRemaining: nil, progress: progress),
                        generation: generation
                    )
                }
            }
            guard generation == warmGeneration, !Task.isCancelled else { return }

            if !intervalCache.isAnalysisCompleted(
                episodeID: item.episodeID,
                targetWords: settingsStore.activeNormalizedTargetSet()
            ) {
                updateJob(item, stage: .transcribing, generation: generation)
                let targets = settingsStore.activeNormalizedTargetSet()
                let unrelated = UnrelatedContentOptions(
                    enabled: settingsStore.unrelatedContentEnabled
                        && cleaningStore.isChannelUnrelatedContentEnabled(forFeedURL: item.feedURL),
                    action: settingsStore.unrelatedCensorAction()
                )
                let removeCloudObserver: () -> Void
                if let pipeline = analyzer as? AnalysisPipeline {
                    let observerID = pipeline.addCloudAdDetectionObserver(started: { [weak self] in
                        Task { @MainActor in
                            guard let self else { return }
                            self.updateJob(item, stage: .checkingAds, generation: generation)
                        }
                    }, finished: { _ in })
                    removeCloudObserver = { pipeline.removeCloudAdDetectionObserver(observerID) }
                } else {
                    removeCloudObserver = {}
                }
                defer { removeCloudObserver() }
                let intervals = try await Self.analyzeWithOneRetry(
                    analyzer: analyzer,
                    episodeID: item.episodeID,
                    audioURL: localURL,
                    targetWords: targets,
                    profanityAction: settingsStore.censorAction(),
                    unrelatedContent: unrelated
                )
                // Production AnalysisPipeline owns completion semantics: an unavailable
                // Gemini result must remain incomplete rather than being overwritten as ready.
                if !(analyzer is AnalysisPipeline) {
                    try intervalCache.store(intervals, episodeID: item.episodeID, targetWords: targets)
                }
            }
            guard generation == warmGeneration, !Task.isCancelled else { return }
            guard isAnalysisReady(episodeID: item.episodeID, feedURL: item.feedURL) else {
                let category: CloudAdDetectionFailureCategory?
                if let pipeline = analyzer as? AnalysisPipeline,
                   case let .failed(value)? = pipeline.lastCloudAdDetectionOutcome {
                    category = value
                } else {
                    category = nil
                }
                if let category, !Self.isRetryable(category) {
                    updateJob(
                        item,
                        stage: .needsAttention,
                        detail: Self.listenerDetail(for: category),
                        cloudFailure: category,
                        retryCount: jobs[item.episodeID]?.retryCount ?? 0,
                        generation: generation
                    )
                    return
                }
                let retryCount = (jobs[item.episodeID]?.retryCount ?? 0) + 1
                let delay = Self.retryDelay(for: retryCount)
                updateJob(
                    item,
                    stage: .adCheckDelayed,
                    detail: "Retrying automatically",
                    retryAfter: Date().addingTimeInterval(delay),
                    cloudFailure: category,
                    retryCount: retryCount,
                    generation: generation
                )
                scheduleRetry(item, generation: generation, delay: delay)
                return
            }
            if isUserRequested || warmedEpisodeIDs.count < Self.warmCap
                || warmedEpisodeIDs.contains(item.episodeID) {
                warmedEpisodeIDs.insert(item.episodeID)
            }
            while !isUserRequested && warmedEpisodeIDs.count > Self.warmCap {
                if let victim = warmedEpisodeIDs.first(where: { $0 != item.episodeID }) {
                    warmedEpisodeIDs.remove(victim)
                } else {
                    break
                }
            }
            updateJob(item, stage: .ready, generation: generation)
        } catch {
            guard generation == warmGeneration, !Task.isCancelled else { return }
            let category = CloudAdDetectionFailureCategory.classify(error)
            if !Self.isRetryable(category) {
                updateJob(
                    item,
                    stage: .needsAttention,
                    detail: Self.listenerDetail(for: category),
                    cloudFailure: category,
                    retryCount: jobs[item.episodeID]?.retryCount ?? 0,
                    generation: generation
                )
                return
            }
            let retryCount = (jobs[item.episodeID]?.retryCount ?? 0) + 1
            let delay = Self.retryDelay(for: retryCount)
            updateJob(
                item,
                stage: .adCheckDelayed,
                detail: "Retrying automatically",
                retryAfter: Date().addingTimeInterval(delay),
                cloudFailure: category,
                retryCount: retryCount,
                generation: generation
            )
            scheduleRetry(item, generation: generation, delay: delay)
            PlaybackDiagnostics.error(
                "WarmPlanner failed episodeID=\(item.episodeID) error=\(error.localizedDescription)"
            )
        }
    }

    private func scheduleRetry(_ item: ComingUpItem, generation: Int, delay: TimeInterval) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, generation == self.warmGeneration else { return }
            await self.warmOne(item, generation: generation)
        }
    }

    private static func retryDelay(for retryCount: Int) -> TimeInterval {
        switch retryCount {
        case 0, 1: return 30
        case 2: return 120
        case 3: return 600
        default: return 3600
        }
    }

    private static func isRetryable(_ category: CloudAdDetectionFailureCategory) -> Bool {
        switch category {
        case .network, .rateLimited, .serviceUnavailable, .timeout: return true
        case .disabled, .configuration, .firebaseAuth, .appCheck, .credentials, .unauthorized, .invalidResponse: return false
        }
    }

    private static func listenerDetail(for category: CloudAdDetectionFailureCategory) -> String {
        switch category {
        case .disabled: return "Cloud ad checks are off"
        case .configuration, .firebaseAuth, .appCheck, .credentials, .unauthorized: return "Ad checks need attention"
        case .invalidResponse: return "Ad check returned an invalid result"
        case .network, .rateLimited, .serviceUnavailable, .timeout: return "Retrying automatically"
        }
    }

    private func updateJob(
        _ item: ComingUpItem,
        stage: AnalysisJobStage,
        estimate: AnalysisJobEstimate = AnalysisJobEstimate(secondsRemaining: nil, progress: nil),
        detail: String? = nil,
        retryAfter: Date? = nil,
        cloudFailure: CloudAdDetectionFailureCategory? = nil,
        retryCount: Int = 0,
        generation: Int? = nil
    ) {
        guard generation == nil || generation == warmGeneration else { return }
        let job = AnalysisJob(
            episodeID: item.episodeID,
            title: item.episodeTitle,
            stage: stage,
            estimate: estimate,
            updatedAt: Date(),
            retryAfter: retryAfter,
            detail: detail,
            cloudFailure: cloudFailure,
            retryCount: retryCount
        )
        jobs[item.episodeID] = job
        // Keep only recovery checkpoints; high-frequency download updates are useful in
        // the shelf but need not churn persistent storage.
        if stage != .downloading || estimate.progress == nil || estimate.progress == 1 {
            jobStore.save(jobs)
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

typealias AnalysisJobCoordinator = WarmPlanner
