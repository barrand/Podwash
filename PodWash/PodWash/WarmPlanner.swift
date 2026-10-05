//
//  WarmPlanner.swift
//  PodWash
//
//  Shared explicit preparation and the automatic next-two readiness window.
//

import Foundation
import Observation

/// The single-worker coordinator for explicit, replay, and automatic preparation.
@MainActor
@Observable final class WarmPlanner {
    private enum PreparationRequestKind: Equatable {
        case replay
        case explicit
        case automatic
    }

    private struct PreparationRequest {
        let item: ComingUpItem
        let kind: PreparationRequestKind
    }

    var onJobsChanged: (() -> Void)?
    /// The current automatic preparation window, not a lifetime download cap.
    static let peekCount = UpcomingSelectionPolicy.readyTarget

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
    private var ownerRequests: [PreparationRequest] = []
    private struct Requirements: Equatable {
        let targets: Set<String>
        let cleaning: Bool
        let cloud: Bool
        let unrelated: Bool
        let preset: SkipPreset
    }
    private var activeRequirements: [String: Requirements] = [:]
    private var retryTasks: [String: Task<Void, Never>] = [:]
    /// Durable explicit requests are independent from Queue membership and retire
    /// only after verified readiness or an explicit terminating action.
    private var explicitEpisodeIDs: Set<String>
    private var workerTask: Task<Void, Never>?
    private(set) var warmingEpisodeIDs: Set<String> = []
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
        reaim(requests: Array((settingsStore.autoDownloadEnabled ? items : []).prefix(Self.peekCount)).map {
            PreparationRequest(item: $0, kind: .automatic)
        })
    }

    private func reaim(requests: [PreparationRequest]) {
        for id in explicitEpisodeIDs where podcastStore.episodeLookup(id: id) == nil {
            explicitEpisodeIDs.remove(id)
            preferencesStore.removeExplicit(id)
        }
        ownerRequests = requests
        let windowIDs = Set(requests.filter { $0.kind == .automatic }.map { $0.item.episodeID })
        for id in preferencesStore.preferences.automaticallySuppressedEpisodeIDs.subtracting(windowIDs) {
            preferencesStore.clearSuppression(id)
        }
        rebuildWorker()
    }

    private func rebuildWorker(force: Bool = false) {
        let requests = ownerRequests
        let explicit = explicitEpisodeIDs.sorted().compactMap { id -> PreparationRequest? in
            guard let lookup = podcastStore.episodeLookup(id: id) else { return nil }
            return PreparationRequest(
                item: ComingUpItem(
                    episodeID: id,
                    episodeTitle: lookup.episode.title,
                    podcastTitle: lookup.podcastTitle,
                    feedURL: lookup.feedURL,
                    isBinge: podcastStore.isBinge(feedURL: lookup.feedURL)
                ),
                kind: .explicit
            )
        }
        var seen = Set<String>()
        let automatic = requests.filter {
            $0.kind == .automatic
                && !preferencesStore.preferences.automaticallySuppressedEpisodeIDs.contains($0.item.episodeID)
        }
        let effectiveRequests = (requests.filter { $0.kind != .automatic } + explicit + automatic)
            .filter { seen.insert($0.item.episodeID).inserted }
        let effectiveIDs = Set(effectiveRequests.map { $0.item.episodeID })
        let requirements = Dictionary(uniqueKeysWithValues: effectiveRequests.map { request in
            (request.item.episodeID, Requirements(targets: settingsStore.activeNormalizedTargetSet(),
                cleaning: cleaningStore.isChannelCleaningEnabled(forFeedURL: request.item.feedURL),
                cloud: settingsStore.canUseCloudTranscriptProcessing,
                unrelated: settingsStore.unrelatedContentEnabled
                    && cleaningStore.isChannelUnrelatedContentEnabled(forFeedURL: request.item.feedURL),
                preset: settingsStore.skipPreset))
        })
        let changedRequirements = Set(requirements.compactMap { id, value in
            activeRequirements[id].map { $0 != value } == true ? id : nil
        })
        activeRequirements = requirements
        for id in changedRequirements {
            guard var job = jobs[id], job.cloudFailure != nil else { continue }
            retryTasks.removeValue(forKey: id)?.cancel()
            job.stage = .queued
            job.retryAfter = nil
            job.cloudFailure = nil
            job.detail = nil
            job.failureReason = nil
            jobs[id] = job
        }
        for id in Array(retryTasks.keys) where !effectiveIDs.contains(id) {
            retryTasks.removeValue(forKey: id)?.cancel()
        }
        let previousJobs = jobs
        for id in Array(jobs.keys) where !effectiveIDs.contains(id) {
            guard let job = jobs[id], [.queued, .downloading, .transcribing, .checkingAds].contains(job.stage) else { continue }
            jobs.removeValue(forKey: id)
        }
        if jobs != previousJobs {
            jobStore.save(jobs)
            onJobsChanged?()
        }
        let requestIDs = effectiveRequests.map {
            $0.kind == .replay ? "replay-\($0.item.episodeID)" : $0.item.episodeID
        }
        // Refresh events routinely deliver the same selection. Keep useful
        // work alive rather than cancelling and restarting it.
        guard force || requestIDs != activeRequestIDs || !changedRequirements.isEmpty else { return }
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
                if let job = self.jobs[request.item.episodeID] {
                    if job.stage == .needsAttention { continue }
                    if let deadline = job.retryAfter, deadline > Date() {
                        self.scheduleRetry(request.item, generation: generation,
                            delay: deadline.timeIntervalSinceNow, kind: request.kind)
                        continue
                    }
                }
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
        currentEpisodeID: String? = nil,
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
        let selection = UpcomingSelectionPolicy().preparationWindow(
            currentEpisodeID: currentEpisodeID,
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
        let ordered = (replay.map { [$0] } ?? []) + selection.compactMap { id -> PreparationRequest? in
            guard let item = byID[id] else { return nil }
            return PreparationRequest(item: item, kind: .automatic)
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
        let generation = warmGeneration
        await previousTask?.value
        guard generation == warmGeneration else { return }
        workerTask = nil
        activeRequestIDs = []
        warmingEpisodeIDs.removeAll()
    }

    func cancel() {
        warmGeneration += 1
        workerTask?.cancel()
        // Retain the cancelled task so a replacement can await late writes.
        activeRequestIDs = []
        warmingEpisodeIDs.removeAll()
        for task in retryTasks.values { task.cancel() }
        retryTasks.removeAll()
    }

    /// Re-check prepared episodes when a local projection setting changes.
    /// AnalysisPipeline reuses the typed artifact, so this performs no network
    /// or transcription work when the prior Jev result is available.
    func refreshForSettingsChange() {
        rebuildWorker(force: true)
    }

    func job(for episodeID: String) -> AnalysisJob? { jobs[episodeID] }

    func hasExplicitPreparation(episodeID: String) -> Bool { explicitEpisodeIDs.contains(episodeID) }

    func hasAutomaticPreparation(episodeID: String) -> Bool {
        ownerRequests.contains { $0.kind == .automatic && $0.item.episodeID == episodeID }
            && !preferencesStore.preferences.automaticallySuppressedEpisodeIDs.contains(episodeID)
    }

    var ownedEpisodeIDs: Set<String> {
        explicitEpisodeIDs.union(ownerRequests.compactMap {
            $0.kind != .automatic || !preferencesStore.preferences.automaticallySuppressedEpisodeIDs.contains($0.item.episodeID)
                ? $0.item.episodeID : nil
        })
    }

    var allJobs: [AnalysisJob] { jobs.values.sorted { $0.updatedAt > $1.updatedAt } }

    func removeJob(episodeID: String) {
        retryTasks.removeValue(forKey: episodeID)?.cancel()
        jobs.removeValue(forKey: episodeID)
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
        rebuildWorker()
    }

    func cancelExplicitPreparation(episodeID: String) {
        explicitEpisodeIDs.remove(episodeID)
        preferencesStore.removeExplicit(episodeID)
        if !ownerRequests.contains(where: { $0.item.episodeID == episodeID }) {
            removeJob(episodeID: episodeID)
        }
        rebuildWorker()
    }

    func suppressAutomaticPreparation(episodeID: String) {
        preferencesStore.suppressAutomatic(episodeID)
        rebuildWorker()
    }

    func retireEpisode(episodeID: String) {
        explicitEpisodeIDs.remove(episodeID)
        preferencesStore.removeExplicit(episodeID)
        preferencesStore.clearSuppression(episodeID)
        ownerRequests.removeAll { $0.item.episodeID == episodeID }
        removeJob(episodeID: episodeID)
        rebuildWorker()
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
                if requestedEpisodeIDs.contains(episodeID) || explicitEpisodeIDs.contains(episodeID) {
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
                job.failureReason = nil
                jobs[episodeID] = job
                changed = true
            } else if job.stage != .ready, job.stage != .needsAttention, job.stage != .adCheckDelayed {
                if explicitEpisodeIDs.contains(episodeID) || requestedEpisodeIDs.contains(episodeID) {
                    job.stage = .queued
                    jobs[episodeID] = job
                } else {
                    jobs.removeValue(forKey: episodeID)
                }
                changed = true
            }
        }
        guard changed else { return }
        jobStore.save(jobs)
        onJobsChanged?()
        rebuildWorker(force: true)
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
        job.failureReason = nil
        job.retryCount = 0
        jobs[episodeID] = job
        jobStore.save(jobs)
        onJobsChanged?()
        retryTasks.removeValue(forKey: episodeID)?.cancel()
        rebuildWorker(force: true)
    }

    /// True when cleaning is off for the channel, or interval cache already has a hit.
    func isAnalysisReady(episodeID: String, feedURL: URL) -> Bool {
        let cleaningOn = cleaningStore.isChannelCleaningEnabled(forFeedURL: feedURL)
        if !cleaningOn { return true }
        let targets = settingsStore.activeNormalizedTargetSet()
        // Cloud-off is a supported local-clean mode. A partial cache record proves
        // local transcription/profanity analysis completed even though no ad result
        // should be required for automatic playback.
        if !settingsStore.canUseCloudTranscriptProcessing
            || !settingsStore.unrelatedContentEnabled
            || !cleaningStore.isChannelUnrelatedContentEnabled(forFeedURL: feedURL) {
            return intervalCache.loadRecord(
                episodeID: episodeID,
                targetWords: targets,
                preset: settingsStore.skipPreset
            ) != nil
        }
        return intervalCache.isAnalysisCompleted(
            episodeID: episodeID,
            targetWords: targets,
            preset: settingsStore.skipPreset
        )
    }

    func isLocallyDownloaded(episodeID: String) -> Bool {
        downloadManager.verifiedLocalFileURL(for: episodeID) != nil
    }

    func isReadyForSeamlessPlay(episodeID: String, feedURL: URL) -> Bool {
        let cleaningOn = cleaningStore.isChannelCleaningEnabled(forFeedURL: feedURL)
        if !cleaningOn { return true }
        return isLocallyDownloaded(episodeID: episodeID)
            && isAnalysisReady(episodeID: episodeID, feedURL: feedURL)
    }

    /// Listener-visible readiness always requires installed local audio.
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
        let isReplay = kind == .replay
        guard let lookup = podcastStore.episodeLookup(id: item.episodeID) else { return }
        if isReplay, jobs[item.episodeID]?.stage == .ready,
           isReadyOffline(episodeID: item.episodeID, feedURL: item.feedURL) { return }

        let cleaningOn = cleaningStore.isChannelCleaningEnabled(forFeedURL: item.feedURL)
        if !isReplay,
           isAnalysisReady(episodeID: item.episodeID, feedURL: item.feedURL),
           isLocallyDownloaded(episodeID: item.episodeID) {
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
                    updateJob(item, stage: .needsAttention, detail: "No downloadable audio",
                              failureReason: .noDownloadableAudio, generation: generation)
                    return
                }
                // A newly fetched enclosure must never inherit timestamps from
                // the previous audio. Keep transcript/artifact history until a
                // successful fresh analysis replaces it; retire derived playback
                // schedules before the new file can become visible.
                try intervalCache.remove(episodeID: item.episodeID)
                updateJob(item, stage: .downloading, estimate: AnalysisJobEstimate(secondsRemaining: nil, progress: 0), generation: generation)
                localURL = try await downloadManager.download(
                    episodeID: item.episodeID,
                    from: remote
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
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

            if isReplay || (cleaningOn && !isAnalysisReady(episodeID: item.episodeID, feedURL: item.feedURL)) {
                updateJob(item, stage: .transcribing, generation: generation)
                let targets = settingsStore.activeNormalizedTargetSet()
                let unrelated = UnrelatedContentOptions(
                    enabled: settingsStore.unrelatedContentEnabled
                        && cleaningStore.isChannelUnrelatedContentEnabled(forFeedURL: item.feedURL),
                    action: settingsStore.unrelatedCensorAction(),
                    preset: settingsStore.skipPreset
                )
                let removeCloudObserver: () -> Void
                if let pipeline = SerialEpisodeAnalyzer.pipeline(for: analyzer) {
                    let observerID = pipeline.addCloudAdDetectionObserver(started: { [weak self] in
                        Task { @MainActor [weak self] in
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
                // Jev result must remain incomplete rather than being overwritten as ready.
                if SerialEpisodeAnalyzer.pipeline(for: analyzer) == nil {
                    try intervalCache.store(
                        intervals,
                        episodeID: item.episodeID,
                        targetWords: targets,
                        preset: settingsStore.skipPreset
                    )
                }
            }
            guard generation == warmGeneration, !Task.isCancelled else { return }
            guard isLocallyDownloaded(episodeID: item.episodeID) else {
                updateJob(item, stage: .needsAttention, detail: "Download failed",
                          failureReason: .downloadFailed, generation: generation)
                return
            }
            guard isAnalysisReady(episodeID: item.episodeID, feedURL: item.feedURL) else {
                let category: CloudAdDetectionFailureCategory?
                if let pipeline = SerialEpisodeAnalyzer.pipeline(for: analyzer),
                   case let .failed(value)? = pipeline.lastCloudAdDetectionOutcome {
                    category = value
                } else {
                    category = nil
                }
                guard let category else {
                    updateJob(item, stage: .needsAttention, detail: "Local preparation failed",
                              failureReason: .localPreparationFailed, generation: generation)
                    return
                }
                if !Self.isRetryable(category) {
                    updateJob(
                        item,
                        stage: .needsAttention,
                        detail: Self.listenerDetail(for: category),
                        cloudFailure: category,
                        failureReason: .cloud(category),
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
            updateJob(item, stage: .ready, generation: generation)
        } catch {
            // Cancellation is a resumable interruption. It is not a failed ad
            // check and must never immediately start a second analyzer.
            guard generation == warmGeneration, !Task.isCancelled,
                  !(error is CancellationError) else { return }
            if !isLocallyDownloaded(episodeID: item.episodeID) {
                updateJob(item, stage: .needsAttention, detail: "Download failed",
                          failureReason: .downloadFailed, generation: generation)
                return
            }
            guard let pipeline = SerialEpisodeAnalyzer.pipeline(for: analyzer),
                  case let .failed(category)? = pipeline.lastCloudAdDetectionOutcome else {
                updateJob(item, stage: .needsAttention, detail: "Local preparation failed",
                          failureReason: .localPreparationFailed, generation: generation)
                return
            }
            if !Self.isRetryable(category) {
                updateJob(
                    item,
                    stage: .needsAttention,
                        detail: Self.listenerDetail(for: category),
                        cloudFailure: category,
                        failureReason: .cloud(category),
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
        retryTasks[item.episodeID]?.cancel()
        retryTasks[item.episodeID] = Task { @MainActor [weak self, timing] in
            do {
                try await timing.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.retryTasks.removeValue(forKey: item.episodeID)
            self.jobs[item.episodeID]?.retryAfter = nil
            // Retry joins the same serial worker, never starts a parallel analyzer.
            self.rebuildWorker(force: true)
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
        failureReason: PreparationFailureReason? = nil,
        retryCount: Int? = nil,
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
            failureReason: failureReason,
            retryCount: retryCount ?? jobs[item.episodeID]?.retryCount ?? 0
        )
        jobs[item.episodeID] = job
        if stage == .ready {
            explicitEpisodeIDs.remove(item.episodeID)
            preferencesStore.removeExplicit(item.episodeID)
        }
        // Keep only recovery checkpoints; high-frequency download updates are useful in
        // the row but need not churn persistent storage.
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
