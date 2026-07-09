//
//  PodcastDetailView.swift
//  PodWash
//
//  Slice 06 — Podcast header + feed states (slice-06-ux.md).
//

import SwiftUI

struct PodcastDetailView: View {
    @Bindable var viewModel: EpisodeListViewModel

    var body: some View {
        Group {
            switch viewModel.phase {
            case .idle, .loading:
                loadingView
            case .failed(let error):
                errorView(error)
            case .loaded(let feed):
                if feed.episodes.isEmpty {
                    emptyView(feed)
                } else {
                    loadedView(feed)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading episodes…")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("feed.loading")
        .accessibilityLabel("Loading episodes")
    }

    private func loadedView(_ feed: PodcastFeed) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            podcastHeader(feed)
            EpisodeListView(feed: feed)
        }
    }

    private func emptyView(_ feed: PodcastFeed) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            podcastHeader(feed)
            Text("No episodes yet")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("feed.empty")
                .accessibilityLabel("No episodes")
        }
    }

    private func errorView(_ error: RSSParserError) -> some View {
        VStack(spacing: 16) {
            Text("Podcast")
                .font(.headline)
            Text(errorSummary(for: error))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Retry") {}
                .accessibilityIdentifier("feed.retry")
                .accessibilityLabel("Retry")
        }
        .padding()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("feed.error")
        .accessibilityLabel("Feed error")
        .accessibilityValue(errorAccessibilityValue(for: error))
    }

    private func podcastHeader(_ feed: PodcastFeed) -> some View {
        HStack(alignment: .top, spacing: 12) {
            artworkView(feed.artworkURL)
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(feed.title)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .accessibilityHidden(true)

                if let description = feed.description {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("podcastTitle")
            .accessibilityLabel("Podcast title")
            .accessibilityValue(feed.title)

            Spacer(minLength: 0)
        }
        .padding()
    }

    @ViewBuilder
    private func artworkView(_ artworkURL: URL?) -> some View {
        if artworkURL != nil {
            Image(systemName: "photo.artframe")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("podcastArtwork")
                .accessibilityLabel("Podcast artwork")
                .accessibilityValue("loaded")
        } else {
            Image(systemName: "mic.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("podcastArtwork")
                .accessibilityLabel("Podcast artwork")
                .accessibilityValue("placeholder")
        }
    }

    private func errorSummary(for error: RSSParserError) -> String {
        switch error {
        case .networkFailure:
            "Could not load the feed. Check your connection and try again."
        case .malformedFeed:
            "This feed could not be parsed."
        }
    }

    private func errorAccessibilityValue(for error: RSSParserError) -> String {
        switch error {
        case .networkFailure:
            "networkFailure"
        case .malformedFeed:
            "parseFailure"
        }
    }
}
