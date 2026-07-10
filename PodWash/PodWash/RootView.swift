//
//  RootView.swift
//  PodWash
//
//  Slice 03/06/09 — Routes fixture-mode UI tests to player or episode-list shells.
//

import SwiftUI

struct RootView: View {
    let persistence: PersistenceController

    @State private var fixtureEngine: PlaybackEngine?
    @State private var fixtureFeedViewModel: EpisodeListViewModel?
    @State private var fixtureAnalysisViewModel: AnalysisUIViewModel?
    @State private var fixtureDownloadManager: DownloadManager?
    @State private var queueStore: QueueStore?

    init(persistence: PersistenceController) {
        self.persistence = persistence
    }

    var body: some View {
        Group {
            if FixtureAudio.isEnabled {
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
            await loadFixtureAudioIfNeeded()
            await loadFixtureFeedIfNeeded()
        }
    }

    private func loadFixtureAudioIfNeeded() async {
        guard FixtureAudio.isEnabled, fixtureEngine == nil else { return }
        guard let url = FixtureAudio.bundledURL() else { return }
        fixtureEngine = PlaybackEngine(
            url: url,
            title: FixtureAudio.fixtureTitle,
            artist: FixtureAudio.fixtureArtist
        )
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
