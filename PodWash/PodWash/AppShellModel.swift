//
//  AppShellModel.swift
//  PodWash
//
//  Slice 23 — Production composition root + mini-player session (ADR-015 §4).
//  Slice 24 — Production analysis wiring (ADR-020 §5–§8).
//

import AVFoundation
import Foundation

struct QueueUndoSnapshot: Equatable {
    let episodeID: String
    let previousQueueIDs: [String]
    let previousPlayedState: Bool
    let previousPlaybackPosition: TimeInterval
    let marksPlayed: Bool
}

@MainActor @Observable
final class AppShellModel {
    enum AnalysisRecoveryState: Equatable {
        case notNeeded
        case refreshAvailable
        case missingArtifacts
        case inProgress
    }

    enum PlaybackReadiness: Equatable {
        case ready
        case preparing
        case failed
    }

    private struct RestoredAnalysisContext {
        let episode: Episode
        let podcastTitle: String
        let feedURL: URL?
        let audioURL: URL
    }

    /// A value-only handoff for consent-triggered downloads. Never retain a UIKit
    /// controller, IndexPath, or callback across sheet presentation/dismissal.
    private struct PendingCloudConsentDownload {
        let episodeID: String
        let remoteURL: URL
    }
    let persistence: PersistenceController
    let podcastStore: PodcastStore
    let queueStore: QueueStore
    let resumeStore: ResumePositionStore
    let nowPlayingSessionStore: NowPlayingSessionStore
    let cleaningStore: CleaningToggleStore
    let downloadManager: DownloadManager
    let settingsStore: SettingsStore
    let remoteCommands: RemoteCommandCoordinator

    /// Shared by play path and LibraryPodcastDetailView / AnalysisUIViewModel.
    private(set) var episodeAnalyzer: any EpisodeAnalyzing

    /// Multiplexes analyzer progress to shell + episode-row view models.
    private(set) var analysisProgressRelay: AnalysisProgressRelay

    /// Terminal analysis snapshot used for completed seek-bar paint.
    private(set) var playbackAnalysisSnapshot: AnalysisProgressSnapshot?

    /// Episode currently driving the mini-player session.
    private(set) var nowPlayingEpisodeID: String?

    /// The only listener-facing gate for transport and seek controls.
    private(set) var playbackReadiness: PlaybackReadiness = .ready
    var isPreparingPlayback: Bool { playbackReadiness == .preparing }

    /// Listener-facing active-work copy for the mini and full player.
    var preparationStatusText: String {
        foregroundPreparationJob?.stage.listenerStatus ?? PreparationStatusCopy.preparing
    }
    private(set) var analysisRecoveryState: AnalysisRecoveryState = .notNeeded
    private var restoredAnalysisContext: RestoredAnalysisContext?
    private var stagedRefreshIntervals: ([CensorInterval], [CensorInterval], UnrelatedContentOptions, URL)?

    private var playbackPreparationTask: Task<Void, Never>?
    private var playbackPreparationRequestID = 0

    /// Episode awaiting download-before-play (channel cleaning on, no local file).
    private var pendingDownloadForPlayEpisodeID: String?

    /// Compatibility state for the cloud-ad-detection disclosure.
    var isCloudTranscriptConsentPresented = false
    private var pendingCloudConsentEpisode: Episode?
    private var pendingCloudConsentPodcastTitle = ""
    private var pendingCloudConsentFeedURL: URL?
    private var pendingCloudConsentDownload: PendingCloudConsentDownload?

    /// Observes deferred NoCache transcript backfill so episode/full-player affordances refresh.
    /// `nonisolated(unsafe)`: removed from `nonisolated deinit` without a MainActor hop.
    private nonisolated(unsafe) var transcriptBackfillObserver: NSObjectProtocol?

    /// Test-only: forwarded to `preparePlayback` so AC4/AC5 avoid live ASR.
    var injectedTranscriptForTesting: [TimedWord]? = nil

    /// Test-only override for downloads directory (local-file gate).
    var downloadsDirectoryForTesting: URL? = nil

    /// Test-only fixture-branch override (AC8).
    /// - `nil` (production / UITest): use `FixtureLibrary.isEnabled || isEmptyEnabled`
    /// - `true`: Library fixture mode — skip `preparePlayback` regardless of cleaning
    /// - `false`: force non-fixture play path
    var fixtureLibraryModeForTesting: Bool? = nil

    /// Effective Library-fixture gate used by `playEpisode` and default analyzer choice.
    var isFixtureLibraryMode: Bool {
        fixtureLibraryModeForTesting
            ?? (FixtureLibrary.isEnabled
                || FixtureLibrary.isEmptyEnabled
                || FixtureTranscript.isAnyEnabled
                || FixtureMuteMarkers.isAnyEnabled
                || FixturePrerollAdBands.isAnyEnabled)
    }

    /// Applied playback intervals for seek-bar ad/mute paint (ADR-023 / ADR-026 / task-031).
    /// Matches `presentTranscript(for:)` precedence so transcript and player chrome
    /// never diverge on recognized ad spans.
    var nowPlayingMuteIntervals: [CensorInterval] {
        guard let episodeID = nowPlayingEpisodeID else { return [] }
        return presentationIntervals(for: episodeID)
    }

    private(set) var engine: PlaybackEngine?
    private(set) var playbackCoordinator: PlaybackCoordinator?
    private(set) var queueCoordinator: QueueCoordinator?
    /// Not observation-tracked: releasing via `@Observable` setter trips
    /// `swift_task_deinitOnExecutorImpl` on `LibraryEpisodePlayer` (Slice 31 unit teardown).
    @ObservationIgnored private var episodePlayer: LibraryEpisodePlayer?

    /// Drives mini-player visibility (true after a successful episode play start).
    private(set) var isMiniPlayerVisible: Bool = false
    /// Full controls presentation (sheet).
    var isFullPlayerPresented: Bool = false

    /// Idempotency gate for cold-start / relaunch restore (ADR-027 §5).
    private var didAttemptNowPlayingRestore = false

    /// Bumped after playback prepare when a transcript file exists — refreshes episode-row affordance.
    private(set) var transcriptAffordanceGeneration = 0

    /// Transcript sheet presentation (Slice 26). Non-nil when the sheet should show.
    var transcriptSheetEpisodeID: String? = nil
    /// View model for the open transcript sheet (built on present).
    private(set) var transcriptSheetViewModel: TranscriptViewModel?
    /// Resume / open-time playhead frozen for the presentation (ADR-028 §4).
    private(set) var transcriptSheetOpenPlaybackPosition: TimeInterval = 0

    /// Live engine for follow-along when the open transcript is the now-playing episode.
    var transcriptSheetPlaybackEngine: PlaybackEngine? {
        guard let episodeID = transcriptSheetEpisodeID,
              episodeID == nowPlayingEpisodeID
        else { return nil }
        return engine
    }

    private let transcriptCache: TranscriptCache
    private let intervalCache: IntervalCache
    private let artifactStore: EpisodeAnalysisArtifactStore

    private(set) var nowPlayingEpisodeTitle: String = "Now playing"
    private(set) var nowPlayingPodcastTitle: String = ""
    /// Feed URL for the active now-playing episode (smart order / binge).
    private(set) var nowPlayingFeedURL: URL?

    /// Active binge context for smart autoplay (ADR-029).
    private var activeBingeFeedURL: URL?

    /// Coming up peek for UI (next 2–3 smart predictions when Up Next is empty).
    private(set) var comingUpItems: [ComingUpItem] = []

    /// Explicit Observation dependency for Core Data, downloads, and WarmPlanner.
    private(set) var queuePresentationRevision = 0
    @ObservationIgnored private var downloadStateHandlerID: UUID?

    /// User-facing preparation queue (manual Up Next first, then smart predictions).
    var preparationJobs: [AnalysisJob] {
        guard let warmPlanner else { return [] }
        let manual = queueStore.queueEpisodeIDs().compactMap { warmPlanner.job(for: $0) }
        let predicted = comingUpItems.compactMap { warmPlanner.job(for: $0.episodeID) }
        var seen = Set<String>()
        let foreground = foregroundPreparationJob.map { [$0] } ?? []
        return (foreground + manual + predicted).filter { seen.insert($0.episodeID).inserted }
    }

    /// One shared snapshot powers the Queue tab and the mini-player status strip.
    var queuePresentation: QueuePresentation {
        _ = queuePresentationRevision
        let manualIDs = queueStore.queueEpisodeIDs()
        let downloadedIDs = Set(downloadManager.downloadedEpisodeIDs())
        let candidateIDs = Set(manualIDs).union(downloadedIDs)
        var metadata: [String: QueueEpisodeMetadata] = [:]
        for id in candidateIDs {
            guard let lookup = podcastStore.episodeLookup(id: id) else { continue }
            metadata[id] = QueueEpisodeMetadata(
                episodeID: id,
                title: lookup.episode.title,
                podcastTitle: lookup.podcastTitle,
                publicationDate: lookup.episode.pubDate,
                isPlayed: resumeStore.isPlayed(id)
            )
        }
        let jobs = Dictionary(uniqueKeysWithValues: (warmPlanner?.allJobs ?? []).map { ($0.episodeID, $0) })
        return QueuePresentationBuilder.build(QueuePresentationInput(
            manualQueueIDs: manualIDs,
            downloadedEpisodeIDs: downloadedIDs,
            nowPlayingEpisodeID: nowPlayingEpisodeID,
            metadataByEpisodeID: metadata,
            jobsByEpisodeID: jobs,
            foregroundJob: foregroundPreparationJob
        ))
    }
    /// The now-playing analysis uses the same listener-facing state as warm jobs.
    private(set) var foregroundPreparationJob: AnalysisJob?
    var isPreparationPresented = false

    /// True while waiting on analysis before auto-advancing (rare miss path).
    private(set) var isPreparingNextEpisode = false
    private(set) var preparingNextAnnouncement: String?

    @ObservationIgnored private var warmPlanner: WarmPlanner?
    private var didStartPreparationForCurrentSession = false

    init(
        persistence: PersistenceController,
        remoteCommands: RemoteCommandCoordinator,
        episodeAnalyzer: (any EpisodeAnalyzing)? = nil,
        settingsStore: SettingsStore? = nil,
        fixtureLibraryModeForTesting: Bool? = nil,
        downloadManager: DownloadManager? = nil,
        transcriptCache: TranscriptCache = .applicationSupport,
        intervalCache: IntervalCache = .applicationSupport,
        artifactStore: EpisodeAnalysisArtifactStore = .applicationSupport,
        analysisJobStore: AnalysisJobStore = AnalysisJobStore()
    ) {
        self.persistence = persistence
        self.remoteCommands = remoteCommands
        self.fixtureLibraryModeForTesting = fixtureLibraryModeForTesting
        self.settingsStore = settingsStore ?? SettingsStore()
        self.transcriptCache = transcriptCache
        self.intervalCache = intervalCache
        self.artifactStore = artifactStore
        let resolvedAnalyzer = episodeAnalyzer
            ?? Self.makeDefaultAnalyzer(fixtureLibraryMode: fixtureLibraryModeForTesting)
        self.episodeAnalyzer = resolvedAnalyzer
        self.analysisProgressRelay = AnalysisProgressRelay.install(on: resolvedAnalyzer)

        let context = persistence.viewContext
        podcastStore = PodcastStore(context: context, retaining: persistence)
        queueStore = QueueStore(context: context)
        resumeStore = ResumePositionStore(context: context)
        nowPlayingSessionStore = NowPlayingSessionStore(context: context)
        cleaningStore = CleaningToggleStore(context: context)
        try? cleaningStore.migrateAllChannelsCleaningAndUnrelatedOnIfNeeded()
        if let downloadManager {
            self.downloadManager = downloadManager
        } else {
            let downloadStateStore = DownloadStateStore(context: context)
            self.downloadManager = DownloadManager(
                downloadsDirectory: DownloadPaths.productionDownloadsDirectory,
                stateStore: InMemoryDownloadStateStore(backing: downloadStateStore)
            )
        }
        CarPlayDependencies.register(self)

        warmPlanner = WarmPlanner(
            downloadManager: self.downloadManager,
            analyzer: resolvedAnalyzer,
            settingsStore: self.settingsStore,
            intervalCache: intervalCache,
            cleaningStore: cleaningStore,
            podcastStore: podcastStore,
            jobStore: analysisJobStore
        )
        warmPlanner?.onJobsChanged = { [weak self] in self?.refreshQueuePresentation() }
        downloadStateHandlerID = self.downloadManager.addStateChangeHandler { [weak self] in
            self?.refreshQueuePresentation()
        }

        let knownEpisodeIDs = podcastStore.allSubscriptions().flatMap {
            podcastStore.subscription(forFeedURL: $0.feedURL)?.episodes.map(\.id) ?? []
        }
        artifactStore.migrateLegacyArtifactsIfNeeded(
            intervalCache: intervalCache,
            episodeIDs: knownEpisodeIDs
        )

        transcriptBackfillObserver = NotificationCenter.default.addObserver(
            forName: .podwashTranscriptBackfillDidStore,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.transcriptAffordanceGeneration += 1
            }
        }
    }

    /// Factory used when `episodeAnalyzer` init arg is nil (AC2 / production).
    static func makeDefaultAnalyzer(
        fixtureLibraryMode: Bool? = nil
    ) -> any EpisodeAnalyzing {
        ProductionAnalyzerFactory.makeAnalyzer(
            fixtureLibraryMode: fixtureLibraryMode
        )
    }

    // Avoid MainActor/TaskLocal deinit crash under SWIFT_DEFAULT_ACTOR_ISOLATION.
    nonisolated deinit {
        if let transcriptBackfillObserver {
            NotificationCenter.default.removeObserver(transcriptBackfillObserver)
        }
    }

    var carPlayEpisodePlayer: (any EpisodePlaying)? { self }
    var carPlayPlaybackEngine: PlaybackEngine? { engine }

    /// Player chrome no longer publishes in-flight / bucket segment colors (ADR-030).
    /// Always `nil` so AC4/AC5 can assert no `ready/processing/pending` paint path.
    var miniPlayerTimelineColors: [TimelineSegmentColor]? { nil }

    /// Full-player timeline colors — same nil contract as mini (ADR-030).
    var fullPlayerTimelineColors: [TimelineSegmentColor]? { nil }

    /// Completed analysis adds ad/mute paint; cleaning-off playback remains unannotated.
    var isPlayerSeekBarAnalysisComplete: Bool {
        guard let snapshot = playbackAnalysisSnapshot else { return false }
        return snapshot.processedEnd >= snapshot.episodeDuration
    }

    var canShowPlayerSeekBar: Bool { playbackReadiness == .ready }

    /// Episode duration for seek bar math — prefers analysis snapshot (120 s fixture) over asset.
    var superSeekDuration: Double {
        if let snapshot = playbackAnalysisSnapshot, snapshot.episodeDuration > 0 {
            return snapshot.episodeDuration
        }
        return engine?.duration ?? 0
    }

    func seekReadyPlayback(to seconds: Double) {
        applyStagedRefreshIfNeeded()
        let duration = engine?.duration ?? seconds
        engine?.seek(to: min(max(0, seconds), duration))
        // Seek-while-paused must still land in ResumePositionStore (ADR-027 flush budget).
        if engine?.isPlaying != true {
            flushPlaybackPosition()
        }
    }

    func seek(by delta: Double) {
        // Prefer the engine's observable clock — AVPlayer may still report 0/NaN while
        // the item loads, which would wipe a paused restore / pinned seek target.
        let current = engine?.currentTime ?? 0
        seekReadyPlayback(to: current + delta)
    }

    /// Library / detail entry: resolve audio, prepare engine + coordinators, show mini-player paused.
    /// Playback starts when the user taps `miniPlayerPlayPause` (AC4).
    /// Synchronous when a playable URL is already available; download-before-play defers
    /// the session until a local file exists when channel cleaning is on (task-012).
    func playEpisode(_ episode: Episode, podcastTitle: String, feedURL: URL? = nil) {
        PlaybackDiagnostics.logEpisodeTap(episodeID: episode.id, title: episode.title)

        if nowPlayingEpisodeID == episode.id, isPreparingPlayback {
            PlaybackDiagnostics.info(
                "playEpisode ignored — already preparing episodeID=\(episode.id)"
            )
            return
        }
        if pendingDownloadForPlayEpisodeID == episode.id {
            PlaybackDiagnostics.info(
                "playEpisode ignored — download-before-play in flight episodeID=\(episode.id)"
            )
            return
        }

        if shouldDownloadBeforePlay(for: episode, feedURL: feedURL) {
            guard let remoteURL = episode.audioURL else {
                PlaybackDiagnostics.error(
                    "playEpisode aborted — no audio URL for download episodeID=\(episode.id)"
                )
                downloadManager.markFailed(episodeID: episode.id)
                return
            }
            startDownloadBeforePlay(
                episode: episode,
                podcastTitle: podcastTitle,
                feedURL: feedURL,
                remoteURL: remoteURL
            )
            return
        }

        let localCandidate = resolvedLocalFileURL(for: episode.id)
        let remoteCandidate = episode.audioURL
        guard let audioURL = resolveAudioURL(for: episode) else {
            PlaybackDiagnostics.logAudioURLResolution(
                episodeID: episode.id,
                localURL: localCandidate,
                remoteURL: remoteCandidate,
                chosen: nil
            )
            PlaybackDiagnostics.error(
                "playEpisode aborted — no playable URL episodeID=\(episode.id) "
                    + "downloadState=\(downloadStateLabel(for: episode.id))"
            )
            return
        }

        beginPlaybackSession(
            episode: episode,
            podcastTitle: podcastTitle,
            feedURL: feedURL,
            audioURL: audioURL,
            localCandidate: localCandidate,
            remoteCandidate: remoteCandidate
        )
    }

    private func startDownloadBeforePlay(
        episode: Episode,
        podcastTitle: String,
        feedURL: URL?,
        remoteURL: URL
    ) {
        pendingDownloadForPlayEpisodeID = episode.id
        PlaybackDiagnostics.info(
            "playEpisode download-before-play episodeID=\(episode.id) remote=\(remoteURL.absoluteString)"
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pendingDownloadForPlayEpisodeID = nil }
            do {
                let localURL = try await self.downloadManager.download(
                    episodeID: episode.id,
                    from: remoteURL
                ) { _ in }
                self.beginPlaybackSession(
                    episode: episode,
                    podcastTitle: podcastTitle,
                    feedURL: feedURL,
                    audioURL: localURL,
                    localCandidate: localURL,
                    remoteCandidate: remoteURL
                )
            } catch {
                PlaybackDiagnostics.error(
                    "playEpisode download-before-play failed episodeID=\(episode.id) "
                        + "downloadState=\(self.downloadStateLabel(for: episode.id))"
                )
            }
        }
    }

    private func beginPlaybackSession(
        episode: Episode,
        podcastTitle: String,
        feedURL: URL?,
        audioURL: URL,
        localCandidate: URL?,
        remoteCandidate: URL?,
        startAnalysis: Bool = true
    ) {
        analysisRecoveryState = .notNeeded
        restoredAnalysisContext = nil
        stagedRefreshIntervals = nil
        PlaybackDiagnostics.logAudioURLResolution(
            episodeID: episode.id,
            localURL: localCandidate,
            remoteURL: remoteCandidate,
            chosen: audioURL
        )

        invalidatePlaybackPreparation()
        clearPlaybackAnalysisProgress()

        // Tear down the prior session before installing a new engine. LibraryEpisodePlayer
        // holds PlaybackEngine strongly; releasing it from nonisolated deinit while the
        // @Observable engine property is still being replaced SIGABRTs (NowPlayingSession).
        flushPlaybackPosition()
        engine?.onPlaybackEnded = nil
        engine?.pause()
        engine?.onUnrelatedContentSkip = nil
        engine?.onSeekCompleted = nil
        remoteCommands.bind(nil)
        playbackCoordinator = nil
        queueCoordinator = nil
        episodePlayer = nil
        engine = nil

        let newEngine = PlaybackEngine(
            url: audioURL,
            title: episode.title,
            artist: podcastTitle
        )
        let coordinator = PlaybackCoordinator(
            pipeline: episodeAnalyzer,
            engine: newEngine,
            settingsStore: settingsStore
        )

        let player = LibraryEpisodePlayer(engine: newEngine)
        // Use AppShellModel as EpisodePlaying so auto-advance loads a full cleaned session.
        let queue = QueueCoordinator(
            queue: queueStore,
            player: self,
            resume: resumeStore,
            sessionStore: nowPlayingSessionStore
        )
        queue.bindCurrentEpisode(episode.id)
        queue.resolveSmartNext = { [weak self] endedID in
            self?.resolveSmartNextEpisodeID(endedEpisodeID: endedID)
        }
        queue.resolveQueuedNext = { [weak self] ids in
            self?.firstReadyQueuedEpisode(in: ids)
        }
        queue.onQueuedPreparationBlocked = { [weak self] in
            guard let self else { return }
            self.isPreparingNextEpisode = true
            self.preparingNextAnnouncement = "Still checking the next episode for ads"
        }
        queue.onEpisodeMarkedPlayed = { [weak self] episodeID in
            self?.handleEpisodeMarkedPlayed(episodeID)
        }

        newEngine.onPlaybackEnded = { [weak self] in
            self?.handleEnginePlaybackEnded()
        }

        engine = newEngine
        playbackCoordinator = coordinator
        episodePlayer = player
        queueCoordinator = queue
        remoteCommands.bind(newEngine)

        nowPlayingEpisodeID = episode.id
        nowPlayingEpisodeTitle = episode.title
        nowPlayingPodcastTitle = podcastTitle
        nowPlayingFeedURL = feedURL
        isMiniPlayerVisible = true
        refreshQueuePresentation()
        try? nowPlayingSessionStore.setActiveEpisodeID(episode.id)
        if let feedURL {
            try? podcastStore.touchLastHeard(feedURL: feedURL)
            if podcastStore.isBinge(feedURL: feedURL) {
                activeBingeFeedURL = feedURL
            } else if activeBingeFeedURL == feedURL {
                activeBingeFeedURL = nil
            }
        }
        refreshComingUp()
        // A new session waits for its first Play action before beginning background
        // preparation. A restored session is handled separately after its durable
        // playback state has been rebuilt.
        didStartPreparationForCurrentSession = false
        PlaybackDiagnostics.info(
            "playEpisode session ready episodeID=\(episode.id) miniPlayer=visible paused=true"
        )
        // Leave paused so AC4's play-button tap yields "playing".

        let resumePosition = resumeStore.position(for: episode.id)
        if resumePosition > 0, startAnalysis {
            engine?.restorePausedPosition(resumePosition)
        }

        // Cold-start restore must stay paused without kicking prepare → play races (ADR-027).
        if !startAnalysis {
            PlaybackDiagnostics.info("playEpisode skip prepare — restore path")
            playbackReadiness = .ready
            return
        }

        // Fixture Library play skips analysis even when cleaning is on (AC8),
        // except when a player-timeline / progressive / mute-marker UITest fixture is active.
        if isFixtureLibraryMode,
           !FixtureLibraryAnalysisTimeline.isEnabled,
           !FixtureTranscript.isNoCacheEnabled,
           !FixtureMuteMarkers.isAnyEnabled,
           !FixturePrerollAdBands.isAnyEnabled {
            PlaybackDiagnostics.info("playEpisode skip prepare — fixture library mode")
            playbackReadiness = .ready
            newEngine.play()
            return
        }

        let cleaningApplies = cleaningApplies(for: episode, feedURL: feedURL)
        let isLocalFile = isLocalFileURL(audioURL)
        guard cleaningApplies, isLocalFile else {
            PlaybackDiagnostics.info(
                "playEpisode skip prepare cleaning=\(cleaningApplies) localFile=\(isLocalFile)"
            )
            playbackReadiness = .ready
            newEngine.play()
            return
        }

        let targetWords = settingsStore.activeNormalizedTargetSet()
        let action = settingsStore.censorAction()
        let channelUnrelated = channelUnrelatedContentEnabled(forFeedURL: feedURL)
        let unrelated = UnrelatedContentOptions(
            enabled: channelUnrelated
                && (settingsStore.unrelatedContentEnabled || cleaningApplies),
            action: settingsStore.unrelatedCensorAction()
        )
        let injected = injectedTranscriptForTesting
            ?? (FixtureTranscript.isNoCacheEnabled ? FixtureTranscript.makeTranscript() : nil)

        playbackReadiness = .preparing
        let requestID = playbackPreparationRequestID
        foregroundPreparationJob = AnalysisJob(
            episodeID: episode.id,
            title: episode.title,
            stage: .transcribing,
            estimate: AnalysisJobEstimate(secondsRemaining: nil, progress: nil),
            updatedAt: Date(),
            retryAfter: nil,
            detail: nil
        )
        PlaybackDiagnostics.logPreparePlaybackStart(
            episodeID: episode.id,
            cleaning: cleaningApplies,
            localFile: isLocalFile
        )
        playbackPreparationTask = Task { @MainActor [weak self, weak coordinator] in
            guard let self, let coordinator, self.isCurrentPlaybackPreparation(requestID, episodeID: episode.id) else { return }
            let cloudObserverID: UUID?
            if let pipeline = self.episodeAnalyzer as? AnalysisPipeline {
                cloudObserverID = pipeline.addCloudAdDetectionObserver(started: { [weak self] in
                    Task { @MainActor in
                        guard let self, self.isCurrentPlaybackPreparation(requestID, episodeID: episode.id) else { return }
                        self.updateForegroundPreparation(
                            episodeID: episode.id,
                            stage: .checkingAds
                        )
                    }
                }, finished: { [weak self] outcome in
                    Task { @MainActor in
                        guard case let .failed(category) = outcome else { return }
                        guard let self, self.isCurrentPlaybackPreparation(requestID, episodeID: episode.id) else { return }
                        self.updateForegroundPreparation(
                            episodeID: episode.id,
                            stage: Self.isRetryableCloudFailure(category) ? .adCheckDelayed : .needsAttention,
                            detail: Self.foregroundDetail(for: category),
                            cloudFailure: category
                        )
                    }
                })
            } else {
                cloudObserverID = nil
            }
            defer {
                if let cloudObserverID, let pipeline = self.episodeAnalyzer as? AnalysisPipeline {
                    pipeline.removeCloudAdDetectionObserver(cloudObserverID)
                }
            }
            defer {
                if self.isCurrentPlaybackPreparation(requestID, episodeID: episode.id) {
                    self.playbackPreparationTask = nil
                    self.isPreparingNextEpisode = false
                    self.preparingNextAnnouncement = nil
                }
                if self.transcriptExists(for: episode.id) {
                    self.transcriptAffordanceGeneration += 1
                }
            }
            do {
                try await coordinator.preparePlayback(
                    episode: EpisodeIdentity(id: episode.id),
                    audioURL: audioURL,
                    targetWords: targetWords,
                    action: action,
                    unrelatedContent: unrelated,
                    injectedTranscript: injected,
                    segmentationContext: SegmentationContext(
                        showTitle: podcastTitle,
                        showDescription: feedURL.flatMap { podcastStore.feedDescription(feedURL: $0) } ?? "",
                        episodeTitle: episode.title,
                        episodeDescription: episode.showNotes ?? ""
                    )
                )
                guard self.isCurrentPlaybackPreparation(requestID, episodeID: episode.id), !Task.isCancelled else { return }
                let (playbackIntervals, analysisUnion) = self.reconcilePlaybackIntervals(
                    profanityAction: action,
                    unrelatedContent: unrelated,
                    pipelineIntervals: coordinator.cachedIntervals,
                    analysisUnion: coordinator.lastAnalysisUnion
                )
                if playbackIntervals != coordinator.cachedIntervals {
                    await coordinator.applyReconciledIntervals(
                        playbackIntervals,
                        profanityAction: action,
                        unrelatedContent: unrelated
                    )
                }
                if let pipeline = self.episodeAnalyzer as? AnalysisPipeline,
                   case let .failed(category)? = pipeline.lastCloudAdDetectionOutcome {
                    self.playbackReadiness = .failed
                    self.updateForegroundPreparation(
                        episodeID: episode.id,
                        stage: Self.isRetryableCloudFailure(category) ? .adCheckDelayed : .needsAttention,
                        detail: Self.foregroundDetail(for: category),
                        cloudFailure: category
                    )
                    return
                }
                PlaybackDiagnostics.logPreparePlaybackEnd(
                    episodeID: episode.id,
                    intervals: playbackIntervals,
                    union: analysisUnion,
                    error: nil
                )
                await self.publishTerminalPlaybackAnalysisSnapshot(
                    intervals: playbackIntervals,
                    analysisUnion: analysisUnion,
                    unrelatedContent: unrelated,
                    audioURL: audioURL
                )
                if !self.settingsStore.canUseCloudTranscriptProcessing {
                    self.updateForegroundPreparation(
                        episodeID: episode.id,
                        stage: .ready,
                        detail: "Ad checks are off"
                    )
                } else if let pipeline = self.episodeAnalyzer as? AnalysisPipeline,
                   case let .failed(category)? = pipeline.lastCloudAdDetectionOutcome {
                    self.updateForegroundPreparation(
                        episodeID: episode.id,
                        stage: Self.isRetryableCloudFailure(category) ? .adCheckDelayed : .needsAttention,
                        detail: Self.foregroundDetail(for: category),
                        cloudFailure: category
                    )
                } else {
                    self.updateForegroundPreparation(episodeID: episode.id, stage: .ready)
                }
                self.playbackReadiness = .ready
                self.engine?.play()
                self.startQueuePreparationIfNeeded()
            } catch {
                guard self.isCurrentPlaybackPreparation(requestID, episodeID: episode.id), !Task.isCancelled else { return }
                PlaybackDiagnostics.logPreparePlaybackEnd(
                    episodeID: episode.id,
                    intervals: coordinator.cachedIntervals,
                    union: coordinator.lastAnalysisUnion,
                    error: error
                )
                PlaybackDiagnostics.error(
                    "Analysis did not finish — playback remains blocked until preparation succeeds."
                )
                self.playbackReadiness = .failed
                let category = CloudAdDetectionFailureCategory.classify(error)
                self.updateForegroundPreparation(
                    episodeID: episode.id,
                    stage: Self.isRetryableCloudFailure(category) ? .adCheckDelayed : .needsAttention,
                    detail: Self.foregroundDetail(for: category),
                    cloudFailure: category
                )
            }
        }
    }

    /// Accept the disclosure and resume the play request that triggered it.
    func enableCloudTranscriptProcessing() {
        settingsStore.cloudTranscriptProcessingConsentPrompted = true
        settingsStore.cloudTranscriptProcessingConsentGranted = true
        settingsStore.cloudTranscriptProcessingEnabled = true
        settingsStore.unrelatedContentEnabled = true
        isCloudTranscriptConsentPresented = false
        resumePendingCloudConsentPlay()
    }

    /// Keep cloud analysis off without interrupting the already-created player session.
    func declineCloudTranscriptProcessing() {
        settingsStore.cloudTranscriptProcessingConsentPrompted = true
        settingsStore.cloudTranscriptProcessingConsentGranted = false
        settingsStore.cloudTranscriptProcessingEnabled = false
        settingsStore.unrelatedContentEnabled = false
        isCloudTranscriptConsentPresented = false
        resumePendingCloudConsentPlay()
    }

    private func resumePendingCloudConsentPlay() {
        let download = pendingCloudConsentDownload
        pendingCloudConsentDownload = nil
        if let download {
            startDownloadAfterCloudConsent(download)
        }
        guard let episode = pendingCloudConsentEpisode else { return }
        let title = pendingCloudConsentPodcastTitle
        let feedURL = pendingCloudConsentFeedURL
        pendingCloudConsentEpisode = nil
        pendingCloudConsentPodcastTitle = ""
        pendingCloudConsentFeedURL = nil
        playEpisode(episode, podcastTitle: title, feedURL: feedURL)
    }

    /// Shows first-use disclosure before a manual download. The deferred work is
    /// represented only by episode data, avoiding a stale table-controller callback.
    @discardableResult
    func requestCloudConsentBeforeDownload(for episode: Episode) -> Bool {
        guard !settingsStore.cloudTranscriptProcessingConsentPrompted,
              let remoteURL = episode.audioURL
        else { return false }
        pendingCloudConsentDownload = PendingCloudConsentDownload(
            episodeID: episode.id,
            remoteURL: remoteURL
        )
        isCloudTranscriptConsentPresented = true
        return true
    }

    private func startDownloadAfterCloudConsent(_ pending: PendingCloudConsentDownload) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await downloadManager.download(
                    episodeID: pending.episodeID,
                    from: pending.remoteURL
                ) { [weak self] _ in
                    self?.refreshQueuePresentation()
                }
            } catch {
                // DownloadManager records its own failure state; handler listeners
                // refresh the episode row without retaining that row here.
                self.refreshQueuePresentation()
            }
        }
    }

    func toggleMiniPlayerPlayPause() {
        let willPlay = !(engine?.isPlaybackRequested ?? false)
        PlaybackDiagnostics.logMiniPlayerToggle(
            willPlay: willPlay,
            enginePresent: engine != nil
        )
        guard let engine else {
            PlaybackDiagnostics.warning("miniPlayer toggle ignored — engine nil")
            return
        }
        if engine.isPlaybackRequested {
            engine.pause()
            flushPlaybackPosition()
        } else if analysisRecoveryState == .missingArtifacts {
            startRestoredRecoveryIfNeeded()
        } else if analysisRecoveryState == .refreshAvailable {
            applyStagedRefreshIfNeeded()
            engine.play()
            startQueuePreparationIfNeeded()
            startRestoredRecoveryIfNeeded()
        } else if playbackReadiness == .preparing {
            PlaybackDiagnostics.info("miniPlayer play ignored — preparation is active")
        } else if playbackReadiness == .failed {
            PlaybackDiagnostics.info("miniPlayer play ignored — preparation needs attention")
        } else {
            applyStagedRefreshIfNeeded()
            engine.play()
            startQueuePreparationIfNeeded()
        }
    }

    func openPreparation() {
        isPreparationPresented = true
        startRestoredRecoveryIfNeeded()
    }

    /// Starts playback only after the terminal preparation state is ready.
    func startPlaybackWhenReady() {
        guard playbackReadiness == .ready else {
            PlaybackDiagnostics.info("playback blocked — preparation is not ready")
            return
        }
        engine?.play()
        startQueuePreparationIfNeeded()
    }

    func expandFullPlayer() {
        guard engine != nil else { return }
        isFullPlayerPresented = true
    }

    /// Affordance gate — complete transcript file on disk (ADR-022).
    func transcriptExists(for episodeID: String) -> Bool {
        transcriptCache.exists(episodeID: episodeID)
    }

    /// Channel-row cleaning summary from IntervalCache hit (ADR-025). Nil on miss.
    func cleaningSummary(for episodeID: String) -> EpisodeCleaningSummary? {
        let targetWords = settingsStore.activeNormalizedTargetSet()
        guard intervalCache.isAnalysisCompleted(episodeID: episodeID, targetWords: targetWords),
              let intervals = intervalCache.load(
                  episodeID: episodeID,
                  targetWords: targetWords
              )
        else {
            return nil
        }
        return CleaningSummaryModel.summary(from: intervals)
    }

    /// Whether the now-playing episode has a cached transcript (full-player affordance).
    var nowPlayingTranscriptExists: Bool {
        // Observe generation so the full-player overlay refreshes after backfill
        // (disk `exists` alone is not an @Observable dependency).
        _ = transcriptAffordanceGeneration
        guard let episodeID = nowPlayingEpisodeID else { return false }
        return transcriptExists(for: episodeID)
    }

    /// Present the transcript sheet for an episode (row or full-player entry).
    func presentTranscript(for episodeID: String) {
        guard let words = transcriptCache.load(episodeID: episodeID), !words.isEmpty else {
            return
        }

        let intervals: [CensorInterval]
        if nowPlayingEpisodeID == episodeID {
            intervals = presentationIntervals(for: episodeID)
        } else if let fromDisk = intervalCache.load(
            episodeID: episodeID,
            targetWords: settingsStore.activeNormalizedTargetSet()
        ) {
            intervals = fromDisk
        } else {
            intervals = []
        }

        // The resume store is only flushed at lifecycle boundaries. When this is
        // the episode currently playing, use the engine's live clock so opening
        // the transcript lands at the word being heard rather than an old save.
        let position: TimeInterval
        if nowPlayingEpisodeID == episodeID, let engine {
            position = engine.currentTime
        } else {
            position = resumeStore.position(for: episodeID)
        }
        transcriptSheetViewModel = TranscriptViewModel.make(
            transcript: words,
            intervals: intervals,
            playbackPosition: position
        )
        transcriptSheetOpenPlaybackPosition = position
        transcriptSheetEpisodeID = episodeID
    }

    func presentTranscriptForNowPlaying() {
        guard let episodeID = nowPlayingEpisodeID else { return }
        presentTranscript(for: episodeID)
    }

    func dismissTranscript() {
        transcriptSheetEpisodeID = nil
        transcriptSheetViewModel = nil
        transcriptSheetOpenPlaybackPosition = 0
    }

    func stopAndDismissPlayer() {
        invalidatePlaybackPreparation()
        flushPlaybackPosition()
        engine?.pause()
        engine?.onUnrelatedContentSkip = nil
        engine?.onSeekCompleted = nil
        remoteCommands.bind(nil)
        isFullPlayerPresented = false
        isMiniPlayerVisible = false
        // Drop coordinators before the player/engine so retain graphs unwind cleanly
        // (QueueCoordinator holds EpisodePlaying; LibraryEpisodePlayer holds engine).
        playbackCoordinator = nil
        queueCoordinator = nil
        // Clear the ObservationIgnored player first, then the @Observable engine, so
        // LibraryEpisodePlayer's nonisolated deinit does not race an Observable setter.
        episodePlayer = nil
        engine = nil
        nowPlayingEpisodeID = nil
        nowPlayingEpisodeTitle = "Now playing"
        nowPlayingPodcastTitle = ""
        nowPlayingFeedURL = nil
        comingUpItems = []
        foregroundPreparationJob = nil
        warmPlanner?.cancel()
        clearPlaybackAnalysisProgress()
        // Durable session id is intentionally retained (ADR-027 intake).
    }

    /// Mini-player Next control: advances to the first episode in manual Up Next.
    /// The interrupted episode remains resumable instead of being dismissed from autoplay.
    func skipToNextUp() {
        guard let episodeID = nowPlayingEpisodeID else { return }
        let position = engine?.currentTime
        queueCoordinator?.handleSkipToNext(
            episodeID: episodeID,
            currentPosition: position
        )
    }

    func setBinge(_ enabled: Bool, feedURL: URL) {
        try? podcastStore.setBinge(enabled, feedURL: feedURL)
        if !enabled, activeBingeFeedURL == feedURL {
            activeBingeFeedURL = nil
        }
        if enabled, nowPlayingFeedURL == feedURL {
            activeBingeFeedURL = feedURL
        }
        refreshComingUp()
        scheduleWarmForComingUp()
    }

    func isBinge(feedURL: URL) -> Bool {
        podcastStore.isBinge(feedURL: feedURL)
    }

    private func handleEnginePlaybackEnded() {
        guard let episodeID = nowPlayingEpisodeID else { return }
        let duration = engine?.duration
        queueCoordinator?.handlePlaybackEnded(episodeID: episodeID, duration: duration)
    }

    private func handleEpisodeMarkedPlayed(_ episodeID: String) {
        if settingsStore.autoDeleteAfterPlayedEnabled {
            removeDownloadAndPreparation(episodeID: episodeID)
        } else {
            refreshQueuePresentation()
        }
    }

    private func resolveSmartNextEpisodeID(
        endedEpisodeID: String
    ) -> String? {
        guard settingsStore.smartAutoplayEnabled else { return nil }

        var engine = SmartOrderEngine(activeBingeFeedURL: activeBingeFeedURL)
        let shows = podcastStore.smartOrderShows()
        guard let next = engine.nextEpisode(
            shows: shows,
            currentEpisodeID: endedEpisodeID,
            currentFeedURL: nowPlayingFeedURL
        ) else {
            return nil
        }

        activeBingeFeedURL = SmartOrderEngine.activeBingeURL(afterPlaying: next)

        let ready = warmPlanner?.isReadyForSeamlessPlay(
            episodeID: next.episodeID,
            feedURL: next.feedURL
        ) ?? false
        if !ready {
            isPreparingNextEpisode = true
            preparingNextAnnouncement =
                "Preparing \(next.podcastTitle)"
        } else {
            isPreparingNextEpisode = false
            preparingNextAnnouncement = nil
        }

        return next.episodeID
    }

    func refreshComingUp() {
        guard settingsStore.smartAutoplayEnabled,
              queueStore.queueEpisodeIDs().isEmpty
        else {
            comingUpItems = []
            return
        }
        let engine = SmartOrderEngine(activeBingeFeedURL: activeBingeFeedURL)
        comingUpItems = engine.peek(
            count: WarmPlanner.peekCount,
            shows: podcastStore.smartOrderShows(),
            currentEpisodeID: nowPlayingEpisodeID,
            currentFeedURL: nowPlayingFeedURL
        )
    }

    func addAndPrepare(episodeID: String) {
        guard podcastStore.episodeLookup(id: episodeID) != nil else { return }
        if resumeStore.isPlayed(episodeID) {
            try? resumeStore.resetForReplay(episodeID)
        }
        try? queueStore.add(episodeID)
        didStartPreparationForCurrentSession = true
        scheduleWarmForComingUp()
        refreshQueuePresentation()
    }

    func moveUpNext(episodeID: String, to index: Int) {
        try? queueStore.move(episodeID, toIndex: index)
        scheduleWarmForComingUp()
        refreshQueuePresentation()
    }

    func moveUpNextToTop(episodeID: String) {
        moveUpNext(episodeID: episodeID, to: 0)
    }

    func removeFromUpNext(episodeID: String) {
        let wasReady = isReadyOffline(episodeID)
        try? queueStore.remove(episodeID)
        if !wasReady {
            warmPlanner?.removeJob(episodeID: episodeID)
            Task { [downloadManager] in
                await downloadManager.cancel(episodeID: episodeID)
                try? downloadManager.deleteDownload(episodeID: episodeID)
            }
        }
        scheduleWarmForComingUp()
        refreshQueuePresentation()
    }

    func removeDownloadAndPreparation(episodeID: String) {
        try? queueStore.remove(episodeID)
        warmPlanner?.removeJob(episodeID: episodeID)
        Task { [downloadManager] in
            await downloadManager.cancel(episodeID: episodeID)
            try? downloadManager.deleteDownload(episodeID: episodeID)
        }
        scheduleWarmForComingUp()
        refreshQueuePresentation()
    }

    func removeFromUpNextWithUndo(episodeID: String) -> QueueUndoSnapshot {
        let snapshot = QueueUndoSnapshot(
            episodeID: episodeID,
            previousQueueIDs: queueStore.queueEpisodeIDs(),
            previousPlayedState: resumeStore.isPlayed(episodeID),
            previousPlaybackPosition: resumeStore.position(for: episodeID),
            marksPlayed: false
        )
        removeFromUpNext(episodeID: episodeID)
        return snapshot
    }

    func markPlayedWithUndo(episodeID: String) -> QueueUndoSnapshot {
        let snapshot = QueueUndoSnapshot(
            episodeID: episodeID,
            previousQueueIDs: queueStore.queueEpisodeIDs(),
            previousPlayedState: resumeStore.isPlayed(episodeID),
            previousPlaybackPosition: resumeStore.position(for: episodeID),
            marksPlayed: true
        )
        try? resumeStore.setPlayed(true, for: episodeID)
        try? queueStore.remove(episodeID)
        scheduleWarmForComingUp()
        refreshQueuePresentation()
        return snapshot
    }

    func restoreQueueMutation(_ snapshot: QueueUndoSnapshot) {
        try? resumeStore.setPlayed(snapshot.previousPlayedState, for: snapshot.episodeID)
        try? resumeStore.setPosition(snapshot.previousPlaybackPosition, for: snapshot.episodeID)
        try? queueStore.restore(snapshot.previousQueueIDs)
        didStartPreparationForCurrentSession = true
        scheduleWarmForComingUp()
        refreshQueuePresentation()
    }

    /// Called after the five-second Undo window for a manual Mark as Played.
    func commitQueueMutation(_ snapshot: QueueUndoSnapshot) {
        guard snapshot.marksPlayed, settingsStore.autoDeleteAfterPlayedEnabled else { return }
        removeDownloadAndPreparation(episodeID: snapshot.episodeID)
    }

    /// Clears manual Up Next while retaining completed downloads. Returns the
    /// exact prior order so the Queue tab can offer a short Undo window.
    @discardableResult
    func clearUpNext() -> [String] {
        let ids = queueStore.queueEpisodeIDs()
        for id in ids {
            let wasReady = isReadyOffline(id)
            if !wasReady {
                warmPlanner?.removeJob(episodeID: id)
                Task { [downloadManager] in
                    await downloadManager.cancel(episodeID: id)
                    try? downloadManager.deleteDownload(episodeID: id)
                }
            }
        }
        try? queueStore.clear()
        scheduleWarmForComingUp()
        return ids
    }

    func restoreUpNext(_ episodeIDs: [String]) {
        try? queueStore.restore(episodeIDs)
        didStartPreparationForCurrentSession = true
        scheduleWarmForComingUp()
        refreshQueuePresentation()
    }

    func playReadyEpisodeNow(_ episodeID: String) {
        guard let currentEpisodeID = nowPlayingEpisodeID,
              podcastStore.episodeLookup(id: episodeID) != nil
        else { return }
        flushPlaybackPosition()
        try? queueStore.prepareForImmediatePlayback(
            selectedEpisodeID: episodeID,
            replacingCurrentEpisodeID: currentEpisodeID
        )
        play(episodeID: episodeID)
        scheduleWarmForComingUp()
    }

    private func isReadyOffline(_ episodeID: String) -> Bool {
        guard let lookup = podcastStore.episodeLookup(id: episodeID) else { return false }
        return warmPlanner?.isReadyOffline(episodeID: episodeID, feedURL: lookup.feedURL) == true
    }

    private func scheduleWarmForComingUp() {
        refreshComingUp()
        // Manual Up Next stays first, followed by visible smart predictions. This
        // makes the listener's ordered queue trustworthy while keeping several
        // likely next episodes ready in the background.
        let smartPredictions = smartPredictionItems()
        warmPlanner?.reaim(
            manualQueueIDs: queueStore.queueEpisodeIDs(),
            predicted: smartPredictions
        )
    }

    private func refreshQueuePresentation() {
        queuePresentationRevision &+= 1
    }

    /// Immediately switches to a tapped Up Next item, retaining the interrupted
    /// episode as the first item to resume afterward.
    func playQueuedEpisodeNow(_ episodeID: String) {
        playReadyEpisodeNow(episodeID)
    }

    private func startQueuePreparationIfNeeded() {
        guard !didStartPreparationForCurrentSession else { return }
        didStartPreparationForCurrentSession = true
        scheduleWarmForComingUp()
    }

    /// Requeue the current preparation selection immediately, bypassing its scheduled retry.
    func retryPreparation(episodeID: String) {
        warmPlanner?.resetJobForRetry(episodeID: episodeID)
        if var job = foregroundPreparationJob, job.episodeID == episodeID {
            job.stage = .queued
            job.estimate = AnalysisJobEstimate(secondsRemaining: nil, progress: nil)
            job.updatedAt = Date()
            job.retryAfter = nil
            job.detail = nil
            job.cloudFailure = nil
            job.retryCount = 0
            foregroundPreparationJob = job
        }
        scheduleWarmForComingUp()
    }

    private func updateForegroundPreparation(
        episodeID: String,
        stage: AnalysisJobStage,
        detail: String? = nil,
        cloudFailure: CloudAdDetectionFailureCategory? = nil
    ) {
        guard var job = foregroundPreparationJob, job.episodeID == episodeID else { return }
        job.stage = stage
        job.detail = detail
        job.cloudFailure = cloudFailure
        job.updatedAt = Date()
        foregroundPreparationJob = job
    }

    private static func isRetryableCloudFailure(_ category: CloudAdDetectionFailureCategory) -> Bool {
        switch category {
        case .network, .rateLimited, .serviceUnavailable, .timeout: return true
        case .disabled, .configuration, .firebaseAuth, .appCheck, .credentials, .unauthorized, .invalidResponse: return false
        }
    }

    private static func foregroundDetail(for category: CloudAdDetectionFailureCategory) -> String {
        switch category {
        case .disabled: return "Cloud ad checks are off"
        case .configuration, .firebaseAuth, .appCheck, .credentials, .unauthorized: return "Ad checks need attention"
        case .invalidResponse: return "Ad check returned an invalid result"
        case .network, .rateLimited, .serviceUnavailable, .timeout: return "Retrying automatically"
        }
    }

    /// Listener override for a delayed ad scan. Existing local profanity intervals remain
    /// active; no Gemini-derived ad interval is required to begin playback.
    func playWithAds(episodeID: String) {
        guard let lookup = podcastStore.episodeLookup(id: episodeID),
              let localURL = resolvedLocalFileURL(for: episodeID)
        else { return }
        beginPlaybackSession(
            episode: lookup.episode,
            podcastTitle: lookup.podcastTitle,
            feedURL: lookup.feedURL,
            audioURL: localURL,
            localCandidate: localURL,
            remoteCandidate: lookup.episode.audioURL,
            startAnalysis: false
        )
        let targets = settingsStore.activeNormalizedTargetSet()
        if let record = intervalCache.loadRecord(episodeID: episodeID, targetWords: targets) {
            let localOnly = record.intervals.filter { $0.source == .profanity }
            Task { @MainActor [weak self, weak coordinator = playbackCoordinator] in
                guard let self, let coordinator, self.nowPlayingEpisodeID == episodeID else { return }
                await coordinator.applyReconciledIntervals(
                    localOnly,
                    profanityAction: settingsStore.censorAction(),
                    unrelatedContent: UnrelatedContentOptions(enabled: false)
                )
                self.engine?.play()
                self.startQueuePreparationIfNeeded()
            }
        } else {
            engine?.play()
            startQueuePreparationIfNeeded()
        }
        isPreparationPresented = false
    }

    private func smartPredictionItems() -> [ComingUpItem] {
        guard settingsStore.smartAutoplayEnabled else { return [] }
        let order = SmartOrderEngine(activeBingeFeedURL: activeBingeFeedURL)
        return order.peek(
            count: WarmPlanner.peekCount,
            shows: podcastStore.smartOrderShows(),
            currentEpisodeID: nowPlayingEpisodeID,
            currentFeedURL: nowPlayingFeedURL
        )
    }

    private func firstReadyQueuedEpisode(in ids: [String]) -> String? {
        guard let first = ids.first,
              let lookup = podcastStore.episodeLookup(id: first),
              warmPlanner?.isReadyForSeamlessPlay(episodeID: first, feedURL: lookup.feedURL) == true
        else { return nil }
        return first
    }

    /// Cold-start / post-relaunch: rebuild paused mini session from durable stores.
    /// Idempotent: no-op if already restored / no durable id / episode missing.
    func restoreNowPlayingSessionIfNeeded() {
        if didAttemptNowPlayingRestore { return }
        didAttemptNowPlayingRestore = true

        if isMiniPlayerVisible, nowPlayingEpisodeID != nil { return }

        guard let id = nowPlayingSessionStore.activeEpisodeID(), !id.isEmpty else { return }

        guard let lookup = podcastStore.episodeLookup(id: id) else {
            try? nowPlayingSessionStore.clear()
            return
        }

        let localCandidate = resolvedLocalFileURL(for: lookup.episode.id)
        let remoteCandidate = lookup.episode.audioURL
        guard let audioURL = resolveAudioURL(for: lookup.episode) else {
            try? nowPlayingSessionStore.clear()
            return
        }

        beginPlaybackSession(
            episode: lookup.episode,
            podcastTitle: lookup.podcastTitle,
            feedURL: lookup.feedURL,
            audioURL: audioURL,
            localCandidate: localCandidate,
            remoteCandidate: remoteCandidate,
            startAnalysis: false
        )

        // A relaunch intentionally does not re-run analysis, but the player chrome and
        // engine still need the completed cache restored. Without this, a previously
        // analyzed episode is playable after launch with an empty seek bar.
        restoreCachedPlaybackAnalysis(
            episode: lookup.episode,
            feedURL: lookup.feedURL,
            audioURL: audioURL
        )

        let position = resumeStore.position(for: id)
        if position > 0 {
            // Prefer restorePausedPosition — do not call pause() afterward (refreshCurrentTime
            // would wipe an in-flight seek). beginPlaybackSession already left transport paused.
            engine?.restorePausedPosition(position)
        }
        restoredAnalysisContext = RestoredAnalysisContext(
            episode: lookup.episode,
            podcastTitle: lookup.podcastTitle,
            feedURL: lookup.feedURL,
            audioURL: audioURL
        )
        let hasExact = intervalCache.isAnalysisCompleted(
            episodeID: lookup.episode.id,
            targetWords: settingsStore.activeNormalizedTargetSet()
        )
        analysisRecoveryState = !cleaningApplies(for: lookup.episode, feedURL: lookup.feedURL)
            ? .notNeeded
            : (hasExact ? .notNeeded : (artifactStore.load(episodeID: lookup.episode.id) == nil ? .missingArtifacts : .refreshAvailable))
        resumeNextUpPreparationAfterRestore()
        // Pause-not-play: never call play() / startPlaybackWhenReady on this path.
    }

    /// A restored listener session may quietly continue preparing its next items so
    /// the next transition is seamless. This never touches the active episode and
    /// only permits new background downloads when the listener has enabled the
    /// explicit Auto-download new episodes preference.
    private func resumeNextUpPreparationAfterRestore() {
        guard settingsStore.autoDownloadEnabled else {
            PlaybackDiagnostics.info("restored session leaves next-up downloads idle — auto-download disabled")
            return
        }
        guard nowPlayingEpisodeID != nil else { return }
        didStartPreparationForCurrentSession = true
        scheduleWarmForComingUp()
    }

    /// Starts analysis only after a listener interaction with a cold-restored session.
    /// It deliberately retains the existing engine and queue binding.
    private func startRestoredRecoveryIfNeeded() {
        guard analysisRecoveryState == .refreshAvailable || analysisRecoveryState == .missingArtifacts,
              let context = restoredAnalysisContext,
              let coordinator = playbackCoordinator
        else { return }
        let hadPriorResult = analysisRecoveryState == .refreshAvailable
        analysisRecoveryState = .inProgress
        if !hadPriorResult { playbackReadiness = .preparing }
        foregroundPreparationJob = AnalysisJob(
            episodeID: context.episode.id,
            title: context.episode.title,
            stage: .transcribing,
            estimate: AnalysisJobEstimate(secondsRemaining: nil, progress: nil),
            updatedAt: Date(), retryAfter: nil, detail: nil
        )
        let targets = settingsStore.activeNormalizedTargetSet()
        let action = settingsStore.censorAction()
        let unrelated = UnrelatedContentOptions(
            enabled: channelUnrelatedContentEnabled(forFeedURL: context.feedURL),
            action: settingsStore.unrelatedCensorAction()
        )
        Task { @MainActor [weak self, weak coordinator] in
            guard let self, let coordinator else { return }
            defer {
                if !hadPriorResult, self.playbackReadiness == .preparing {
                    self.playbackReadiness = .failed
                }
                if self.transcriptExists(for: context.episode.id) {
                    self.transcriptAffordanceGeneration += 1
                }
            }
            do {
                if hadPriorResult {
                    let intervals = try await self.episodeAnalyzer.analyze(
                        episode: EpisodeIdentity(id: context.episode.id),
                        audioURL: context.audioURL,
                        targetWords: targets,
                        injectedTranscript: self.injectedTranscriptForTesting,
                        profanityAction: action,
                        unrelatedContent: unrelated
                    )
                    let union = (self.episodeAnalyzer as? AnalysisPipeline)?.lastAnalysisUnion ?? intervals
                    self.stagedRefreshIntervals = (intervals, union, unrelated, context.audioURL)
                    self.updateForegroundPreparation(episodeID: context.episode.id, stage: .ready)
                    self.analysisRecoveryState = .notNeeded
                } else {
                    try await coordinator.preparePlayback(
                        episode: EpisodeIdentity(id: context.episode.id),
                        audioURL: context.audioURL,
                        targetWords: targets,
                        action: action,
                        unrelatedContent: unrelated,
                        injectedTranscript: self.injectedTranscriptForTesting,
                        segmentationContext: SegmentationContext(
                            showTitle: context.podcastTitle,
                            showDescription: context.feedURL.flatMap { self.podcastStore.feedDescription(feedURL: $0) } ?? "",
                            episodeTitle: context.episode.title,
                            episodeDescription: context.episode.showNotes ?? ""
                        )
                    )
                    await self.publishTerminalPlaybackAnalysisSnapshot(
                        intervals: coordinator.cachedIntervals,
                        analysisUnion: coordinator.lastAnalysisUnion,
                        unrelatedContent: unrelated,
                        audioURL: context.audioURL
                    )
                    self.updateForegroundPreparation(episodeID: context.episode.id, stage: .ready)
                    self.analysisRecoveryState = .notNeeded
                    self.playbackReadiness = .ready
                    self.engine?.play()
                }
            } catch {
                if !hadPriorResult { self.playbackReadiness = .failed }
                self.analysisRecoveryState = hadPriorResult ? .refreshAvailable : .missingArtifacts
                self.updateForegroundPreparation(
                    episodeID: context.episode.id,
                    stage: .needsAttention,
                    detail: "Analysis needs attention",
                    cloudFailure: CloudAdDetectionFailureCategory.classify(error)
                )
            }
        }
    }

    private func applyStagedRefreshIfNeeded() {
        guard let staged = stagedRefreshIntervals,
              let coordinator = playbackCoordinator
        else { return }
        stagedRefreshIntervals = nil
        Task { @MainActor [weak self, weak coordinator] in
            guard let self, let coordinator else { return }
            await coordinator.applyReconciledIntervals(
                staged.0,
                profanityAction: self.settingsStore.censorAction(),
                unrelatedContent: staged.2
            )
            await self.publishTerminalPlaybackAnalysisSnapshot(
                intervals: staged.0,
                analysisUnion: staged.1,
                unrelatedContent: staged.2,
                audioURL: staged.3
            )
        }
    }

    /// Reapplies current derived results, or the durable prior ad result, without
    /// starting ASR/cloud work during cold restoration.
    private func restoreCachedPlaybackAnalysis(
        episode: Episode,
        feedURL: URL?,
        audioURL: URL
    ) {
        guard cleaningApplies(for: episode, feedURL: feedURL) else { return }

        let targetWords = settingsStore.activeNormalizedTargetSet()
        let exactRecord = intervalCache.loadRecord(
            episodeID: episode.id,
            targetWords: targetWords
        ).flatMap { $0.analysisCompleted ? $0 : nil }

        let action = settingsStore.censorAction()
        let unrelated = UnrelatedContentOptions(
            enabled: channelUnrelatedContentEnabled(forFeedURL: feedURL)
                && (settingsStore.unrelatedContentEnabled || cleaningApplies(for: episode, feedURL: feedURL)),
            action: settingsStore.unrelatedCensorAction()
        )
        let union: [CensorInterval]
        if let exactRecord {
            union = exactRecord.intervals
        } else if let artifact = artifactStore.load(episodeID: episode.id) {
            let adIntervals = artifact.adSpans.map {
                CensorInterval(start: $0.start, end: $0.end, action: unrelated.action, source: .unrelatedContent)
            }
            let profanity = transcriptCache.load(episodeID: episode.id).map {
                IntervalBuilder.buildIntervals(from: $0, targetSet: targetWords, action: action)
            } ?? []
            union = (profanity + adIntervals).sorted { $0.start < $1.start }
        } else {
            return
        }
        let playbackIntervals = AnalysisPipeline.projectPlaybackIntervals(
            union: union,
            profanityAction: action,
            unrelatedContent: unrelated
        )

        Task { @MainActor [weak self, weak coordinator = playbackCoordinator] in
            guard let self, let coordinator,
                  self.nowPlayingEpisodeID == episode.id
            else { return }
            await coordinator.applyReconciledIntervals(
                playbackIntervals,
                profanityAction: action,
                unrelatedContent: unrelated
            )
            await self.publishTerminalPlaybackAnalysisSnapshot(
                intervals: playbackIntervals,
                analysisUnion: union,
                unrelatedContent: unrelated,
                audioURL: audioURL
            )
        }
    }

    /// Writes `ResumePositionStore` from the live engine clock for the active id.
    func flushPlaybackPosition() {
        let episodeID = nowPlayingEpisodeID ?? nowPlayingSessionStore.activeEpisodeID()
        guard let episodeID, let engine else { return }
        let seconds = engine.currentTime
        try? resumeStore.setPosition(seconds, for: episodeID)
    }

    private func clearPlaybackAnalysisProgress() {
        playbackReadiness = .ready
        playbackAnalysisSnapshot = nil
    }

    private func invalidatePlaybackPreparation() {
        playbackPreparationRequestID &+= 1
        playbackPreparationTask?.cancel()
        playbackPreparationTask = nil
    }

    private func isCurrentPlaybackPreparation(_ requestID: Int, episodeID: String) -> Bool {
        requestID == playbackPreparationRequestID && nowPlayingEpisodeID == episodeID
    }

    /// Pins the terminal colored timeline for player chrome after analysis completes.
    private func publishTerminalPlaybackAnalysisSnapshot(
        intervals: [CensorInterval],
        analysisUnion: [CensorInterval],
        unrelatedContent: UnrelatedContentOptions,
        audioURL: URL
    ) async {
        let duration = await resolvedEpisodeDuration(audioURL: audioURL)
        guard duration > 0 else { return }
        playbackAnalysisSnapshot = AnalysisTimelineModel.completeSnapshot(
            duration: duration,
            intervals: intervals,
            adRangeIntervals: AnalysisPipeline.adRangePaintIntervals(
                playbackIntervals: intervals,
                analysisUnion: analysisUnion,
                unrelatedContentEnabled: unrelatedContent.enabled
            )
        )
    }

    /// Intervals for transcript skipped-ad rows and mini/full seek-bar ad bands.
    /// Prefers applied schedule, then coordinator cache, then persisted analysis union.
    private func presentationIntervals(for episodeID: String) -> [CensorInterval] {
        if let coordinator = playbackCoordinator, nowPlayingEpisodeID == episodeID {
            let applied = coordinator.appliedPlaybackIntervals
            if !applied.isEmpty {
                return applied
            }
            if !coordinator.cachedIntervals.isEmpty {
                return coordinator.cachedIntervals
            }
        }
        if let fromDisk = intervalCache.load(
            episodeID: episodeID,
            targetWords: settingsStore.activeNormalizedTargetSet()
        ) {
            return fromDisk
        }
        if let artifact = artifactStore.load(episodeID: episodeID) {
            let profanity = transcriptCache.load(episodeID: episodeID).map {
                IntervalBuilder.buildIntervals(
                    from: $0,
                    targetSet: settingsStore.activeNormalizedTargetSet(),
                    action: settingsStore.censorAction()
                )
            } ?? []
            let adIntervals = artifact.adSpans.map {
                CensorInterval(
                    start: $0.start,
                    end: $0.end,
                    action: settingsStore.unrelatedCensorAction(),
                    source: .unrelatedContent
                )
            }
            return profanity + adIntervals
        }
        return []
    }

    /// Re-project analyze union when playback analyze omitted unrelated (legacy 4-arg spies).
    private func reconcilePlaybackIntervals(
        profanityAction: CensorAction,
        unrelatedContent: UnrelatedContentOptions,
        pipelineIntervals: [CensorInterval],
        analysisUnion: [CensorInterval]
    ) -> (playbackIntervals: [CensorInterval], analysisUnion: [CensorInterval]) {
        guard unrelatedContent.enabled,
              analysisUnion.contains(where: { $0.source == .unrelatedContent })
        else {
            return (pipelineIntervals, analysisUnion)
        }

        let projected = AnalysisPipeline.projectPlaybackIntervals(
            union: analysisUnion,
            profanityAction: profanityAction,
            unrelatedContent: unrelatedContent
        )
        return (projected, analysisUnion)
    }

    private func resolvedEpisodeDuration(audioURL: URL) async -> Double {
        if FixturePrerollAdBands.isAnyEnabled {
            return FixturePrerollAdBands.episodeDuration
        }
        if let engine, engine.duration > 0 {
            return engine.duration
        }
        // Match PlaybackEngine remapping — downloads may be WAVE/MP3 bytes under `.m4a`.
        let playableURL = PlaybackEngine.playableFileURL(for: audioURL)
        if let headerDuration = PlaybackEngine.waveFileDuration(for: playableURL), headerDuration > 0 {
            return headerDuration
        }
        let asset = AVURLAsset(url: playableURL)
        do {
            let loaded = try await asset.load(.duration)
            let seconds = loaded.seconds
            guard seconds.isFinite, seconds > 0 else {
                return engine?.duration ?? 0
            }
            return seconds
        } catch {
            return engine?.duration ?? 0
        }
    }

    private func resolveAudioURL(for episode: Episode) -> URL? {
        if FixtureTranscript.isScrollFollowEnabled {
            return FixtureTranscript.scrollFollowAudioURL()
        }
        if FixturePrerollAdBands.isAnyEnabled {
            return FixturePrerollAdBands.bundledURL()
        }
        if FixtureMuteMarkers.isAnyEnabled {
            return FixtureMuteMarkers.bundledURL()
        }
        if isFixtureLibraryMode, !FixtureDownload.isEnabled {
            return FixtureAudio.bundledURL()
        }
        if let localURL = resolvedLocalFileURL(for: episode.id) {
            return localURL
        }
        return episode.audioURL
    }

    /// Channel cleaning on + no local file → download before play (task-012).
    /// Fixture Library keeps bundled-audio play unless `-UITestFixtureDownload` is set.
    private func shouldDownloadBeforePlay(for episode: Episode, feedURL: URL?) -> Bool {
        guard cleaningApplies(for: episode, feedURL: feedURL) else { return false }
        guard resolvedLocalFileURL(for: episode.id) == nil else { return false }
        if isFixtureLibraryMode, !FixtureDownload.isEnabled { return false }
        return true
    }

    private func resolvedLocalFileURL(for episodeID: String) -> URL? {
        if let testDirectory = downloadsDirectoryForTesting {
            return try? DownloadPaths.migrateLegacyLocalFileIfNeeded(
                episodeID: episodeID,
                downloadsDirectory: testDirectory
            )
        }
        return downloadManager.localFileURL(for: episodeID)
    }

    private func isLocalFileURL(_ url: URL) -> Bool {
        url.isFileURL && FileManager.default.fileExists(atPath: url.path)
    }

    private func cleaningApplies(for episode: Episode, feedURL: URL?) -> Bool {
        channelCleaningEnabled(forFeedURL: feedURL)
    }

    private func channelCleaningEnabled(forFeedURL feedURL: URL?) -> Bool {
        if let feedURL {
            return cleaningStore.isChannelCleaningEnabled(forFeedURL: feedURL)
        }
        return cleaningStore.isChannelCleaningEnabled
    }

    private func channelUnrelatedContentEnabled(forFeedURL feedURL: URL?) -> Bool {
        if let feedURL {
            return cleaningStore.isChannelUnrelatedContentEnabled(forFeedURL: feedURL)
        }
        return cleaningStore.isChannelUnrelatedContentEnabled
    }

    private func downloadStateLabel(for episodeID: String) -> String {
        switch downloadManager.state(for: episodeID) {
        case .notDownloaded: return "notDownloaded"
        case .downloading(let progress): return String(format: "downloading(%.2f)", progress)
        case .downloaded: return "downloaded"
        case .failed: return "failed"
        }
    }
}

// MARK: - CarPlay (ADR-016)

extension AppShellModel: CarPlayDependencyProviding {}

extension AppShellModel: EpisodePlaying {
    func play(episodeID: String) {
        for summary in podcastStore.allSubscriptions() {
            guard
                let feed = podcastStore.subscription(forFeedURL: summary.feedURL),
                let episode = feed.episodes.first(where: { $0.id == episodeID })
            else { continue }
            playEpisode(episode, podcastTitle: summary.title, feedURL: summary.feedURL)
            startPlaybackWhenReady()
            return
        }
    }

    func pause() {
        engine?.pause()
        flushPlaybackPosition()
    }

    func seek(to seconds: TimeInterval) {
        engine?.seek(to: seconds)
    }
}
