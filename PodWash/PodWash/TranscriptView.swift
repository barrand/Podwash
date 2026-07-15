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

                        TranscriptParagraphsView(
                            words: viewModel.words,
                            paragraphs: TranscriptViewModel.paragraphs(
                                from: viewModel.words.map(\.word)
                            )
                        )
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

/// Sentence paragraphs with inline-wrapping words and start timestamps.
private struct TranscriptParagraphsView: View {
    let words: [TranscriptWordDisplay]
    let paragraphs: [TranscriptParagraph]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { paragraphIndex, paragraph in
                VStack(alignment: .leading, spacing: 4) {
                    Text(paragraph.formattedStartTimestamp)
                        .font(.caption)
                        .foregroundStyle(BrandTheme.onSurface.opacity(0.6))
                        .accessibilityElement(children: .ignore)
                        .accessibilityIdentifier("transcript.paragraph_\(paragraphIndex).timestamp")
                        .accessibilityLabel("Paragraph start time")
                        .accessibilityValue(paragraph.formattedStartTimestamp)

                    WrappingTranscriptWordsLayout(horizontalSpacing: 4, verticalSpacing: 4) {
                        ForEach(wordsIn(paragraph), id: \.index) { display in
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func wordsIn(_ paragraph: TranscriptParagraph) -> [TranscriptWordDisplay] {
        Array(words[paragraph.firstWordIndex ... paragraph.lastWordIndex])
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

/// Flow layout that wraps transcript word views onto multiple lines.
private struct WrappingTranscriptWordsLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }

        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                totalWidth = max(totalWidth, x - horizontalSpacing)
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            if x > 0 { x += horizontalSpacing }
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }

        totalWidth = max(totalWidth, x)
        return CGSize(width: totalWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }

        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            if x > bounds.minX { x += horizontalSpacing }
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }
    }
}
