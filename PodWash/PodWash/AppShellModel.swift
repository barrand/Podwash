//
//  AppShellModel.swift
//  PodWash
//
//  Slice 23 — Production composition root + mini-player session (ADR-015 §4).
//  Slice 24 — Production analysis wiring (ADR-020 §5–§8).
//

import Foundation

@MainActor @Observable
final class AppShellModel {
    let persistence: PersistenceController
    let podcastStore: PodcastStore
    let queueStore: QueueStore
    let resumeStore: ResumePositionStore
    let cleaningStore: CleaningToggleStore
    let downloadManager: DownloadManager
    let settingsStore: SettingsStore
    let remoteCommands: RemoteCommandCoordinator

    /// Shared by play path and LibraryPodcastDetailView / AnalysisUIViewModel.
    private(set) var episodeAnalyzer: any EpisodeAnalyzing

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
            ?? (FixtureLibrary.isEnabled || FixtureLibrary.isEmptyEnabled)
    }

    private(set) var engine: PlaybackEngine?
    private(set) var playbackCoordinator: PlaybackCoordinator?
    private(set) var queueCoordinator: QueueCoordinator?
    private var episodePlayer: LibraryEpisodePlayer?

    /// Drives mini-player visibility (true after a successful episode play start).
    private(set) var isMiniPlayerVisible: Bool = false
    /// Full controls presentation (sheet).
    var isFullPlayerPresented: Bool = false

    private(set) var nowPlayingEpisodeTitle: String = "Now playing"
    private(set) var nowPlayingPodcastTitle: String = ""

    init(
        persistence: PersistenceController,
        remoteCommands: RemoteCommandCoordinator,
        episodeAnalyzer: (any EpisodeAnalyzing)? = nil,
        settingsStore: SettingsStore? = nil,
        fixtureLibraryModeForTesting: Bool? = nil
    ) {
        self.persistence = persistence
        self.remoteCommands = remoteCommands
        self.fixtureLibraryModeForTesting = fixtureLibraryModeForTesting
        self.settingsStore = settingsStore ?? SettingsStore()
        self.episodeAnalyzer = episodeAnalyzer
            ?? Self.makeDefaultAnalyzer(fixtureLibraryMode: fixtureLibraryModeForTesting)

        let context = persistence.viewContext
        podcastStore = PodcastStore(context: context, retaining: persistence)
        queueStore = QueueStore(context: context)
        resumeStore = ResumePositionStore(context: context)
        cleaningStore = CleaningToggleStore(context: context)
        let downloadStateStore = DownloadStateStore(context: context)
        downloadManager = DownloadManager(
            downloadsDirectory: DownloadPaths.productionDownloadsDirectory,
            stateStore: InMemoryDownloadStateStore(backing: downloadStateStore)
        )
        CarPlayDependencies.register(self)
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
    nonisolated deinit {}

    var carPlayEpisodePlayer: (any EpisodePlaying)? { self }
    var carPlayPlaybackEngine: PlaybackEngine? { engine }

    /// Library / detail entry: resolve audio, prepare engine + coordinators, show mini-player paused.
    /// Playback starts when the user taps `miniPlayerPlayPause` (AC4).
    /// Synchronous so episode-row taps publish `miniPlayer` before XCTest post-tap idle.
    func playEpisode(_ episode: Episode, podcastTitle: String, feedURL: URL? = nil) {
        guard let audioURL = resolveAudioURL(for: episode) else { return }

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
        let queue = QueueCoordinator(
            queue: queueStore,
            player: player,
            resume: resumeStore
        )

        engine = newEngine
        playbackCoordinator = coordinator
        episodePlayer = player
        queueCoordinator = queue
        remoteCommands.bind(newEngine)

        nowPlayingEpisodeTitle = episode.title
        nowPlayingPodcastTitle = podcastTitle
        isMiniPlayerVisible = true
        // Leave paused so AC4's play-button tap yields "playing".

        // Fixture Library play skips analysis even when cleaning is on (AC8).
        if isFixtureLibraryMode { return }

        let cleaningApplies = cleaningApplies(for: episode, feedURL: feedURL)
        let isLocalFile = isLocalFileURL(audioURL)
        guard cleaningApplies, isLocalFile else { return }

        let targetWords = settingsStore.activeNormalizedTargetSet()
        let action = settingsStore.censorAction()
        let channelUnrelated = channelUnrelatedContentEnabled(forFeedURL: feedURL)
        let unrelated = UnrelatedContentOptions(
            enabled: settingsStore.unrelatedContentEnabled && channelUnrelated,
            action: settingsStore.unrelatedCensorAction()
        )
        let injected = injectedTranscriptForTesting

        Task { @MainActor in
            try? await coordinator.preparePlayback(
                episode: EpisodeIdentity(id: episode.id),
                audioURL: audioURL,
                targetWords: targetWords,
                action: action,
                unrelatedContent: unrelated,
                injectedTranscript: injected
            )
        }
    }

    func toggleMiniPlayerPlayPause() {
        guard let engine else { return }
        if engine.isPlaying {
            engine.pause()
        } else {
            engine.play()
        }
    }

    func expandFullPlayer() {
        guard engine != nil else { return }
        isFullPlayerPresented = true
    }

    func stopAndDismissPlayer() {
        engine?.pause()
        isFullPlayerPresented = false
        isMiniPlayerVisible = false
        engine = nil
        playbackCoordinator = nil
        queueCoordinator = nil
        episodePlayer = nil
    }

    private func resolveAudioURL(for episode: Episode) -> URL? {
        if isFixtureLibraryMode {
            return FixtureAudio.bundledURL()
        }
        let downloadsDirectory = downloadsDirectoryForTesting
            ?? DownloadPaths.productionDownloadsDirectory
        let resolver = PlaybackSourceResolver(downloadsDirectory: downloadsDirectory)
        return resolver.playbackURL(for: episode)
    }

    private func isLocalFileURL(_ url: URL) -> Bool {
        url.isFileURL && FileManager.default.fileExists(atPath: url.path)
    }

    private func cleaningApplies(for episode: Episode, feedURL: URL?) -> Bool {
        if cleaningStore.isEpisodeCleaningEnabled(episode.id) {
            return true
        }
        return channelCleaningEnabled(forFeedURL: feedURL)
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
            // CarPlay selection starts playback immediately (phone mini-player stays paused until tap).
            engine?.play()
            return
        }
    }

    func pause() {
        engine?.pause()
    }

    func seek(to seconds: TimeInterval) {
        engine?.seek(to: seconds)
    }
}
