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
    let rowSnapshot: (String) -> EpisodeRowSnapshot?
    let rowBindings: (String) -> EpisodeRowBindings
    let onClearUpNext: () -> Void

    @State private var isReordering = false

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
                    if !isReordering {
                        Button(role: .destructive) {
                            rowBindings(item.episodeID).perform(.removeFromUpNext)
                        } label: { Label("Remove", systemImage: "trash") }
                    }
                }
        }
    }
}
