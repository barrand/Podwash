//
//  PodcastDetailView.swift
//  PodWash
//
//  Slice 06/11 — Podcast header + feed states + up-next queue (slice-06-ux, slice-11-queue-resume-ux).
//

import SwiftUI

struct PodcastDetailView: View {
    @Bindable var viewModel: EpisodeListViewModel
    @Bindable var analysisViewModel: AnalysisUIViewModel
    var downloadManager: DownloadManager
    var queueStore: QueueStore
    /// Slice 23 — episode row tap starts playback in the app shell (nil in exclusive fixtures).
    var onPlayEpisode: ((Episode) -> Void)? = nil
    /// Slice 26 — transcript affordance gate + present action.
    var transcriptExists: ((String) -> Bool)? = nil
    var onViewTranscript: ((String) -> Void)? = nil
    var transcriptAffordanceGeneration: Int = 0
    @State private var queueRevision = 0
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
        let _ = queueRevision
        let _ = transcriptAffordanceGeneration
        return VStack(alignment: .leading, spacing: 0) {
            podcastHeader(feed)
            upNextSection(feed: feed)
            EpisodeListView(
                feed: feed,
                analysisViewModel: analysisViewModel,
                downloadManager: downloadManager,
                queueStore: queueStore,
                onQueueChanged: { queueRevision += 1 },
                onPlayEpisode: onPlayEpisode,
                transcriptExists: transcriptExists,
                onViewTranscript: onViewTranscript,
                transcriptAffordanceGeneration: transcriptAffordanceGeneration
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Prefer list height over header intrinsic size when the window is short
            // (UITest sims often launch landscape; without this episodeList collapses
            // to ~0pt and episodeCell_* exists but is not hittable).
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

    private func upNextSection(feed: PodcastFeed) -> some View {
        let ids = queueStore.queueEpisodeIDs()
        let titleByID = Dictionary(uniqueKeysWithValues: feed.episodes.map { ($0.id, $0.title) })
        let sectionSpacing: CGFloat = isCompactHeight ? 4 : 8
        let topPad: CGFloat = isCompactHeight ? 2 : 8
        let emptyBottomPad: CGFloat = isCompactHeight ? 2 : 8
        return VStack(alignment: .leading, spacing: sectionSpacing) {
            Text("Up Next")
                .font(.headline)
                .padding(.horizontal)
                .padding(.top, topPad)

            if ids.isEmpty {
                Text("Nothing queued")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, emptyBottomPad)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("queueEmpty")
                    .accessibilityLabel("Nothing queued")
            }

            VStack(spacing: 0) {
                ForEach(Array(ids.enumerated()), id: \.element) { index, episodeID in
                    HStack {
                        Text(titleByID[episodeID] ?? episodeID)
                            .lineLimit(2)
                        Spacer()
                        Button("Remove") {
                            try? queueStore.remove(episodeID)
                            queueRevision += 1
                        }
                        .accessibilityIdentifier("queueRemoveButton_\(index)")
                        .accessibilityLabel("Remove from queue")
                        .accessibilityValue(episodeID)
                        .accessibilityHint("Removes this episode from up next.")
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("queueCell_\(index)")
                    .accessibilityLabel(titleByID[episodeID] ?? episodeID)
                    .accessibilityValue(episodeID)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("queueList")
            .accessibilityLabel("Up next")
            .accessibilityValue("\(ids.count)")
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
