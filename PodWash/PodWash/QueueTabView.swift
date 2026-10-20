//
//  QueueTabView.swift
//  PodWash
//

import SwiftUI

/// Queue combines durable manual Up Next with a read-only radio forecast.
/// Downloads remain episode state, not a second queue.
struct QueueTabView: View {
    let presentation: QueuePresentation
    let bottomContentClearance: CGFloat
    let onMove: (IndexSet, Int) -> Void
    let rowSnapshot: (String) -> EpisodeRowSnapshot?
    let rowBindings: (String) -> EpisodeRowBindings
    let onClearUpNext: () -> Void

    @State private var isReordering = false

    var body: some View {
        NavigationStack {
            List {
                upNextSection
                autoplaySection
            }
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
                .onDisappear { isReordering = false }
        }
    }

    private var upNextSection: some View {
        Section {
            if presentation.upNext.isEmpty {
                if presentation.autoplay.isEmpty {
                    ContentUnavailableView(
                        presentation.isSmartAutoplayEnabled ? "Nothing Up Next" : "Autoplay is off",
                        systemImage: "text.line.first.and.arrowtriangle.forward",
                        description: Text(presentation.isSmartAutoplayEnabled
                            ? "Add episodes from a podcast to play next."
                            : "Turn on Smart autoplay in Settings to keep listening automatically."))
                        .accessibilityIdentifier("queueEmpty")
                } else {
                    Text("Your manual queue is empty. Autoplay will continue after the current episode.")
                        .foregroundStyle(.secondary)
                }
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
                        onClearUpNext()
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .disabled(presentation.upNext.isEmpty)
                .accessibilityLabel("Up Next actions")
            }
        }
    }

    @ViewBuilder private func row(_ item: QueueEpisodePresentation) -> some View {
        if let snapshot = rowSnapshot(item.episodeID) {
            SharedEpisodeRow(snapshot: snapshot, bindings: rowBindings(item.episodeID),
                             isReordering: isReordering)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if !isReordering, item.origin == .manual {
                        Button(role: .destructive) {
                            rowBindings(item.episodeID).perform(.removeFromUpNext)
                        } label: { Label("Remove", systemImage: "trash") }
                    }
                }
        }
    }

    private var autoplaySection: some View {
        Section {
            if presentation.isSmartAutoplayEnabled {
                if presentation.autoplay.isEmpty {
                    Text("No eligible episodes are available for autoplay.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("A live forecast. These choices may change as you listen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(presentation.autoplay) { item in
                        row(item)
                            .accessibilityIdentifier("queueAutoplay_\(item.episodeID)")
                    }
                }
            } else {
                Text("Smart autoplay is off. Turn it on in Settings to continue automatically.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Autoplay after Up Next")
        }
    }
}
