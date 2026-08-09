//
//  TranscriptView.swift
//  PodWash
//
//  Slice 26 — Scrollable transcript sheet (slice-26-ux.md).
//  Slice 32 — Live karaoke highlight + follow / snap-back (ADR-028, slice-32-ux.md).
//

import AVFoundation
import SwiftUI

struct TranscriptView: View {
    let viewModel: TranscriptViewModel
    /// Live playhead while the sheet is open (now-playing engine). Nil → freeze at open-time resume.
    var playbackEngine: PlaybackEngine? = nil
    /// Open-time resume seconds used when no live engine is available.
    var openPlaybackPosition: TimeInterval = 0
    /// Space occupied by persistent playback chrome outside this view.
    var bottomControlClearance: CGFloat = 0
    var onClose: (() -> Void)? = nil

    @State private var didInitialAlignment = false
    @State private var isFollowModeOn = true
    @State private var lastFollowedBlockIndex: Int?
    @State private var activeWordIndex: Int = 0
    /// The live clock used for the listened (grey) treatment. Keeping this in
    /// state makes the visible words update with the same cadence as karaoke.
    @State private var playbackPosition: TimeInterval = 0

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            aggregateHosts
                                .padding(.bottom, 12)

                            ForEach(viewModel.renderBlocks) { block in
                                TranscriptRenderBlockView(
                                    block: block,
                                    words: viewModel.words,
                                    paragraphs: viewModel.paragraphs,
                                    activeWordIndex: activeWordIndex,
                                    playbackPosition: playbackPosition
                                )
                                .id(block.id)
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(BrandTheme.surface)
                    // A real drag is the only thing that suspends following. Scroll
                    // phase callbacks also report proxy-driven animation, which made
                    // the recovery button race with its own scroll request.
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 1)
                            .onEnded { _ in noteUserScrollInteraction() }
                    )
                    .onAppear {
                        alignToLiveWordOnOpen(proxy: proxy)
                    }
                    .onChange(of: activeWordIndex) { _, newIndex in
                        followScrollIfNeeded(to: newIndex, proxy: proxy)
                    }

                    if !isFollowModeOn {
                        snapToFollowButton(activeIndex: activeWordIndex, proxy: proxy)
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
        .background {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let _ = playbackEngine?.uiRefreshToken
                let position = livePlayheadSeconds
                let index = computedActiveWordIndex
                Color.clear
                    .accessibilityHidden(true)
                    .onChange(of: index) { _, newIndex in
                        activeWordIndex = newIndex
                    }
                    .onChange(of: position) { _, newPosition in
                        playbackPosition = newPosition
                    }
                    .onAppear {
                        activeWordIndex = index
                        playbackPosition = position
                    }
            }
        }
    }

    private var computedActiveWordIndex: Int {
        TranscriptViewModel.activeWordIndex(
            transcript: viewModel.timedWords,
            playhead: livePlayheadSeconds
        )
    }

    private var livePlayheadSeconds: TimeInterval {
        if let engine = playbackEngine {
            // `currentTime` is the observable, skip-aware engine clock. Reading
            // AVPlayer directly can lag an in-flight seek or skip landing.
            return engine.currentTime
        }
        return openPlaybackPosition
    }

    private func noteUserScrollInteraction() {
        isFollowModeOn = false
    }

    private func alignToLiveWordOnOpen(proxy: ScrollViewProxy) {
        guard !didInitialAlignment else { return }
        didInitialAlignment = true

        let index = computedActiveWordIndex
        activeWordIndex = index
        scrollToRenderBlock(containing: index, proxy: proxy, animated: false)
    }

    private func followScrollIfNeeded(to activeIndex: Int, proxy: ScrollViewProxy) {
        guard isFollowModeOn else { return }
        guard didInitialAlignment else { return }
        guard let blockIndex = viewModel.renderBlockIndex(containingWordAt: activeIndex) else { return }
        guard lastFollowedBlockIndex != blockIndex else { return }
        scrollToRenderBlock(at: blockIndex, proxy: proxy, animated: true)
    }

    private func snapToFollow(activeIndex: Int, proxy: ScrollViewProxy) {
        isFollowModeOn = true
        scrollToRenderBlock(containing: activeIndex, proxy: proxy, animated: true)
    }

    private func scrollToRenderBlock(
        containing wordIndex: Int,
        proxy: ScrollViewProxy,
        animated: Bool
    ) {
        guard let blockIndex = viewModel.renderBlockIndex(containingWordAt: wordIndex) else { return }
        scrollToRenderBlock(at: blockIndex, proxy: proxy, animated: animated)
    }

    private func scrollToRenderBlock(at blockIndex: Int, proxy: ScrollViewProxy, animated: Bool) {
        guard viewModel.renderBlocks.indices.contains(blockIndex) else { return }
        let blockID = viewModel.renderBlocks[blockIndex].id
        lastFollowedBlockIndex = blockIndex

        // Direct lazy-child IDs are available to ScrollViewReader even when a
        // distant block has not yet been materialized.
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(blockID, anchor: .center)
                }
            } else {
                proxy.scrollTo(blockID, anchor: .center)
            }
        }
    }

    @ViewBuilder
    private func snapToFollowButton(activeIndex: Int, proxy: ScrollViewProxy) -> some View {
        Button {
            snapToFollow(activeIndex: activeIndex, proxy: proxy)
        } label: {
            Image(systemName: "arrow.down.to.line.compact")
                .font(.body.weight(.semibold))
                .foregroundStyle(BrandTheme.onSurface)
                .frame(width: 44, height: 44)
                .background(
                    Capsule()
                        .fill(BrandTheme.surface.opacity(0.9))
                        .overlay(
                            Capsule()
                                .stroke(BrandTheme.onSurface.opacity(0.2), lineWidth: 1)
                        )
                )
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("transcript.snapToFollow")
        .accessibilityLabel("Follow transcript")
        .accessibilityHint("Scrolls to the current word and turns follow mode on.")
        .padding(.trailing, 16)
        .padding(.bottom, 16 + bottomControlClearance)
        .safeAreaPadding(.bottom)
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
                .accessibilityValue("\(listenedCountAtLivePlayhead)")

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

            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("transcript.activeWord")
                .accessibilityLabel("Active transcript word")
                .accessibilityValue("\(activeWordIndex)")
                .accessibilityHint("Index of the word at the current playback position.")
        }
        .accessibilityElement(children: .contain)
        .frame(width: 1, height: 1)
        .opacity(0.01)
        .allowsHitTesting(false)
    }

    private var listenedCountAtLivePlayhead: Int {
        viewModel.words.reduce(into: 0) { count, display in
            if TranscriptViewModel.isListened(
                word: display.word,
                skippedAd: display.skippedAd,
                playhead: playbackPosition
            ) {
                count += 1
            }
        }
    }

}

/// One direct LazyVStack child. Blocks preserve sentence timestamps and spacing
/// while guaranteeing distant scroll targets can be materialized on demand.
private struct TranscriptRenderBlockView: View {
    let block: TranscriptRenderBlock
    let words: [TranscriptWordDisplay]
    let paragraphs: [TranscriptParagraph]
    var activeWordIndex: Int = -1
    var playbackPosition: TimeInterval = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if block.showsParagraphHeader,
               paragraphs.indices.contains(block.paragraphIndex) {
                let paragraph = paragraphs[block.paragraphIndex]
                Text(paragraph.formattedStartTimestamp)
                    .font(.caption)
                    .foregroundStyle(BrandTheme.onSurface.opacity(0.6))
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("transcript.paragraph_\(block.paragraphIndex).timestamp")
                    .accessibilityLabel("Paragraph start time")
                    .accessibilityValue(paragraph.formattedStartTimestamp)
            }

            WrappingTranscriptWordsLayout(horizontalSpacing: 4, verticalSpacing: 4) {
                ForEach(wordsIn(block), id: \.index) { display in
                    let isActive = display.index == activeWordIndex
                    Text(display.word.word)
                        // Keep the text metrics identical as the active word
                        // changes; karaoke is a highlight, not a layout change.
                        .font(.body)
                        .foregroundStyle(foreground(for: display))
                        .background {
                            if isActive {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(BrandTheme.primary.opacity(0.25))
                            }
                        }
                        .id(display.index)
                        .accessibilityElement(children: .ignore)
                        .accessibilityIdentifier("transcript.word_\(display.index)")
                        .accessibilityLabel(display.word.word)
                        .accessibilityValue(accessibilityValue(for: display, isActive: isActive))
                }
            }
            // A render block is measured independently by LazyVStack. Give the
            // wrapping layout the ScrollView's concrete width during that
            // measurement, rather than letting its first pass use an
            // unconstrained proposal. Otherwise it reports a one-line height
            // and a following block can be placed over its wrapped last line.
            .containerRelativeFrame(.horizontal, count: 1, span: 1, spacing: 0, alignment: .leading)
        }
        .padding(.bottom, block.endsParagraph ? 12 : 0)
    }

    private func wordsIn(_ block: TranscriptRenderBlock) -> [TranscriptWordDisplay] {
        guard words.indices.contains(block.firstWordIndex), words.indices.contains(block.lastWordIndex) else {
            return []
        }
        return Array(words[block.firstWordIndex ... block.lastWordIndex])
    }

    private func foreground(for display: TranscriptWordDisplay) -> Color {
        if display.skippedAd {
            return BrandTheme.accent
        }
        if isListened(display) {
            return BrandTheme.onSurface.opacity(0.6)
        }
        return BrandTheme.onSurface
    }

    private func accessibilityValue(for display: TranscriptWordDisplay, isActive: Bool) -> String {
        var parts: [String] = []
        if display.skippedAd {
            parts.append("skippedAd")
        } else if isListened(display) {
            parts.append("listened")
        }
        if isActive {
            parts.append("active")
        }
        return parts.joined(separator: ",")
    }

    private func isListened(_ display: TranscriptWordDisplay) -> Bool {
        TranscriptViewModel.isListened(
            word: display.word,
            skippedAd: display.skippedAd,
            playhead: playbackPosition
        )
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
            let nextX = x == 0 ? size.width : x + horizontalSpacing + size.width
            if x > 0, nextX > maxWidth {
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
            let nextX = x == bounds.minX ? x + size.width : x + horizontalSpacing + size.width
            if x > bounds.minX, nextX > bounds.maxX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            if x > bounds.minX { x += horizontalSpacing }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }
    }
}
