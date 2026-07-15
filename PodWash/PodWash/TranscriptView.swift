//
//  TranscriptView.swift
//  PodWash
//
//  Slice 26 — Scrollable transcript sheet (slice-26-ux.md).
//

import SwiftUI

struct TranscriptView: View {
    let viewModel: TranscriptViewModel
    var onClose: (() -> Void)? = nil

    @State private var didAutoScroll = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        aggregateHosts

                        FlowTranscriptWords(words: viewModel.words)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(BrandTheme.surface)
                .onAppear {
                    guard !didAutoScroll else { return }
                    didAutoScroll = true
                    guard viewModel.scrollAnchorSeconds > 0 || viewModel.scrollAnchorIndex > 0 else { return }
                    DispatchQueue.main.async {
                        withAnimation {
                            proxy.scrollTo(viewModel.scrollAnchorIndex, anchor: .center)
                        }
                    }
                }
            }
            .navigationTitle("Transcript")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        onClose?()
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcript.view")
        .accessibilityLabel("Transcript")
    }

    @ViewBuilder
    private var aggregateHosts: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("transcript.wordCount")
                .accessibilityLabel("Word count")
                .accessibilityValue("\(viewModel.wordCount)")

            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("transcript.listenedCount")
                .accessibilityLabel("Listened word count")
                .accessibilityValue("\(viewModel.listenedCount)")

            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("transcript.skippedAdCount")
                .accessibilityLabel("Skipped ad word count")
                .accessibilityValue("\(viewModel.skippedAdCount)")

            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("transcript.scrollAnchor")
                .accessibilityLabel("Transcript scroll position")
                .accessibilityValue("\(viewModel.scrollAnchorSeconds)")
                .accessibilityHint("Seconds position scrolled to on open.")
        }
        .accessibilityElement(children: .contain)
        .frame(width: 1, height: 1)
        .opacity(0.01)
        .allowsHitTesting(false)
    }
}

/// Simple wrapping flow of transcript words.
private struct FlowTranscriptWords: View {
    let words: [TranscriptWordDisplay]

    var body: some View {
        // LazyVStack of rows keeps ScrollViewReader ids stable without a custom layout.
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(words, id: \.index) { display in
                Text(display.word.word)
                    .font(.body)
                    .foregroundStyle(foreground(for: display))
                    .id(display.index)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("transcript.word_\(display.index)")
                    .accessibilityLabel(display.word.word)
                    .accessibilityValue(accessibilityValue(for: display))
            }
        }
    }

    private func foreground(for display: TranscriptWordDisplay) -> Color {
        if display.skippedAd {
            return BrandTheme.accent
        }
        if display.listened {
            return BrandTheme.onSurface.opacity(0.6)
        }
        return BrandTheme.onSurface
    }

    private func accessibilityValue(for display: TranscriptWordDisplay) -> String {
        if display.skippedAd { return "skippedAd" }
        if display.listened { return "listened" }
        return ""
    }
}
