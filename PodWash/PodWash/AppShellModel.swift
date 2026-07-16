//
//  AppShellModel.swift
//  PodWash
//
//  Slice 23 — Production composition root + mini-player session (ADR-015 §4).
//  Slice 24 — Production analysis wiring (ADR-020 §5–§8).
//

import AVFoundation
import Foundation

@MainActor @Observable
final class AppShellModel {
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

    /// Latest progress for the mini-player timeline (nil when no playback analysis).
    private(set) var playbackAnalysisSnapshot: AnalysisProgressSnapshot?

    /// Episode currently driving the mini-player session.
    private(set) var nowPlayingEpisodeID: String?

    /// When true, relay progress updates `playbackAnalysisSnapshot`.
    private var acceptingPlaybackProgress = false

    /// True while `preparePlayback` is running for the current episode.
    private(set) var isPreparingPlayback = false

    /// User tapped play while analysis was still preparing; start once ready.
    private var pendingPlayAfterPrepare = false

    /// Episode awaiting download-before-play (channel cleaning on, no local file).
    private var pendingDownloadForPlayEpisodeID: String?

    private var playbackProgressHandlerID: UUID?

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
                || FixtureProgressivePlayback.isEnabled
                || FixtureTranscript.isAnyEnabled
                || FixtureMuteMarkers.isAnyEnabled
                || FixturePrerollAdBands.isAnyEnabled)
    }

    /// Applied / cached intervals for mute-marker overlays on mini + full player (ADR-023 / ADR-026).
    var nowPlayingMuteIntervals: [CensorInterval] {
        playbackCoordinator?.cachedIntervals ?? []
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

    private(set) var nowPlayingEpisodeTitle: String = "Now playing"
    private(set) var nowPlayingPodcastTitle: String = ""
    /// Feed URL for the active now-playing episode (smart order / binge).
    private(set) var nowPlayingFeedURL: URL?

    /// Active binge context for smart autoplay (ADR-029).
    private var activeBingeFeedURL: URL?

    /// Coming up peek for UI (next 2–3 smart predictions when Up Next is empty).
    private(set) var comingUpItems: [ComingUpItem] = []

    /// True while waiting on analysis before auto-advancing (rare miss path).
    private(set) var isPreparingNextEpisode = false
    private(set) var preparingNextAnnouncement: String?

    @ObservationIgnored private var warmPlanner: WarmPlanner?

    /// Spoken / AX announcement generation for Preparing fallback.
    private(set) var preparingAnnouncementGeneration = 0

    init(
        persistence: PersistenceController,
        remoteCommands: RemoteCommandCoordinator,
        episodeAnalyzer: (any EpisodeAnalyzing)? = nil,
        settingsStore: SettingsStore? = nil,
        fixtureLibraryModeForTesting: Bool? = nil,
        downloadManager: DownloadManager? = nil,
        transcriptCache: TranscriptCache = .applicationSupport,
        intervalCache: IntervalCache = .applicationSupport
    ) {
        self.persistence = persistence
        self.remoteCommands = remoteCommands
        self.fixtureLibraryModeForTesting = fixtureLibraryModeForTesting
        self.settingsStore = settingsStore ?? SettingsStore()
        self.transcriptCache = transcriptCache
        self.intervalCache = intervalCache
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
            podcastStore: podcastStore
        )

        playbackProgressHandlerID = analysisProgressRelay.addHandler { [weak self] snapshot in
            guard let self, self.acceptingPlaybackProgress else { return }
            self.playbackAnalysisSnapshot = snapshot
            if snapshot.processedEnd >= snapshot.episodeDuration {
                self.acceptingPlaybackProgress = false
            }
        }

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

    /// Complete seek-bar paint (green + timestamp yellow + mute red) when analysis finished.
    var isPlayerSeekBarAnalysisComplete: Bool {
        guard let snapshot = playbackAnalysisSnapshot else { return false }
        return snapshot.processedEnd >= snapshot.episodeDuration
    }

    /// Overall analysis progress while in flight; `nil` when complete / no snapshot.
    var analysisProgressFraction: Double? {
        guard let snapshot = playbackAnalysisSnapshot else { return nil }
        guard snapshot.processedEnd < snapshot.episodeDuration else { return nil }
        return SuperSeekBarModel.analysisProgress(
            processedEnd: snapshot.processedEnd,
            duration: snapshot.episodeDuration
        )
    }

    /// Seek frontier for the super seek bar (processedEnd while in flight; duration when complete / cleaning off).
    var superSeekProcessedEnd: Double {
        guard let snapshot = playbackAnalysisSnapshot else {
            return engine?.duration ?? 0
        }
        if snapshot.processedEnd >= snapshot.episodeDuration {
            return snapshot.episodeDuration
        }
        return snapshot.processedEnd
    }

    /// Episode duration for seek bar math — prefers analysis snapshot (120 s fixture) over asset.
    var superSeekDuration: Double {
        if let snapshot = playbackAnalysisSnapshot, snapshot.episodeDuration > 0 {
            return snapshot.episodeDuration
        }
        return engine?.duration ?? 0
    }

    /// Clamped seek used by mini + full super seek bars and ±15 transport.
    func seekClampedToProcessedFrontier(to seconds: Double) {
        let frontier = superSeekProcessedEnd > 0
            ? superSeekProcessedEnd
            : (engine?.duration ?? seconds)
        let clamped = SuperSeekBarModel.clampedSeek(requested: seconds, processedEnd: frontier)
        engine?.seek(to: clamped)
        // Seek-while-paused must still land in ResumePositionStore (ADR-027 flush budget).
        if engine?.isPlaying != true {
            flushPlaybackPosition()
        }
    }

    func seekClampedToProcessedFrontier(by delta: Double) {
        // Prefer the engine's observable clock — AVPlayer may still report 0/NaN while
        // the item loads, which would wipe a paused restore / pinned seek target.
        let current = engine?.currentTime ?? 0
        seekClampedToProcessedFrontier(to: current + delta)
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
        PlaybackDiagnostics.logAudioURLResolution(
            episodeID: episode.id,
            localURL: localCandidate,
            remoteURL: remoteCandidate,
            chosen: audioURL
        )

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
        queue.resolveSmartNext = { [weak self] endedID, skipToNextShow in
            self?.resolveSmartNextEpisodeID(
                endedEpisodeID: endedID,
                skipToNextShow: skipToNextShow
            )
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
        scheduleWarmForComingUp()
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
            return
        }

        // Fixture Library play skips analysis even when cleaning is on (AC8),
        // except when a player-timeline / progressive / mute-marker UITest fixture is active.
        if isFixtureLibraryMode,
           !FixtureLibraryAnalysisTimeline.isEnabled,
           !FixtureProgressivePlayback.isEnabled,
           !FixtureTranscript.isNoCacheEnabled,
           !FixtureMuteMarkers.isAnyEnabled,
           !FixturePrerollAdBands.isAnyEnabled {
            PlaybackDiagnostics.info("playEpisode skip prepare — fixture library mode")
            return
        }

        let cleaningApplies = cleaningApplies(for: episode, feedURL: feedURL)
        let isLocalFile = isLocalFileURL(audioURL)
        guard cleaningApplies, isLocalFile else {
            PlaybackDiagnostics.info(
                "playEpisode skip prepare cleaning=\(cleaningApplies) localFile=\(isLocalFile)"
            )
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

        acceptingPlaybackProgress = true
        isPreparingPlayback = true
        PlaybackDiagnostics.logPreparePlaybackStart(
            episodeID: episode.id,
            cleaning: cleaningApplies,
            localFile: isLocalFile
        )
        Task { @MainActor in
            let duration = await resolvedEpisodeDuration(audioURL: audioURL)
            if duration > 0 {
                playbackAnalysisSnapshot = AnalysisTimelineModel.startSnapshot(duration: duration)
            }

            defer {
                acceptingPlaybackProgress = false
                isPreparingPlayback = false
                isPreparingNextEpisode = false
                preparingNextAnnouncement = nil
                if transcriptExists(for: episode.id) {
                    transcriptAffordanceGeneration += 1
                } else if FixtureTranscript.isNoCacheEnabled {
                    // Deferred NoCache backfill stores off the prepare path (AC7).
                    // Poll so task-020's episode.viewTranscript refresh does not
                    // depend solely on NotificationCenter delivery under UITest.
                    let episodeID = episode.id
                    Task { @MainActor [weak self] in
                        for _ in 0..<24 {
                            try? await Task.sleep(for: .milliseconds(500))
                            guard let self else { return }
                            if self.transcriptExists(for: episodeID) {
                                self.transcriptAffordanceGeneration += 1
                                return
                            }
                        }
                    }
                }
                let shouldPlay = pendingPlayAfterPrepare
                pendingPlayAfterPrepare = false
                if shouldPlay, engine?.isPlaying != true {
                    engine?.play()
                }
            }
            do {
                try await coordinator.preparePlaybackProgressive(
                    episode: EpisodeIdentity(id: episode.id),
                    audioURL: audioURL,
                    targetWords: targetWords,
                    action: action,
                    unrelatedContent: unrelated,
                    injectedTranscript: injected,
                    onChunkReady: { [weak self] in
                        guard let self else { return }
                        guard self.pendingPlayAfterPrepare else { return }
                        self.pendingPlayAfterPrepare = false
                        self.engine?.play()
                    }
                )
                let (playbackIntervals, analysisUnion) = reconcilePlaybackIntervals(
                    profanityAction: action,
                    unrelatedContent: unrelated,
                    pipelineIntervals: coordinator.cachedIntervals,
                    analysisUnion: coordinator.lastAnalysisUnion
                )
                if playbackIntervals != coordinator.cachedIntervals {
                    await coordinator.applyReconciledIntervals(playbackIntervals)
                }
                PlaybackDiagnostics.logPreparePlaybackEnd(
                    episodeID: episode.id,
                    intervals: playbackIntervals,
                    union: analysisUnion,
                    error: nil
                )
                await publishTerminalPlaybackAnalysisSnapshot(
                    intervals: playbackIntervals,
                    analysisUnion: analysisUnion,
                    unrelatedContent: unrelated,
                    audioURL: audioURL
                )
            } catch {
                PlaybackDiagnostics.logPreparePlaybackEnd(
                    episodeID: episode.id,
                    intervals: coordinator.cachedIntervals,
                    union: coordinator.lastAnalysisUnion,
                    error: error
                )
                PlaybackDiagnostics.error(
                    "Analysis did not finish — playback will be uncleaned until you replay this episode."
                )
            }
        }
    }

    func toggleMiniPlayerPlayPause() {
        let willPlay = !(engine?.isPlaying ?? false)
        PlaybackDiagnostics.logMiniPlayerToggle(
            willPlay: willPlay,
            enginePresent: engine != nil
        )
        guard let engine else {
            PlaybackDiagnostics.warning("miniPlayer toggle ignored — engine nil")
            return
        }
        if engine.isPlaying {
            engine.pause()
            flushPlaybackPosition()
        } else if isPreparingPlayback {
            if playbackCoordinator?.canStartPlayback == true {
                engine.play()
            } else {
                pendingPlayAfterPrepare = true
                PlaybackDiagnostics.info("miniPlayer play queued — waiting for analysis")
            }
        } else {
            engine.play()
        }
    }

    /// Starts playback when allowed, or queues play until analysis finishes.
    func startPlaybackWhenReady() {
        if isPreparingPlayback {
            if playbackCoordinator?.canStartPlayback == true {
                engine?.play()
            } else {
                pendingPlayAfterPrepare = true
                PlaybackDiagnostics.info("playback queued — analysis in flight")
            }
            return
        }
        engine?.play()
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
        guard let intervals = intervalCache.load(
            episodeID: episodeID,
            targetWords: settingsStore.activeNormalizedTargetSet()
        ) else {
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
        if let coordinator = playbackCoordinator, nowPlayingEpisodeID == episodeID {
            let applied = coordinator.appliedPlaybackIntervals
            if !applied.isEmpty {
                intervals = applied
            } else if !coordinator.cachedIntervals.isEmpty {
                intervals = coordinator.cachedIntervals
            } else if let fromDisk = intervalCache.load(
                episodeID: episodeID,
                targetWords: settingsStore.activeNormalizedTargetSet()
            ) {
                intervals = fromDisk
            } else {
                intervals = []
            }
        } else if let fromDisk = intervalCache.load(
            episodeID: episodeID,
            targetWords: settingsStore.activeNormalizedTargetSet()
        ) {
            intervals = fromDisk
        } else {
            intervals = []
        }

        let position = resumeStore.position(for: episodeID)
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
        warmPlanner?.cancel()
        clearPlaybackAnalysisProgress()
        // Durable session id is intentionally retained (ADR-027 intake).
    }

    /// Next Show control — dismiss current from autoplay and advance (ADR-029).
    func skipToNextShow() {
        guard let episodeID = nowPlayingEpisodeID else { return }
        let position = engine?.currentTime
        queueCoordinator?.handleSkipToNextShow(
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

    private func resolveSmartNextEpisodeID(
        endedEpisodeID: String,
        skipToNextShow: Bool
    ) -> String? {
        guard settingsStore.smartAutoplayEnabled else { return nil }

        if skipToNextShow {
            try? podcastStore.setDismissedFromAutoplay(true, episodeID: endedEpisodeID)
            activeBingeFeedURL = nil
        }

        var engine = SmartOrderEngine(activeBingeFeedURL: activeBingeFeedURL)
        let shows = podcastStore.smartOrderShows()
        guard let next = engine.nextEpisode(
            shows: shows,
            currentEpisodeID: endedEpisodeID,
            currentFeedURL: nowPlayingFeedURL,
            skipToNextShow: skipToNextShow
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
            preparingAnnouncementGeneration += 1
        } else {
            isPreparingNextEpisode = false
            preparingNextAnnouncement = nil
        }

        return next.episodeID
    }

    func refreshComingUp() {
        guard settingsStore.smartAutoplayEnabled else {
            comingUpItems = []
            return
        }
        if !queueStore.queueEpisodeIDs().isEmpty {
            // Manual Up Next wins — Coming up shows smart peek after the queue empties.
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

    private func scheduleWarmForComingUp() {
        refreshComingUp()
        warmPlanner?.reaim(at: comingUpItems)
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

        let position = resumeStore.position(for: id)
        if position > 0 {
            // Prefer restorePausedPosition — do not call pause() afterward (refreshCurrentTime
            // would wipe an in-flight seek). beginPlaybackSession already left transport paused.
            engine?.restorePausedPosition(position)
        }
        // Pause-not-play: never call play() / startPlaybackWhenReady on this path.
    }

    /// Writes `ResumePositionStore` from the live engine clock for the active id.
    func flushPlaybackPosition() {
        let episodeID = nowPlayingEpisodeID ?? nowPlayingSessionStore.activeEpisodeID()
        guard let episodeID, let engine else { return }
        let seconds = engine.currentTime
        try? resumeStore.setPosition(seconds, for: episodeID)
    }

    private func clearPlaybackAnalysisProgress() {
        acceptingPlaybackProgress = false
        isPreparingPlayback = false
        pendingPlayAfterPrepare = false
        playbackAnalysisSnapshot = nil
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
        if FixtureProgressivePlayback.isEnabled {
            return FixtureProgressivePlayback.bundledURL()
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
