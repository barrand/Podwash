//
//  EpisodeRowView.swift
//  PodWash
//
//  The listener-facing episode state lives here so Library and Up Next cannot
//  drift in wording, controls, or accessibility semantics.
//

import SwiftUI

enum EpisodePrimaryControl: Equatable {
    case download, prepare, waiting, progress(Double?), retry, play
}

enum EpisodeRowSemanticTint: Equatable {
    case secondary, accent, ready, warning, danger
}

struct EpisodeRowPresentation: Equatable {
    let status: EpisodeReadinessStatus
    let statusText: String
    let symbolName: String
    let tint: EpisodeRowSemanticTint
    let primaryControl: EpisodePrimaryControl
    let accessibilityValue: String

    var progress: Double? {
        guard case let .progress(value) = primaryControl, let value else { return nil }
        return min(max(value, 0), 1)
    }
}

enum EpisodeRowPresentationMapper {
    static func map(_ status: EpisodeReadinessStatus) -> EpisodeRowPresentation {
        map(status, failureIsDownload: false)
    }

    static func map(_ availability: EpisodeAvailability) -> EpisodeRowPresentation {
        let downloadFailure: Bool
        if case .failed = availability.localAudio { downloadFailure = true } else { downloadFailure = false }
        return map(availability.readiness, failureIsDownload: downloadFailure)
    }

    private static func map(_ status: EpisodeReadinessStatus, failureIsDownload: Bool) -> EpisodeRowPresentation {
        let control: EpisodePrimaryControl
        let symbol: String
        let tint: EpisodeRowSemanticTint
        switch status {
        case .notDownloaded:
            control = .download; symbol = "arrow.down.circle"; tint = .secondary
        case .waitingToDownload, .waitingToPrepare:
            control = .waiting; symbol = "clock"; tint = .secondary
        case .downloading(let progress):
            control = .progress(progress); symbol = "arrow.down.circle"; tint = .accent
        case .downloadedNotPrepared:
            control = .prepare; symbol = "waveform"; tint = .secondary
        case .preparing, .checkingAds:
            control = .progress(nil); symbol = status == .checkingAds ? "magnifyingglass" : "waveform"; tint = .accent
        case .readyOffline:
            control = .play; symbol = "checkmark.circle.fill"; tint = .ready
        case .adCheckDelayed:
            control = .waiting; symbol = "clock"; tint = .warning
        case .needsAttention:
            control = .retry; symbol = "exclamationmark.triangle.fill"; tint = .danger
        }
        let text: String
        if case .needsAttention = status {
            text = failureIsDownload ? "Download failed" : "Preparation needs attention"
        } else {
            text = status.text
        }
        return EpisodeRowPresentation(
            status: status,
            statusText: text,
            symbolName: symbol,
            tint: tint,
            primaryControl: control,
            accessibilityValue: text
        )
    }
}

enum EpisodeRowContext: Equatable {
    case queue(podcastTitle: String)
    case library(publicationDate: Date, isPlayed: Bool)

    var metadata: String {
        switch self {
        case .queue(let title): return title
        case .library(let date, let isPlayed):
            let dateText = date.formatted(date: .abbreviated, time: .omitted)
            return isPlayed ? "\(dateText) · Played" : dateText
        }
    }
}

struct EpisodeRowActions {
    var download: () -> Void = {}
    var prepare: () -> Void = {}
    var retry: () -> Void = {}
    var play: () -> Void = {}
    var more: () -> Void = {}
}

struct EpisodeRowView: View {
    let episodeID: String
    let title: String
    let presentation: EpisodeRowPresentation
    let context: EpisodeRowContext
    var cleaningSummary: EpisodeCleaningSummary? = nil
    var isReordering = false
    let actions: EpisodeRowActions
    let moreMenu: () -> AnyView

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.semibold)).lineLimit(2)
                Text(context.metadata).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Label(presentation.statusText, systemImage: presentation.symbolName)
                    .font(.caption)
                    .foregroundStyle(color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("episodeStatus_\(episodeID)")
                if let cleaningSummary {
                    Text(CleaningSummaryModel.visibleLabel(from: cleaningSummary))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if !isReordering { primaryControl }
            if !isReordering {
                Menu { moreMenu() } label: {
                    Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
                }
                .accessibilityIdentifier("episodeMore_\(episodeID)")
                .accessibilityLabel("More actions")
                .onTapGesture(perform: actions.more)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("episodeRow_\(episodeID)")
    }

    @ViewBuilder private var primaryControl: some View {
        switch presentation.primaryControl {
        case .download: labeledButton("Download", icon: "arrow.down.circle", action: actions.download)
        case .prepare: labeledButton("Prepare", icon: "waveform", action: actions.prepare)
        case .retry: labeledButton("Retry", icon: "arrow.clockwise", action: actions.retry)
        case .play: labeledButton("Play", icon: "play.fill", action: actions.play)
        case .waiting:
            Image(systemName: "clock").frame(width: 44, height: 44)
                .foregroundStyle(.secondary)
                .accessibilityLabel(presentation.statusText)
        case .progress(let value):
            Group {
                if let value { ProgressView(value: min(max(value, 0), 1)) }
                else { ProgressView() }
            }
            .frame(width: 44, height: 44)
            .accessibilityIdentifier("episodeProgress_\(episodeID)")
            .accessibilityLabel(presentation.statusText)
        }
    }

    private func labeledButton(_ text: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(text, systemImage: icon).labelStyle(.iconOnly).frame(width: 44, height: 44)
        }
        .accessibilityIdentifier("episodePrimary_\(episodeID)")
        .accessibilityLabel(text)
    }

    private var color: Color {
        switch presentation.tint {
        case .secondary: return .secondary
        case .accent: return .accentColor
        case .ready: return .green
        case .warning: return .orange
        case .danger: return .red
        }
    }
}
