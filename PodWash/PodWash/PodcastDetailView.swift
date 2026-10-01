//
//  PodcastDetailView.swift
//  PodWash
//
//  Slice 06/11 — Podcast header + feed states + up-next queue (slice-06-ux, slice-11-queue-resume-ux).
//

import SwiftUI

struct PodcastDetailView: View {
    @Bindable var viewModel: EpisodeListViewModel
    let rowSnapshot: (Episode) -> EpisodeRowSnapshot
    let rowBindings: (String) -> EpisodeRowBindings
    var episodeListRevision: Int = 0
    /// Landscape / short windows (~402pt) — keep episodeList tall enough to hit cells.
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isCompactHeight: Bool {
        verticalSizeClass == .compact
    }

    var body: some View {
        return Group {
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
        let _ = episodeListRevision
        return VStack(alignment: .leading, spacing: 0) {
            podcastHeader(feed)
            // Resolve observable state in SwiftUI's tracked render, not a later
            // UIKit datasource callback. The table receives immutable values.
            EpisodeListView(feed: feed, snapshots: feed.episodes.map(rowSnapshot),
                            bindings: rowBindings, revision: episodeListRevision)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Prefer list height over header intrinsic size when the window is short
            // (UITest sims often launch landscape; without this episodeList collapses
            // to ~0pt and visible episode controls cannot be hit).
            .layoutPriority(1)
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
        let artworkSide: CGFloat = isCompactHeight ? 48 : 72
        let stackSpacing: CGFloat = isCompactHeight ? 6 : 12
        let headerPadding: CGFloat = isCompactHeight ? 8 : 16
        return VStack(alignment: .leading, spacing: stackSpacing) {
            HStack(alignment: .top, spacing: 12) {
                artworkView(feed.artworkURL)
                    .frame(width: artworkSide, height: artworkSide)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 4) {
                    Text(feed.title)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .accessibilityHidden(true)

                    if let description = feed.description, !isCompactHeight {
                        Text(HTMLDescriptionText.attributedString(from: description))
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
        }
        .padding(headerPadding)
    }

    @ViewBuilder
    private func artworkView(_ artworkURL: URL?) -> some View {
        if let artworkURL {
            AsyncImage(url: artworkURL) { phase in
                Group {
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        detailArtworkPlaceholderIcon
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("podcastArtwork")
                .accessibilityLabel("Podcast artwork")
                .accessibilityValue(Self.artworkAccessibilityValue(for: phase))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        } else {
            detailArtworkPlaceholderIcon
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("podcastArtwork")
                .accessibilityLabel("Podcast artwork")
                .accessibilityValue("placeholder")
        }
    }

    private var detailArtworkPlaceholderIcon: some View {
        Image(systemName: "mic.circle.fill")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.secondary)
    }

    private static func artworkAccessibilityValue(for phase: AsyncImagePhase) -> String {
        if case .success = phase {
            return "loaded"
        }
        return "placeholder"
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
