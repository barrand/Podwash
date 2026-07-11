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
    @State private var queueRevision = 0

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
        return VStack(alignment: .leading, spacing: 0) {
            podcastHeader(feed)
            upNextSection(feed: feed)
            EpisodeListView(
                feed: feed,
                analysisViewModel: analysisViewModel,
                downloadManager: downloadManager,
                queueStore: queueStore,
                onQueueChanged: { queueRevision += 1 }
            )
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
        return VStack(alignment: .leading, spacing: 8) {
            Text("Up Next")
                .font(.headline)
                .padding(.horizontal)
                .padding(.top, 8)

            if ids.isEmpty {
                Text("Nothing queued")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
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

            VStack(alignment: .trailing, spacing: 6) {
                Toggle(isOn: channelCleaningBinding) {
                    Text("Clean channel")
                        .font(.caption)
                }
                .labelsHidden()
                .accessibilityIdentifier("channelCleaningToggle")
                .accessibilityLabel("Channel cleaning")
                .accessibilityValue(analysisViewModel.isChannelCleaningEnabled ? "on" : "off")

                Toggle(isOn: channelUnrelatedContentBinding) {
                    Text("Skip unrelated on channel")
                        .font(.caption)
                }
                .labelsHidden()
                .accessibilityIdentifier("channelUnrelatedContentToggle")
                .accessibilityLabel("Channel unrelated content")
                .accessibilityValue(analysisViewModel.isChannelUnrelatedContentEnabled ? "1" : "0")
                .accessibilityHint("Enables unrelated-content handling for this podcast when on.")

                if analysisViewModel.isChannelCleaningEnabled {
                    Text("Channel on")
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                        .accessibilityElement(children: .ignore)
                        .accessibilityIdentifier("cleaningBadge_channelOn")
                        .accessibilityLabel("Channel cleaning on")
                }
            }
        }
        .padding()
    }

    private var channelCleaningBinding: Binding<Bool> {
        Binding(
            get: { analysisViewModel.isChannelCleaningEnabled },
            set: { analysisViewModel.setChannelCleaning($0) }
        )
    }

    private var channelUnrelatedContentBinding: Binding<Bool> {
        Binding(
            get: { analysisViewModel.isChannelUnrelatedContentEnabled },
            set: { analysisViewModel.setChannelUnrelatedContent($0) }
        )
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
