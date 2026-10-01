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
        guard case let .progress(value) = primaryControl, let value, value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }
}

enum EpisodeRowPresentationMapper {
    static func map(_ status: EpisodeReadinessStatus, now: Date = Date()) -> EpisodeRowPresentation {
        map(status, failureIsDownload: false, now: now)
    }

    static func map(_ availability: EpisodeAvailability, now: Date = Date()) -> EpisodeRowPresentation {
        let downloadFailure: Bool
        if case .failed = availability.localAudio { downloadFailure = true } else { downloadFailure = false }
        return map(availability.readiness, failureIsDownload: downloadFailure, now: now)
    }

    static func map(_ job: AnalysisJob, now: Date = Date()) -> EpisodeRowPresentation {
        let status: EpisodeReadinessStatus
        switch job.stage {
        case .queued: status = .waitingToPrepare
        case .downloading: status = .downloading(progress: job.estimate.progress)
        case .transcribing: status = .preparing
        case .checkingAds: status = .checkingAds
        case .ready: status = .readyOffline
        case .adCheckDelayed: status = .adCheckDelayed(retryAt: job.retryAfter)
        case .needsAttention: status = .needsAttention(detail: job.detail)
        }
        return map(status, now: now)
    }

    private static func map(_ status: EpisodeReadinessStatus, failureIsDownload: Bool, now: Date) -> EpisodeRowPresentation {
        let control: EpisodePrimaryControl
        let symbol: String
        let tint: EpisodeRowSemanticTint
        switch status {
        case .notDownloaded:
            control = .download; symbol = "arrow.down.circle"; tint = .secondary
        case .waitingToDownload, .waitingToPrepare:
            control = .waiting; symbol = "clock"; tint = .secondary
        case .downloading(let progress):
            control = .progress(progress.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }); symbol = "arrow.down.circle"; tint = .accent
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
            switch status {
            case .notDownloaded: text = "Not downloaded"
            case .waitingToDownload: text = "Waiting to download"
            case .downloading(let value):
                if let value, value.isFinite {
                    text = "Downloading · \(Int((min(max(value, 0), 1) * 100).rounded()))%"
                } else { text = "Downloading" }
            case .downloadedNotPrepared: text = "Downloaded · Not prepared"
            case .waitingToPrepare: text = "Downloaded · Waiting to prepare"
            case .preparing: text = "Preparing clean playback"
            case .checkingAds: text = "Checking for ads"
            case .readyOffline: text = "Ready to play offline"
            case .adCheckDelayed(let deadline):
                if let deadline {
                    let remaining = deadline.timeIntervalSince(now)
                    if remaining <= 0 { text = "Ad check delayed · Retrying now" }
                    else if remaining < 60 { text = "Ad check delayed · Retrying in under 1 min" }
                    else if remaining < 3600 { text = "Ad check delayed · Retrying in ~\(Int((remaining / 60).rounded())) min" }
                    else { text = "Ad check delayed · Retrying in ~\(Int((remaining / 3600).rounded())) hr" }
                } else { text = "Ad check delayed · Retrying automatically" }
            case .needsAttention: text = "Preparation needs attention"
            }
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
}

enum EpisodeMenuAction: String, Identifiable {
    case addToUpNext, moveToTop, removeFromUpNext, cancelDownload, cancelPreparation, retry
    case playWithoutAdSkipping, playOriginalAudio, markPlayed, replay, transcript, removeDownload
    var id: String { rawValue }
    var title: String {
        switch self {
        case .addToUpNext: "Add to Up Next"
        case .moveToTop: "Move to Top"
        case .removeFromUpNext: "Remove from Up Next"
        case .cancelDownload: "Cancel Download"
        case .cancelPreparation: "Cancel Preparation"
        case .retry: "Retry now"
        case .playWithoutAdSkipping: "Play without ad skipping"
        case .playOriginalAudio: "Play original audio"
        case .markPlayed: "Mark as Played"
        case .replay: "Replay from Beginning"
        case .transcript: "View Transcript"
        case .removeDownload: "Remove Download"
        }
    }
    var isDestructive: Bool { self == .removeDownload || self == .removeFromUpNext }
}

struct EpisodeRowSnapshot: Equatable {
    let episodeID: String
    let title: String
    let presentation: EpisodeRowPresentation
    let context: EpisodeRowContext
    let cleaningSummary: EpisodeCleaningSummary?
    let menu: [EpisodeMenuAction]
}

struct EpisodeMenuFacts {
    let isQueued: Bool
    let isPlayed: Bool
    let hasLocalAudio: Bool
    let hasExplicitOwner: Bool
    let hasTranscript: Bool
    let hasLocalCleaning: Bool
    let readiness: EpisodeReadinessStatus
    var cloudFailure: CloudAdDetectionFailureCategory? = nil
    var protectsLocalAudio = false
}

enum EpisodeMenuPolicy {
    static func actions(_ facts: EpisodeMenuFacts) -> [EpisodeMenuAction] {
        var result: [EpisodeMenuAction] = facts.isQueued ? [.moveToTop, .removeFromUpNext] : [.addToUpNext]
        if facts.hasExplicitOwner && !facts.protectsLocalAudio {
            result.append(facts.hasLocalAudio ? .cancelPreparation : .cancelDownload)
        }
        if case .adCheckDelayed = facts.readiness {
            result.append(.retry)
            if facts.hasLocalAudio && facts.hasLocalCleaning && facts.cloudFailure != nil { result.append(.playWithoutAdSkipping) }
        }
        if case .needsAttention = facts.readiness, facts.hasLocalAudio {
            result.append(facts.hasLocalCleaning && facts.cloudFailure != nil ? .playWithoutAdSkipping : .playOriginalAudio)
        }
        if facts.hasTranscript { result.append(.transcript) }
        result.append(facts.isPlayed ? .replay : .markPlayed)
        if facts.hasLocalAudio && !facts.protectsLocalAudio { result.append(.removeDownload) }
        return result
    }
}

struct EpisodeRowBindings {
    let primary: EpisodeRowActions
    let perform: (EpisodeMenuAction) -> Void
}

struct SharedEpisodeRow: View {
    let snapshot: EpisodeRowSnapshot
    let bindings: EpisodeRowBindings
    var isReordering = false
    @ViewBuilder var body: some View {
        if case .adCheckDelayed = snapshot.presentation.status {
            TimelineView(.periodic(from: .now, by: 30)) { tick in
                row(presentation: EpisodeRowPresentationMapper.map(snapshot.presentation.status, now: tick.date))
            }
        } else { row(presentation: snapshot.presentation) }
    }
    private func row(presentation: EpisodeRowPresentation) -> some View {
        EpisodeRowView(episodeID: snapshot.episodeID, title: snapshot.title,
            presentation: presentation, context: snapshot.context,
            cleaningSummary: snapshot.cleaningSummary, isReordering: isReordering,
            actions: bindings.primary, moreMenu: {
                AnyView(ForEach(snapshot.menu) { action in
                    Button(action.title, role: action.isDestructive ? .destructive : nil) {
                        bindings.perform(action)
                    }.accessibilityIdentifier("episodeMenu_\(action.rawValue)_\(snapshot.episodeID)")
                })
            })
    }
}

struct EpisodeRowView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let episodeID: String
    let title: String
    let presentation: EpisodeRowPresentation
    let context: EpisodeRowContext
    var cleaningSummary: EpisodeCleaningSummary? = nil
    var isReordering = false
    let actions: EpisodeRowActions
    let moreMenu: () -> AnyView

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
        return layout {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.semibold)).lineLimit(2)
                Text(context.metadata).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Label(presentation.statusText, systemImage: presentation.symbolName)
                    .font(.caption)
                    .foregroundStyle(color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("episodeStatus_\(episodeID)")
                if let cleaningSummary {
                    Text(CleaningSummaryModel.visibleLabel(from: cleaningSummary))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("episodeCleaningSummary_\(episodeID)")
                        .accessibilityLabel("Cleaning summary")
                        .accessibilityValue(CleaningSummaryModel.accessibilityValue(from: cleaningSummary))
                }
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 4) }
            if !isReordering {
                HStack(spacing: 4) {
                primaryControl
                Menu { moreMenu() } label: {
                    Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
                }
                .accessibilityIdentifier("episodeMore_\(episodeID)")
                .accessibilityLabel("More actions")
                }
            }
        }
        .padding(.vertical, 6)
        .buttonStyle(.borderless)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("episodeRow_\(episodeID)")
        .accessibilityLabel(title)
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
