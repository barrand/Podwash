//
//  AnalysisTimelineView.swift
//  PodWash
//
//  Slice 20 — Segmented timeline bar (ADR-018 / slice-20-ux.md).
//  List chrome uses `AnalysisTimelineBarView` (UIKit) for stable AX.
//

import SwiftUI
import UIKit

/// SwiftUI wrapper around the same segment model (previews / non-list hosts).
struct AnalysisTimelineView: View {
    let colors: [TimelineSegmentColor]
    var height: CGFloat = 8
    var accessibilityIdentifier: String = "analysisTimeline"

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                Rectangle()
                    .fill(Self.swiftUIColor(color))
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel("Analysis timeline")
        .accessibilityValue(AnalysisTimelineModel.accessibilityValue(from: colors))
        .accessibilityHint("Shows which parts of the episode are scanned, in progress, or waiting.")
    }

    private static func swiftUIColor(_ color: TimelineSegmentColor) -> Color {
        switch color {
        case .green: return Color(uiColor: .systemGreen)
        case .blue: return Color(uiColor: .systemBlue)
        case .grey: return Color(uiColor: .systemGray4)
        case .yellow: return Color(uiColor: .systemYellow)
        }
    }
}

/// UIKit segmented bar hosted in `EpisodeTableViewCell` for XCTest AX stability.
final class AnalysisTimelineBarView: UIView {
    private var segmentViews: [UIView] = []
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .horizontal
        stack.spacing = 0
        stack.distribution = .fillEqually
        stack.alignment = .fill
        stack.isAccessibilityElement = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let stackTrailing = stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        stackTrailing.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackTrailing,
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 8),
        ])
        isAccessibilityElement = false
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func apply(colors: [TimelineSegmentColor]) {
        if segmentViews.count != colors.count {
            segmentViews.forEach { $0.removeFromSuperview() }
            segmentViews = colors.map { _ in
                let view = UIView()
                view.isAccessibilityElement = false
                stack.addArrangedSubview(view)
                return view
            }
        }
        for (index, color) in colors.enumerated() {
            segmentViews[index].backgroundColor = Self.uiColor(color)
        }
    }

    private static func uiColor(_ color: TimelineSegmentColor) -> UIColor {
        switch color {
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .grey: return .systemGray4
        case .yellow: return .systemYellow
        }
    }
}
