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
    var onClose: (() -> Void)? = nil

    @State private var didAutoScroll = false
    @State private var isFollowModeOn = true
    @State private var isProgrammaticScrollInFlight = false
    @State private var lastFollowedActiveIndex: Int?
    @State private var activeWordIndex: Int = 0

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            aggregateHosts

                            TranscriptParagraphsView(
                                words: viewModel.words,
                                paragraphs: TranscriptViewModel.paragraphs(
                                    from: viewModel.words.map(\.word)
                                ),
                                activeWordIndex: activeWordIndex
                            )
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(BrandTheme.surface)
                    .onScrollPhaseChange { _, newPhase in
                        guard newPhase == .interacting else { return }
                        guard !isProgrammaticScrollInFlight else { return }
                        noteUserScrollInteraction()
                    }
                    .onAppear {
                        refreshActiveWordIndex()
                        performOpenTimeScrollIfNeeded(proxy: proxy)
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
                let index = computedActiveWordIndex
                Color.clear
                    .accessibilityHidden(true)
                    .onChange(of: index) { _, newIndex in
                        activeWordIndex = newIndex
                    }
                    .onAppear {
                        activeWordIndex = index
                    }
            }
        }
    }

    private var computedActiveWordIndex: Int {
        TranscriptViewModel.activeWordIndex(
            transcript: viewModel.words.map(\.word),
            playhead: livePlayheadSeconds
        )
    }

    private var livePlayheadSeconds: TimeInterval {
        if let engine = playbackEngine {
            let seconds = engine.avPlayer.currentTime().seconds
            if seconds.isFinite, !seconds.isNaN {
                return seconds
            }
            return engine.currentTime
        }
        return openPlaybackPosition
    }

    private func refreshActiveWordIndex() {
        activeWordIndex = computedActiveWordIndex
    }

    private func noteUserScrollInteraction() {
        isFollowModeOn = false
    }

    private func performOpenTimeScrollIfNeeded(proxy: ScrollViewProxy) {
        guard !didAutoScroll else { return }
        didAutoScroll = true
        guard viewModel.scrollAnchorSeconds > 0 || viewModel.scrollAnchorIndex > 0 else {
            lastFollowedActiveIndex = viewModel.scrollAnchorIndex
            return
        }
        scrollProgrammatically(to: viewModel.scrollAnchorIndex, proxy: proxy)
        lastFollowedActiveIndex = viewModel.scrollAnchorIndex
    }

    private func followScrollIfNeeded(to activeIndex: Int, proxy: ScrollViewProxy) {
        guard isFollowModeOn else { return }
        guard didAutoScroll else { return }
        guard lastFollowedActiveIndex != activeIndex else { return }
        scrollProgrammatically(to: activeIndex, proxy: proxy)
        lastFollowedActiveIndex = activeIndex
    }

    private func snapToFollow(activeIndex: Int, proxy: ScrollViewProxy) {
        isFollowModeOn = true
        scrollProgrammatically(to: activeIndex, proxy: proxy)
        lastFollowedActiveIndex = activeIndex
    }

    private func scrollProgrammatically(to index: Int, proxy: ScrollViewProxy) {
        isProgrammaticScrollInFlight = true
        DispatchQueue.main.async {
            withAnimation {
                proxy.scrollTo(index, anchor: .center)
            }
            DispatchQueue.main.async {
                isProgrammaticScrollInFlight = false
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
        .padding(.bottom, 16)
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

            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("transcript.followMode")
                .accessibilityLabel("Transcript follow mode")
                .accessibilityValue(isFollowModeOn ? "on" : "off")
                .accessibilityHint("Whether the transcript scrolls with playback.")

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
}

/// Sentence paragraphs with inline-wrapping words and start timestamps.
private struct TranscriptParagraphsView: View {
    let words: [TranscriptWordDisplay]
    let paragraphs: [TranscriptParagraph]
    var activeWordIndex: Int = -1

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
                            let isActive = display.index == activeWordIndex
                            Text(display.word.word)
                                .font(isActive ? .body.weight(.semibold) : .body)
                                .foregroundStyle(foreground(for: display))
                                .padding(.horizontal, isActive ? 4 : 0)
                                .padding(.vertical, isActive ? 2 : 0)
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

    private func accessibilityValue(for display: TranscriptWordDisplay, isActive: Bool) -> String {
        var parts: [String] = []
        if display.skippedAd {
            parts.append("skippedAd")
        } else if display.listened {
            parts.append("listened")
        }
        if isActive {
            parts.append("active")
        }
        return parts.joined(separator: ",")
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
