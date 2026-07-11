//
//  RootView.swift
//  PodWash
//
//  Slice 03/06/09/13/19 — Routes fixture-mode UI tests to player, feed, settings,
//  or skip-override shells.
//

import SwiftUI

struct RootView: View {
    let persistence: PersistenceController
    let remoteCommands: RemoteCommandCoordinator

    @State private var fixtureEngine: PlaybackEngine?
    @State private var fixtureFeedViewModel: EpisodeListViewModel?
    @State private var fixtureAnalysisViewModel: AnalysisUIViewModel?
    @State private var fixtureDownloadManager: DownloadManager?
    @State private var queueStore: QueueStore?
    @State private var fixtureSettingsStore: SettingsStore?

    init(
        persistence: PersistenceController,
        remoteCommands: RemoteCommandCoordinator
    ) {
        self.persistence = persistence
        self.remoteCommands = remoteCommands
    }

    var body: some View {
        Group {
            if FixtureSkipOverride.isEnabled {
                if let fixtureEngine {
                    SkipOverridePlaybackView(engine: fixtureEngine)
                } else {
                    ProgressView()
                        .accessibilityIdentifier("playback.loading")
                }
            } else if FixtureSettings.isEnabled {
                if let fixtureSettingsStore {
                    NavigationStack {
                        SettingsView(store: fixtureSettingsStore)
                    }
                } else {
                    ProgressView()
                        .accessibilityIdentifier("settings.loading")
                }
            } else if FixtureAudio.isEnabled {
                if let fixtureEngine {
                    PlaybackControlsView(engine: fixtureEngine)
                } else {
                    ProgressView()
                        .accessibilityIdentifier("playback.loading")
                }
            } else if FixtureFeed.isEnabled || FixtureAnalysis.isEnabled || FixtureQueue.isEnabled || FixtureQueue.shouldPreserveOnLaunch {
                if let fixtureFeedViewModel, let fixtureAnalysisViewModel, let fixtureDownloadManager, let queueStore {
                    PodcastDetailView(
                        viewModel: fixtureFeedViewModel,
                        analysisViewModel: fixtureAnalysisViewModel,
                        downloadManager: fixtureDownloadManager,
                        queueStore: queueStore
                    )
                } else {
                    ProgressView()
                        .accessibilityIdentifier("feed.loading")
                }
            } else {
                ContentView()
            }
        }
        .task {
            await loadFixtureSkipOverrideIfNeeded()
            loadFixtureSettingsIfNeeded()
            await loadFixtureAudioIfNeeded()
            await loadFixtureFeedIfNeeded()
        }
    }

    private func loadFixtureSkipOverrideIfNeeded() async {
        guard FixtureSkipOverride.isEnabled, fixtureEngine == nil else { return }
        guard let url = FixtureSkipOverride.bundledURL() else { return }
        let engine = PlaybackEngine(
            url: url,
            title: FixtureSkipOverride.fixtureTitle,
            artist: FixtureSkipOverride.fixtureArtist
        )
        await engine.applySchedule(
            IntervalSchedule(intervals: [FixtureSkipOverride.stubSkipInterval])
        )
        fixtureEngine = engine
        remoteCommands.bind(engine)
        // Auto-play is started from SkipOverridePlaybackView.onAppear after the
        // skip-override callback is wired (avoids a nil-handler race at t=2.0 s).
    }

    private func loadFixtureSettingsIfNeeded() {
        guard FixtureSettings.isEnabled, fixtureSettingsStore == nil else { return }
        FixtureSettings.prepareFreshDefaults()
        fixtureSettingsStore = SettingsStore()
    }

    private func loadFixtureAudioIfNeeded() async {
        guard FixtureAudio.isEnabled, fixtureEngine == nil else { return }
        guard let url = FixtureAudio.bundledURL() else { return }
        let engine = PlaybackEngine(
            url: url,
            title: FixtureAudio.fixtureTitle,
            artist: FixtureAudio.fixtureArtist
        )
        fixtureEngine = engine
        remoteCommands.bind(engine)
    }

    private func loadFixtureFeedIfNeeded() async {
        guard FixtureFeed.isEnabled || FixtureAnalysis.isEnabled || FixtureQueue.isEnabled || FixtureQueue.shouldPreserveOnLaunch else { return }
        guard fixtureFeedViewModel == nil else { return }

        FixtureDownload.clearDownloadsDirectoryIfNeeded()

        let context = persistence.viewContext
        let store = PodcastStore(context: context)
        let feedViewModel = EpisodeListViewModel(parser: RSSParser(), store: store)
        let cleaningStore = CleaningToggleStore(context: context)
        let analysisViewModel = AnalysisUIViewModel(
            store: CleaningToggleStoreAdapter(cleaningStore),
            analyzer: InstantEpisodeAnalyzer(),
            autoAnalyzeOnEpisodeEnable: FixtureAnalysis.isEnabled
        )
        let downloadStateStore = DownloadStateStore(context: context)
        let downloadManager = DownloadManager(
            downloadsDirectory: DownloadPaths.productionDownloadsDirectory,
            stateStore: InMemoryDownloadStateStore(backing: downloadStateStore)
        )
        let queue = QueueStore(context: context)
        if FixtureQueue.shouldResetOnLaunch {
            try? queue.clear()
        }

        fixtureFeedViewModel = feedViewModel
        fixtureAnalysisViewModel = analysisViewModel
        fixtureDownloadManager = downloadManager
        queueStore = queue

        guard let data = FixtureFeed.bundledData() else { return }
        await feedViewModel.load(data: data)
    }
}
