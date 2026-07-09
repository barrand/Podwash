//
//  RootView.swift
//  PodWash
//
//  Slice 03/06 — Routes fixture-mode UI tests to player or episode-list shells.
//

import SwiftUI

struct RootView: View {
    @State private var fixtureEngine: PlaybackEngine?
    @State private var fixtureFeedViewModel: EpisodeListViewModel?

    var body: some View {
        Group {
            if FixtureAudio.isEnabled {
                if let fixtureEngine {
                    PlaybackControlsView(engine: fixtureEngine)
                } else {
                    ProgressView()
                        .accessibilityIdentifier("playback.loading")
                }
            } else if FixtureFeed.isEnabled {
                if let fixtureFeedViewModel {
                    PodcastDetailView(viewModel: fixtureFeedViewModel)
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
        guard FixtureFeed.isEnabled, fixtureFeedViewModel == nil else { return }
        let store = InMemoryPodcastStore()
        let viewModel = EpisodeListViewModel(parser: RSSParser(), store: store)
        fixtureFeedViewModel = viewModel
        guard let data = FixtureFeed.bundledData() else { return }
        await viewModel.load(data: data)
    }
}
