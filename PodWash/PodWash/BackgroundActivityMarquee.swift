import SwiftUI

enum ActivityMarqueeMotion {
    static func usesStaticText(reduceMotion: Bool, voiceOver: Bool, largeText: Bool) -> Bool {
        reduceMotion || voiceOver || largeText
    }
}

/// Quiet chrome: no idle row, no invented progress, and no repeated VoiceOver announcements.
struct BackgroundActivityMarquee: View {
    let presentation: BackgroundActivityPresentation
    let onOpenIssue: () -> Void
    let onDismissIssue: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if presentation.isFailure {
                Button(action: onOpenIssue) { content.frame(minHeight: 44) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows recovery options.")
                Button(action: onDismissIssue) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss activity issue")
                .accessibilityIdentifier("backgroundActivity.dismiss")
            } else {
                content
            }
        }
        .font(.caption)
        .foregroundStyle(presentation.isFailure ? .primary : .secondary)
        .padding(.leading, 16)
        .padding(.trailing, presentation.isFailure ? 6 : 16)
        .padding(.vertical, presentation.isFailure ? 0 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrandTheme.surface)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("backgroundActivity")
    }

    private var content: some View {
        HStack(spacing: 8) {
            Image(systemName: presentation.symbol)
                .foregroundStyle(presentation.isFailure ? Color.orange : Color.accentColor)
                .accessibilityHidden(true)
            ActivityScrollingText(text: presentation.text)
            if presentation.additionalCount > 0 {
                Text("+\(presentation.additionalCount)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityIdentifier("backgroundActivity.status")
    }
}

/// A slow, delayed reveal for overflow only. Accessibility uses the complete text;
/// Reduce Motion and VoiceOver use wrapping text with no automatic movement.
private struct ActivityScrollingText: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var textWidth: CGFloat = 0
    @State private var availableWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var travel: CGFloat { max(0, textWidth - availableWidth) }
    private var usesStaticText: Bool {
        ActivityMarqueeMotion.usesStaticText(reduceMotion: reduceMotion, voiceOver: voiceOver,
                                           largeText: dynamicTypeSize.isAccessibilitySize)
    }

    var body: some View {
        Group {
            if usesStaticText {
                Text(text).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(text)
                    .lineLimit(1)
                    .hidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .leading) {
                        Text(text)
                            .fixedSize()
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
                            .offset(x: offset)
                    }
                    .clipped()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
            }
        }
        .task(id: "\(text):\(travel):\(usesStaticText):\(scenePhase):\(layoutDirection)") {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { offset = 0 }
            guard !usesStaticText, scenePhase == .active, travel > 1 else { return }
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2))
                    let duration = Double(travel / 24)
                    withAnimation(.linear(duration: duration)) {
                        offset = layoutDirection == .rightToLeft ? travel : -travel
                    }
                    try await Task.sleep(for: .seconds(duration + 2))
                    withAnimation(.linear(duration: duration)) { offset = 0 }
                    try await Task.sleep(for: .seconds(duration))
                }
            } catch { /* Disappearing or changing text cancels the animation. */ }
        }
    }
}
