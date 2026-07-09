//
//  RootView.swift
//  PodWash
//
//  Slice 03/06/09 — Routes fixture-mode UI tests to player or episode-list shells.
//

import SwiftUI

struct RootView: View {
    @State private var fixtureEngine: PlaybackEngine?
    @State private var fixtureFeedViewModel: EpisodeListViewModel?
    @State private var fixtureAnalysisViewModel: AnalysisUIViewModel?

    var body: some View {
        Group {
            if FixtureAudio.isEnabled {
                if let fixtureEngine {
                    PlaybackControlsView(engine: fixtureEngine)
                } else {
                    ProgressView()
                        .accessibilityIdentifier("playback.loading")
                }
            } else if FixtureFeed.isEnabled || FixtureAnalysis.isEnabled {
                if let fixtureFeedViewModel, let fixtureAnalysisViewModel {
                    PodcastDetailView(
                        viewModel: fixtureFeedViewModel,
                        analysisViewModel: fixtureAnalysisViewModel
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
        guard FixtureFeed.isEnabled || FixtureAnalysis.isEnabled else { return }
        guard fixtureFeedViewModel == nil else { return }

        let store = InMemoryPodcastStore()
        let feedViewModel = EpisodeListViewModel(parser: RSSParser(), store: store)
        let cleaningStore = InMemoryCleaningToggleStore()
        let analysisViewModel = AnalysisUIViewModel(
            store: cleaningStore,
            analyzer: InstantEpisodeAnalyzer(),
            autoAnalyzeOnEpisodeEnable: FixtureAnalysis.isEnabled
        )

        fixtureFeedViewModel = feedViewModel
        fixtureAnalysisViewModel = analysisViewModel

        guard let data = FixtureFeed.bundledData() else { return }
        await feedViewModel.load(data: data)
    }
}
