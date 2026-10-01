//
//  PreparationShelfView.swift
//  PodWash
//

import SwiftUI

/// A compact entry point to the listener's upcoming playback queue.
struct QueueStatusButton: View {
    let presentation: QueuePresentation
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                Text("Queue")
                    .fontWeight(.semibold)
                Text(statusText)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("queueButton")
        .accessibilityLabel("Queue")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Shows upcoming episodes and their preparation status.")
    }

    private var statusText: String {
        if let active = presentation.activeStatus { return active.text }
        return presentation.upNext.isEmpty ? "Empty" : "\(presentation.upNext.count) Up Next"
    }

    private var accessibilityValue: String {
        if let active = presentation.activeStatus { return active.accessibilityValue }
        return "\(presentation.upNext.count) up next"
    }
}
