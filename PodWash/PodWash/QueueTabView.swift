//
//  QueueTabView.swift
//  PodWash
//

import SwiftUI

struct QueueTabView: View {
    let presentation: QueuePresentation
    let bottomContentClearance: CGFloat
    let onMove: (IndexSet, Int) -> Void
    let onPlayNow: (String) -> Void
    let onMoveToTop: (String) -> Void
    let onRemoveFromUpNext: (String) -> QueueUndoSnapshot
    let onMarkPlayed: (String) -> QueueUndoSnapshot
    let onRestore: (QueueUndoSnapshot) -> Void
    let onCommitPlayed: (QueueUndoSnapshot) -> Void
    let onRemoveDownload: (String) -> Void
    let onAddToUpNext: (String) -> Void
    let onClearUpNext: () -> [String]
    let onRestoreUpNext: ([String]) -> Void
    let onRetry: (String) -> Void
    let onPlayWithAds: (String) -> Void

    @AppStorage("queue.downloadsExpanded") private var downloadsExpanded = false
    @State private var isReordering = false
    @State private var undo: QueueUndo?
    @State private var undoTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                upNextSection
                downloadsSection
            }
            .listStyle(.plain)
            .environment(\.editMode, .constant(isReordering ? .active : .inactive))
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if presentation.upNext.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(isReordering ? "Done" : "Reorder") {
                            isReordering.toggle()
                        }
                        .accessibilityIdentifier("queueReorder")
                    }
                }
            }
            .accessibilityIdentifier("queueTab")
            .safeAreaPadding(.bottom, bottomContentClearance)
            .overlay(alignment: .bottom) {
                if let undo {
                    QueueUndoToast(message: undo.message) {
                        undoTask?.cancel()
                        undo.action()
                        self.undo = nil
                    }
                    .padding(.bottom, bottomContentClearance + 12)
                }
            }
            .onDisappear {
                isReordering = false
            }
        }
    }

    private var upNextSection: some View {
        Section {
            if presentation.upNext.isEmpty {
                ContentUnavailableView(
                    "Nothing Up Next",
                    systemImage: "text.line.first.and.arrowtriangle.forward",
                    description: Text("Add episodes from a podcast to prepare them for playback.")
                )
                .accessibilityIdentifier("queueEmpty")
            } else {
                ForEach(presentation.upNext) { item in
                    upNextRow(item)
                }
                .onMove(perform: onMove)
            }
        } header: {
            HStack {
                Text("Up Next · \(presentation.upNext.count)")
                Spacer()
                Menu {
                    Button("Clear Up Next", systemImage: "trash", role: .destructive) {
                        let ids = onClearUpNext()
                        guard !ids.isEmpty else { return }
                        showUndo("Cleared Up Next") { onRestoreUpNext(ids) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(presentation.upNext.isEmpty)
                .accessibilityLabel("Up Next actions")
            }
        }
    }

    private func upNextRow(_ item: QueueEpisodePresentation) -> some View {
        QueueEpisodeRow(
            item: item,
            isReordering: isReordering,
            onPlay: isReordering ? nil : { onPlayNow(item.episodeID) },
            onRetry: onRetry,
            onPlayWithAds: onPlayWithAds
        ) {
            Button("Play now", systemImage: "play.fill") { onPlayNow(item.episodeID) }
            Button("Move to top", systemImage: "arrow.up.to.line") { onMoveToTop(item.episodeID) }
            Button("Mark as played", systemImage: "checkmark.circle") {
                let snapshot = onMarkPlayed(item.episodeID)
                showUndo("Marked as played", action: { onRestore(snapshot) }, onExpire: { onCommitPlayed(snapshot) })
            }
            Button("Remove from Up Next", systemImage: "text.badge.minus", role: .destructive) {
                let snapshot = onRemoveFromUpNext(item.episodeID)
                showUndo("Removed from Up Next") { onRestore(snapshot) }
            }
            if item.isDownloaded || item.activity != nil {
                Button("Remove download", systemImage: "trash", role: .destructive) { onRemoveDownload(item.episodeID) }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !isReordering {
                Button(role: .destructive) {
                    let snapshot = onRemoveFromUpNext(item.episodeID)
                    showUndo("Removed from Up Next") { onRestore(snapshot) }
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
    }

    private var downloadsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $downloadsExpanded) {
                if presentation.downloads.isEmpty {
                    Text("Downloaded episodes will appear here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(presentation.downloads) { item in
                        QueueEpisodeRow(item: item, isReordering: false, onPlay: { onPlayNow(item.episodeID) }, onRetry: onRetry, onPlayWithAds: onPlayWithAds) {
                            Button("Play now", systemImage: "play.fill") { onPlayNow(item.episodeID) }
                            Button("Add to Up Next", systemImage: "text.badge.plus") { onAddToUpNext(item.episodeID) }
                            Button("Mark as played", systemImage: "checkmark.circle") {
                                let snapshot = onMarkPlayed(item.episodeID)
                                showUndo("Marked as played", action: { onRestore(snapshot) }, onExpire: { onCommitPlayed(snapshot) })
                            }
                            Button("Remove download", systemImage: "trash", role: .destructive) { onRemoveDownload(item.episodeID) }
                        }
                    }
                }
            } label: {
                Text("Downloads · \(presentation.downloads.count)")
            }
            .accessibilityIdentifier("queueDownloads")
        }
    }

    private func showUndo(_ message: String, action: @escaping () -> Void, onExpire: @escaping () -> Void = {}) {
        undoTask?.cancel()
        undo?.onExpire()
        undo = QueueUndo(message: message, action: action, onExpire: onExpire)
        undoTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                undo?.onExpire()
                undo = nil
            }
        }
    }
}

private struct QueueEpisodeRow<MoreActions: View>: View {
    let item: QueueEpisodePresentation
    let isReordering: Bool
    let onPlay: (() -> Void)?
    let onRetry: (String) -> Void
    let onPlayWithAds: (String) -> Void
    @ViewBuilder let moreActions: () -> MoreActions

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(metadataText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let progress = item.activity?.progress {
                    ProgressView(value: progress)
                }
                if item.activity == .delayed || item.activity == .needsAttention {
                    HStack {
                        Button("Retry now") { onRetry(item.episodeID) }
                        Button("Play with ads") { onPlayWithAds(item.episodeID) }
                    }
                    .buttonStyle(.bordered)
                }
            }
            Menu(content: moreActions) {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 44, height: 44, alignment: .top)
            }
            .disabled(isReordering)
            .accessibilityLabel("More actions")
        }
        .contentShape(Rectangle())
        .onTapGesture { onPlay?() }
        .accessibilityIdentifier("queueEpisode_\(item.episodeID)")
        .accessibilityLabel(item.title)
        .accessibilityValue(metadataText)
        .accessibilityHint(isReordering ? "Reorder mode" : "Plays now and keeps the current episode next.")
    }

    private var metadataText: String {
        [item.podcastTitle, item.activity?.text].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct QueueUndo {
    let message: String
    let action: () -> Void
    let onExpire: () -> Void
}

private struct QueueUndoToast: View {
    let message: String
    let onUndo: () -> Void

    var body: some View {
        HStack {
            Text(message).lineLimit(1)
            Spacer()
            Button("Undo", action: onUndo)
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal)
    }
}
