//
//  WarmPlanner.swift
//  PodWash
//
//  ADR-029 — Pre-warm next 2–3 autoplay episodes (download + analyze), cap 5.
//

import Foundation
import Observation

enum ImmediatePreparationOutcome: Equatable {
    case ready
    case retrying
    case needsAttention
    case cancelled
}

/// The single-worker preparation coordinator. It keeps the old `WarmPlanner` name
/// for source compatibility with ADR-029 tests, while exposing durable user-facing jobs.
@MainActor
@Observable final class WarmPlanner {
    private enum PreparationRequestKind: Equatable {
        case replay
        case manualQueue
        case automatic

        var isUserRequested: Bool { self != .automatic }
    }

    private struct PreparationRequest {
        let item: ComingUpItem
        let kind: PreparationRequestKind
    }

    var onJobsChanged: (() -> Void)?
    /// Keep the selected next episode plus multiple likely follow-ons warm.
    static let peekCount = UpcomingSelectionPolicy.readyTarget
    static let warmCap = UpcomingSelectionPolicy.readyTarget

    private let downloadManager: DownloadManager
    private let analyzer: any EpisodeAnalyzing
    private let settingsStore: SettingsStore
    private let intervalCache: IntervalCache
    private let cleaningStore: CleaningToggleStore
    private let podcastStore: PodcastStore
    private let jobStore: AnalysisJobStore
    private let preferencesStore: EpisodePreparationPreferencesStore
    private let timing: any AppTiming

    private var warmGeneration = 0
    private var activeRequestIDs: [String] = []
    /// Explicit row requests are independent from Up Next membership. They are
    /// retained for this planner lifetime; persistence/reconciliation is owned
    /// by the shell's durable intent store in a later migration.
    private var explicitEpisodeIDs: Set<String>
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
        jobStore: AnalysisJobStore = AnalysisJobStore(),
        preferencesStore: EpisodePreparationPreferencesStore = EpisodePreparationPreferencesStore(),
        timing: any AppTiming = SystemAppTiming()
    ) {
        self.downloadManager = downloadManager
        self.analyzer = analyzer
        self.settingsStore = settingsStore
        self.intervalCache = intervalCache
        self.cleaningStore = cleaningStore
        self.podcastStore = podcastStore
        self.jobStore = jobStore
        self.preferencesStore = preferencesStore
        self.timing = timing
        self.jobs = jobStore.load()
        self.explicitEpisodeIDs = preferencesStore.preferences.explicitEpisodeIDs
    }

    nonisolated deinit {}

    /// Cancel in-flight warm work and start warming `items` (up to peek / cap).
    func reaim(at items: [ComingUpItem]) {
        reaim(requests: Array(items.prefix(Self.peekCount)).map {
            PreparationRequest(item: $0, kind: .automatic)
        })
    }

    private func reaim(requests: [PreparationRequest]) {
        let explicit = explicitEpisodeIDs.compactMap { id -> PreparationRequest? in
            guard let lookup = podcastStore.episodeLookup(id: id) else { return nil }
            return PreparationRequest(
                item: ComingUpItem(
                    episodeID: id,
                    episodeTitle: lookup.episode.title,
                    podcastTitle: lookup.podcastTitle,
                    feedURL: lookup.feedURL,
                    isBinge: podcastStore.isBinge(feedURL: lookup.feedURL)
                ),
                kind: .manualQueue
            )
        }
        var seen = Set<String>()
        let automatic = requests.filter {
            $0.kind == .automatic
                && !preferencesStore.preferences.automaticallySuppressedEpisodeIDs.contains($0.item.episodeID)
        }
        let effectiveRequests = (requests.filter { $0.kind != .automatic } + explicit + automatic)
            .filter { seen.insert($0.item.episodeID).inserted }
        let requestIDs = effectiveRequests.map { "\($0.kind)-\($0.item.episodeID)" }
        // Refresh events routinely deliver the same selection. Keep useful
        // work alive rather than cancelling and restarting it.
        guard requestIDs != activeRequestIDs else { return }
        activeRequestIDs = requestIDs
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
            for request in effectiveRequests {
                guard generation == self.warmGeneration, !Task.isCancelled else { return }
                await self.warmOne(
                    request.item,
                    generation: generation,
                    kind: request.kind
                )
            }
        }
    }

    /// Manual Up Next is always prepared before predictions. Duplicates retain the
    /// listener-visible manual ordering and the worker remains deliberately serial.
    func reaim(
        replayEpisodeID: String? = nil,
        manualQueueIDs: [String],
        predicted: [ComingUpItem]
    ) {
        let replay = replayEpisodeID.flatMap { id -> PreparationRequest? in
            guard let lookup = podcastStore.episodeLookup(id: id) else { return nil }
            return PreparationRequest(
                item: ComingUpItem(
                    episodeID: id,
                    episodeTitle: lookup.episode.title,
                    podcastTitle: lookup.podcastTitle,
                    feedURL: lookup.feedURL,
                    isBinge: podcastStore.isBinge(feedURL: lookup.feedURL)
                ),
                kind: .replay
            )
        }
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
        let selection = UpcomingSelectionPolicy().select(
            currentEpisodeID: replayEpisodeID,
            manualQueueIDs: manual.map(\.episodeID),
            predictions: predicted,
            automaticPreparationEnabled: settingsStore.autoDownloadEnabled
        )
        // Manual queue entries win if a prediction repeats them. The selection
        // policy removes that duplicate from work, but building this lookup must
        // also be safe before the selection is applied.
        var byID: [String: ComingUpItem] = [:]
        for item in manual + predicted where byID[item.episodeID] == nil {
            byID[item.episodeID] = item
        }
        let ordered = (replay.map { [$0] } ?? []) + selection.compactMap { selected -> PreparationRequest? in
            guard let item = byID[selected.episodeID] else { return nil }
            return PreparationRequest(item: item, kind: selected.origin == .manual ? .manualQueue : .automatic)
        }
        var seen = Set<String>()
        reaim(requests: ordered.filter { seen.insert($0.item.episodeID).inserted })
    }

    /// Stops the serial worker and waits for it to settle so callers can safely
    /// replace an episode's on-disk artifacts without late writes from old work.
    func quiesce() async {
        warmGeneration += 1
        workerTask?.cancel()
        let previousTask = workerTask
        workerTask = nil
        await previousTask?.value
        activeRequestIDs = []
        warmingEpisodeIDs.removeAll()
    }

    /// Promotes one listener-selected episode ahead of automatic warming. The
    /// caller owns any later retry wait, so a newer selection can cancel its
    /// auto-play intent without leaving an unowned playback task behind.
    func prepareImmediately(episodeID: String) async -> ImmediatePreparationOutcome {
        guard let lookup = podcastStore.episodeLookup(id: episodeID) else { return .needsAttention }
        await quiesce()
        guard !Task.isCancelled else { return .cancelled }

        let generation = warmGeneration
        activeRequestIDs = ["immediate-\(episodeID)"]
        let item = ComingUpItem(
            episodeID: episodeID,
            episodeTitle: lookup.episode.title,
            podcastTitle: lookup.podcastTitle,
            feedURL: lookup.feedURL,
            isBinge: podcastStore.isBinge(feedURL: lookup.feedURL)
        )
        await warmOne(item, generation: generation, kind: .manualQueue)
        guard generation == warmGeneration, !Task.isCancelled else { return .cancelled }
        if isReadyOffline(episodeID: episodeID, feedURL: lookup.feedURL) { return .ready }
        switch jobs[episodeID]?.stage {
        case .needsAttention: return .needsAttention
        default: return .retrying
        }
    }

    func cancel() {
        warmGeneration += 1
        workerTask?.cancel()
        workerTask = nil
        activeRequestIDs = []
        warmingEpisodeIDs.removeAll()
    }

    func job(for episodeID: String) -> AnalysisJob? { jobs[episodeID] }

    func hasExplicitPreparation(episodeID: String) -> Bool { explicitEpisodeIDs.contains(episodeID) }

    var allJobs: [AnalysisJob] { jobs.values.sorted { $0.updatedAt > $1.updatedAt } }

    func removeJob(episodeID: String) {
        jobs.removeValue(forKey: episodeID)
        warmedEpisodeIDs.remove(episodeID)
        warmingEpisodeIDs.remove(episodeID)
        jobStore.save(jobs)
        onJobsChanged?()
    }

    /// Promotes one listener-selected row without adding it to Up Next. This
    /// shares the same serial worker and is idempotent across repeated taps.
    func requestExplicitPreparation(episodeID: String) {
        guard podcastStore.episodeLookup(id: episodeID) != nil else { return }
        explicitEpisodeIDs.insert(episodeID)
        preferencesStore.addExplicit(episodeID)
        reaim(requests: [])
    }

    func cancelExplicitPreparation(episodeID: String) {
        explicitEpisodeIDs.remove(episodeID)
        preferencesStore.removeExplicit(episodeID)
        removeJob(episodeID: episodeID)
        reaim(requests: [])
    }

    func suppressAutomaticPreparation(episodeID: String) {
        preferencesStore.suppressAutomatic(episodeID)
        reaim(requests: [])
    }

    /// Repairs durable job markers against the actual file system and analysis
    /// cache. Presentation is safe without this pass, but reconciling prevents
    /// stale ready jobs from surviving relaunch indefinitely.
    func reconcilePersistedJobs(requestedEpisodeIDs: Set<String>) {
        var changed = false
        for episodeID in Array(jobs.keys) {
            guard let lookup = podcastStore.episodeLookup(id: episodeID) else {
                jobs.removeValue(forKey: episodeID)
                changed = true
                continue
            }
            guard var job = jobs[episodeID] else { continue }
            let hasLocalFile = downloadManager.localFileURL(for: episodeID) != nil
            let analysisReady = isAnalysisReady(episodeID: episodeID, feedURL: lookup.feedURL)

            if job.stage == .ready, !hasLocalFile {
                if requestedEpisodeIDs.contains(episodeID) {
                    job.stage = .queued
                    job.updatedAt = Date()
                    jobs[episodeID] = job
                } else {
                    jobs.removeValue(forKey: episodeID)
                }
                changed = true
            } else if hasLocalFile, analysisReady, job.stage != .ready {
                job.stage = .ready
                job.estimate = AnalysisJobEstimate(secondsRemaining: nil, progress: nil)
                job.retryAfter = nil
                job.detail = nil
                jobs[episodeID] = job
                changed = true
            }
        }
        guard changed else { return }
        jobStore.save(jobs)
        onJobsChanged?()
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
        onJobsChanged?()
    }

    /// True when cleaning is off for the channel, or interval cache already has a hit.
    func isAnalysisReady(episodeID: String, feedURL: URL) -> Bool {
        let cleaningOn = cleaningStore.isChannelCleaningEnabled(forFeedURL: feedURL)
        if !cleaningOn { return true }
        let targets = settingsStore.activeNormalizedTargetSet()
        // Cloud-off is a supported local-clean mode. A partial cache record proves
        // local transcription/profanity analysis completed even though no ad result
        // should be required for automatic playback.
        if !settingsStore.canUseCloudTranscriptProcessing {
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
        kind: PreparationRequestKind = .automatic
    ) async {
        guard generation == warmGeneration, !Task.isCancelled else { return }
        let isUserRequested = kind.isUserRequested
        let isReplay = kind == .replay
        if !isUserRequested, warmedEpisodeIDs.count >= Self.warmCap,
           !warmedEpisodeIDs.contains(item.episodeID) {
            return
        }
        guard let lookup = podcastStore.episodeLookup(id: item.episodeID) else { return }

        let cleaningOn = cleaningStore.isChannelCleaningEnabled(forFeedURL: item.feedURL)
        if !isReplay,
           isAnalysisReady(episodeID: item.episodeID, feedURL: item.feedURL),
           isLocallyDownloaded(episodeID: item.episodeID) {
            warmedEpisodeIDs.insert(item.episodeID)
            updateJob(item, stage: .ready, generation: generation)
            return
        }

        warmingEpisodeIDs.insert(item.episodeID)
        defer { warmingEpisodeIDs.remove(item.episodeID) }
        updateJob(item, stage: .queued, generation: generation)

        do {
            let localURL: URL
            if let existing = downloadManager.localFileURL(for: item.episodeID) {
                localURL = existing
            } else {
                guard let remote = lookup.episode.audioURL else {
                    updateJob(item, stage: .needsAttention, detail: "No downloadable audio", generation: generation)
                    return
                }
                updateJob(item, stage: .downloading, estimate: AnalysisJobEstimate(secondsRemaining: nil, progress: 0), generation: generation)
                localURL = try await downloadManager.download(
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
            }
            guard generation == warmGeneration, !Task.isCancelled else { return }

            if isReplay || (cleaningOn && !intervalCache.isAnalysisCompleted(
                episodeID: item.episodeID,
                targetWords: settingsStore.activeNormalizedTargetSet()
            )) {
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
                scheduleRetry(item, generation: generation, delay: delay, kind: kind)
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
            // Cancellation is a resumable interruption. It is not a failed ad
            // check and must never immediately start a second analyzer.
            guard generation == warmGeneration, !Task.isCancelled,
                  !(error is CancellationError) else { return }
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
            scheduleRetry(item, generation: generation, delay: delay, kind: kind)
            PlaybackDiagnostics.error(
                "WarmPlanner failed episodeID=\(item.episodeID) error=\(error.localizedDescription)"
            )
        }
    }

    private func scheduleRetry(
        _ item: ComingUpItem,
        generation: Int,
        delay: TimeInterval,
        kind: PreparationRequestKind
    ) {
        let timing = timing
        Task { @MainActor [weak self, timing] in
            do {
                try await timing.sleep(for: delay)
            } catch {
                return
            }
            guard let self, generation == self.warmGeneration, !Task.isCancelled else { return }
            await self.warmOne(item, generation: generation, kind: kind)
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
        onJobsChanged?()
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
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
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
