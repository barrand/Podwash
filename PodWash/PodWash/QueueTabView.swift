//
//  QueueTabView.swift
//  PodWash
//

import SwiftUI

/// Up Next is deliberately the only collection on this screen. Downloads are
/// episode state, not a second queue.
struct QueueTabView: View {
    let presentation: QueuePresentation
    let bottomContentClearance: CGFloat
    let onMove: (IndexSet, Int) -> Void
    let onDownload: (String) -> Void
    let onPrepare: (String) -> Void
    let onPlay: (String) -> Void
    let onMoveToTop: (String) -> Void
    let onRemoveFromUpNext: (String) -> QueueUndoSnapshot
    let onMarkPlayed: (String) -> QueueUndoSnapshot
    let onRestore: (QueueUndoSnapshot) -> Void
    let onCommitPlayed: (QueueUndoSnapshot) -> Void
    let onRemoveDownload: (String) -> Void
    let onClearUpNext: () -> [String]
    let onRestoreUpNext: ([String]) -> Void
    let onRetry: (String) -> Void
    let onPlayWithoutAdSkipping: (String) -> Void
    let onPlayOriginalAudio: (String) -> Void

    @State private var isReordering = false
    @State private var undo: QueueUndo?
    @State private var undoTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List { upNextSection }
                .listStyle(.plain)
                .environment(\.editMode, .constant(isReordering ? .active : .inactive))
                .navigationTitle("Queue")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if presentation.upNext.count > 1 {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(isReordering ? "Done" : "Reorder") { isReordering.toggle() }
                                .accessibilityIdentifier("queueReorder")
                        }
                    }
                }
                .accessibilityIdentifier("queueTab")
                .safeAreaPadding(.bottom, bottomContentClearance)
                .overlay(alignment: .bottom) {
                    if let undo {
                        QueueUndoToast(message: undo.message) {
                            undoTask?.cancel(); undo.action(); self.undo = nil
                        }
                        .padding(.bottom, bottomContentClearance + 12)
                    }
                }
                .onDisappear { isReordering = false }
        }
    }

    private var upNextSection: some View {
        Section {
            if presentation.upNext.isEmpty {
                ContentUnavailableView(
                    "Nothing Up Next",
                    systemImage: "text.line.first.and.arrowtriangle.forward",
                    description: Text("Add episodes from a podcast to listen later.")
                )
                .accessibilityIdentifier("queueEmpty")
            } else {
                ForEach(presentation.upNext) { item in row(item) }
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
                } label: { Image(systemName: "ellipsis.circle") }
                .disabled(presentation.upNext.isEmpty)
                .accessibilityLabel("Up Next actions")
            }
        }
    }

    private func row(_ item: QueueEpisodePresentation) -> some View {
        EpisodeRowView(
            episodeID: item.episodeID,
            title: item.title,
            presentation: EpisodeRowPresentationMapper.map(item.availability),
            context: .queue(podcastTitle: item.podcastTitle),
            isReordering: isReordering,
            actions: EpisodeRowActions(
                download: { onDownload(item.episodeID) },
                prepare: { onPrepare(item.episodeID) },
                retry: { onRetry(item.episodeID) },
                play: { onPlay(item.episodeID) }
            ),
            moreMenu: { AnyView(queueMoreMenu(item)) }
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !isReordering {
                Button(role: .destructive) {
                    let snapshot = onRemoveFromUpNext(item.episodeID)
                    showUndo("Removed from Up Next") { onRestore(snapshot) }
                } label: { Label("Remove", systemImage: "trash") }
            }
        }
    }

    @ViewBuilder private func queueMoreMenu(_ item: QueueEpisodePresentation) -> some View {
        if case .waitingToDownload = item.availability.readiness {
            Button("Cancel Download", systemImage: "xmark") { onRemoveDownload(item.episodeID) }
        }
        if case .waitingToPrepare = item.availability.readiness {
            Button("Cancel Preparation", systemImage: "xmark") { onRemoveDownload(item.episodeID) }
        }
        if case .adCheckDelayed = item.availability.readiness {
            Button("Retry now", systemImage: "arrow.clockwise") { onRetry(item.episodeID) }
            if item.availability.hasLocalAudio {
                Button("Play without ad skipping", systemImage: "play") { onPlayWithoutAdSkipping(item.episodeID) }
            }
        }
        if case .needsAttention = item.availability.readiness, item.availability.hasLocalAudio {
            Button("Play original audio", systemImage: "play") { onPlayOriginalAudio(item.episodeID) }
        }
        Button("Move to Top", systemImage: "arrow.up.to.line") { onMoveToTop(item.episodeID) }
        Button("Mark as Played", systemImage: "checkmark.circle") {
            let snapshot = onMarkPlayed(item.episodeID)
            showUndo("Marked as played", action: { onRestore(snapshot) }, onExpire: { onCommitPlayed(snapshot) })
        }
        Button("Remove from Up Next", systemImage: "text.badge.minus", role: .destructive) {
            let snapshot = onRemoveFromUpNext(item.episodeID)
            showUndo("Removed from Up Next") { onRestore(snapshot) }
        }
        if item.availability.hasLocalAudio {
            Button("Remove Download", systemImage: "trash", role: .destructive) { onRemoveDownload(item.episodeID) }
        }
    }

    private func showUndo(_ message: String, action: @escaping () -> Void, onExpire: @escaping () -> Void = {}) {
        undoTask?.cancel(); undo?.onExpire()
        undo = QueueUndo(message: message, action: action, onExpire: onExpire)
        undoTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await MainActor.run { undo?.onExpire(); undo = nil }
        }
    }
}

private struct QueueUndo { let message: String; let action: () -> Void; let onExpire: () -> Void }

private struct QueueUndoToast: View {
    let message: String; let onUndo: () -> Void
    var body: some View {
        HStack { Text(message).lineLimit(1); Spacer(); Button("Undo", action: onUndo) }
            .font(.subheadline).padding(.horizontal, 16).padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule()).padding(.horizontal)
    }
}
