//
//  AppShellModel.swift
//  PodWash
//
//  Slice 23 — Production composition root + mini-player session (ADR-015 §4).
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

    init(persistence: PersistenceController, remoteCommands: RemoteCommandCoordinator) {
        self.persistence = persistence
        self.remoteCommands = remoteCommands
        let context = persistence.viewContext
        podcastStore = PodcastStore(context: context, retaining: persistence)
        queueStore = QueueStore(context: context)
        resumeStore = ResumePositionStore(context: context)
        cleaningStore = CleaningToggleStore(context: context)
        settingsStore = SettingsStore()
        let downloadStateStore = DownloadStateStore(context: context)
        downloadManager = DownloadManager(
            downloadsDirectory: DownloadPaths.productionDownloadsDirectory,
            stateStore: InMemoryDownloadStateStore(backing: downloadStateStore)
        )
        CarPlayDependencies.register(self)
    }

    // Avoid MainActor/TaskLocal deinit crash under SWIFT_DEFAULT_ACTOR_ISOLATION.
    nonisolated deinit {}

    var carPlayEpisodePlayer: (any EpisodePlaying)? { self }
    var carPlayPlaybackEngine: PlaybackEngine? { engine }

    /// Library / detail entry: resolve audio, prepare engine + coordinators, show mini-player paused.
    /// Playback starts when the user taps `miniPlayerPlayPause` (AC4).
    /// Synchronous so episode-row taps publish `miniPlayer` before XCTest post-tap idle.
    func playEpisode(_ episode: Episode, podcastTitle: String) {
        guard let audioURL = resolveAudioURL(for: episode) else { return }

        let newEngine = PlaybackEngine(
            url: audioURL,
            title: episode.title,
            artist: podcastTitle
        )
        let coordinator = PlaybackCoordinator(
            pipeline: InstantEpisodeAnalyzer(),
            engine: newEngine
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

        // Fixture Library play skips analysis; production may prepare when cleaning applies.
        if !FixtureLibrary.isEnabled && !FixtureLibrary.isEmptyEnabled {
            Task { @MainActor in
                try? await coordinator.preparePlayback(
                    episode: EpisodeIdentity(id: episode.id),
                    audioURL: audioURL,
                    targetWords: []
                )
            }
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
        if FixtureLibrary.isEnabled || FixtureLibrary.isEmptyEnabled {
            return FixtureAudio.bundledURL()
        }
        let resolver = PlaybackSourceResolver(
            downloadsDirectory: DownloadPaths.productionDownloadsDirectory
        )
        return resolver.playbackURL(for: episode)
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
            playEpisode(episode, podcastTitle: summary.title)
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
