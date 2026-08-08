//
//  QueueTabView.swift
//  PodWash
//

import SwiftUI

struct QueueTabView: View {
    let presentation: QueuePresentation
    let onMove: (IndexSet, Int) -> Void
    let onPlayNow: (String) -> Void
    let onRemoveFromUpNext: (String) -> Void
    let onRemoveDownload: (String) -> Void
    let onAddToUpNext: (String) -> Void
    let onRetry: (String) -> Void
    let onPlayWithAds: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(summaryText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Up Next") {
                    if presentation.upNext.isEmpty {
                        ContentUnavailableView(
                            "Nothing Up Next",
                            systemImage: "text.line.first.and.arrowtriangle.forward",
                            description: Text("Add episodes from a podcast to prepare them for playback.")
                        )
                        .accessibilityIdentifier("queueEmpty")
                    } else {
                        ForEach(presentation.upNext) { item in
                            QueueEpisodeRow(item: item, onPlayNow: onPlayNow, onRetry: onRetry, onPlayWithAds: onPlayWithAds)
                                .contextMenu {
                                    Button("Play now", systemImage: "play.fill") { onPlayNow(item.episodeID) }
                                    Button("Remove from Up Next", systemImage: "text.badge.minus") { onRemoveFromUpNext(item.episodeID) }
                                    Button("Remove download", systemImage: "trash", role: .destructive) { onRemoveDownload(item.episodeID) }
                                }
                        }
                        .onMove(perform: onMove)
                    }
                }

                Section("Ready to Play") {
                    if presentation.readyToPlay.isEmpty {
                        Text("Prepared downloads will appear here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(presentation.readyToPlay) { item in
                        QueueEpisodeRow(item: item, onPlayNow: onPlayNow, onRetry: onRetry, onPlayWithAds: onPlayWithAds)
                            .contextMenu {
                                Button("Play now", systemImage: "play.fill") { onPlayNow(item.episodeID) }
                                Button("Add to Up Next", systemImage: "text.badge.plus") { onAddToUpNext(item.episodeID) }
                                Button("Remove download", systemImage: "trash", role: .destructive) { onRemoveDownload(item.episodeID) }
                            }
                    }
                }
            }
            // Up Next permanently uses the native move affordance; no mode switch or
            // decorative handle is required for a listener to reorder it.
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Queue")
            .accessibilityIdentifier("queueTab")
        }
    }

    private var summaryText: String {
        "\(presentation.upNext.count) Up Next · \(presentation.readyToPlay.count) ready"
            + (presentation.preparingCount > 0 ? " · \(presentation.preparingCount) preparing" : "")
    }
}

private struct QueueEpisodeRow: View {
    let item: QueueEpisodePresentation
    let onPlayNow: (String) -> Void
    let onRetry: (String) -> Void
    let onPlayWithAds: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(item.title).fontWeight(.semibold)
                Spacer()
                Text(item.statusText).foregroundStyle(.secondary)
            }
            Text(item.podcastTitle).font(.caption).foregroundStyle(.secondary)
            if let progress = item.progress {
                ProgressView(value: progress)
            }
            if item.job?.stage == .adCheckDelayed || item.job?.stage == .needsAttention {
                HStack {
                    Button("Retry now") { onRetry(item.episodeID) }
                    Button("Play with ads") { onPlayWithAds(item.episodeID) }
                }
                .buttonStyle(.bordered)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onPlayNow(item.episodeID) }
        .accessibilityIdentifier("queueEpisode_\(item.episodeID)")
        .accessibilityLabel(item.title)
        .accessibilityValue(item.statusText)
        .accessibilityHint("Plays now and keeps the current episode next.")
    }
}
