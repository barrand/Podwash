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
                        // A malformed ASR token or URL must wrap inside the
                        // transcript column instead of widening the flow layout.
                        .fixedSize(horizontal: false, vertical: true)
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
            .frame(maxWidth: .infinity, alignment: .leading)
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
        geometry(for: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = geometry(for: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, layout.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func geometry(for proposedWidth: CGFloat?, subviews: Subviews) -> TranscriptFlowGeometry {
        let containerWidth = proposedWidth.flatMap { width in
            width.isFinite ? max(0, width) : nil
        }
        let itemProposal = containerWidth.map {
            ProposedViewSize(width: $0, height: nil)
        } ?? .unspecified
        let sizes = subviews.map { $0.sizeThatFits(itemProposal) }
        return TranscriptFlowGeometry(
            itemSizes: sizes,
            containerWidth: containerWidth,
            horizontalSpacing: horizontalSpacing,
            verticalSpacing: verticalSpacing
        )
    }
}

/// A single source of truth for both measurement and placement of transcript
/// words. When a parent offers a finite width, the layout claims that exact
/// width. This invariant prevents SwiftUI from placing the words in a narrower
/// box than the one used to calculate their height.
struct TranscriptFlowGeometry {
    let frames: [CGRect]
    let size: CGSize

    init(
        itemSizes: [CGSize],
        containerWidth: CGFloat?,
        horizontalSpacing: CGFloat,
        verticalSpacing: CGFloat
    ) {
        let finiteWidth = containerWidth.flatMap { width in
            width.isFinite ? max(0, width) : nil
        }
        var frames: [CGRect] = []
        frames.reserveCapacity(itemSizes.count)

        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for rawSize in itemSizes {
            let width = min(max(0, rawSize.width), finiteWidth ?? .greatestFiniteMagnitude)
            let height = max(0, rawSize.height)
            let size = CGSize(width: width, height: height)
            let spacedX = x == 0 ? 0 : x + horizontalSpacing

            if x > 0, let finiteWidth, spacedX + width > finiteWidth {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            } else {
                x = spacedX
            }

            let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
            frames.append(frame)
            x = frame.maxX
            rowHeight = max(rowHeight, height)
            contentWidth = max(contentWidth, frame.maxX)
        }

        let contentHeight = itemSizes.isEmpty ? 0 : y + rowHeight
        self.frames = frames
        self.size = CGSize(width: finiteWidth ?? contentWidth, height: contentHeight)
    }
}
