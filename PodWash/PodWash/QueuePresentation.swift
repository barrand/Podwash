//
//  QueuePresentation.swift
//  PodWash
//

import Foundation

/// The storage fact is deliberately independent from preparation. A downloaded
/// audio file is useful, but it is not automatically ready for clean playback.
enum LocalAudioAvailability: Equatable {
    case notDownloaded
    case downloading(progress: Double?)
    case downloaded
    case failed(detail: String?)
}

enum CleanPlaybackPreparation: Equatable {
    case notRequested
    case queued
    case preparing
    case checkingAds
    case ready
    case adCheckDelayed(retryAt: Date?)
    case needsAttention(detail: String?)
}

/// The one listener-facing answer used by Queue, Library, and mini-player copy.
enum EpisodeReadinessStatus: Equatable {
    case notDownloaded
    case waitingToDownload
    case downloading(progress: Double?)
    case downloadedNotPrepared
    case waitingToPrepare
    case preparing
    case checkingAds
    case readyOffline
    case adCheckDelayed(retryAt: Date?)
    case needsAttention(detail: String?)

    var text: String {
        switch self {
        case .notDownloaded: return "Not downloaded"
        case .waitingToDownload: return "Waiting to download"
        case .downloading(let progress):
            guard let progress else { return "Downloading" }
            return "Downloading · \(Self.percent(progress))%"
        case .downloadedNotPrepared: return "Downloaded · Not prepared"
        case .waitingToPrepare: return "Downloaded · Waiting to prepare"
        case .preparing: return "Preparing clean playback · On device"
        case .checkingAds: return "Checking for ads · On device"
        case .readyOffline: return "Ready to play offline"
        case .adCheckDelayed(let retryAt): return Self.delayedText(retryAt: retryAt)
        case .needsAttention: return "Needs attention"
        }
    }

    var iconName: String {
        switch self {
        case .readyOffline: return "checkmark.circle.fill"
        case .notDownloaded, .waitingToDownload, .downloading, .downloadedNotPrepared, .waitingToPrepare:
            return "arrow.down.circle"
        case .preparing: return "waveform"
        case .checkingAds: return "magnifyingglass"
        case .adCheckDelayed: return "clock"
        case .needsAttention: return "exclamationmark.triangle.fill"
        }
    }

    var tint: QueueStatusTint {
        switch self {
        case .readyOffline: return .ready
        case .adCheckDelayed: return .warning
        case .needsAttention: return .danger
        case .preparing, .checkingAds: return .accent
        case .notDownloaded, .waitingToDownload, .downloading, .downloadedNotPrepared, .waitingToPrepare:
            return .secondary
        }
    }

    var progress: Double? {
        guard case let .downloading(value) = self, let value else { return nil }
        return min(max(value, 0), 1)
    }

    var showsIndeterminateProgress: Bool {
        switch self {
        case .downloading(nil), .preparing, .checkingAds: return true
        default: return false
        }
    }

    var isReadyOffline: Bool { self == .readyOffline }

    var summaryCategory: DownloadSummaryCategory {
        switch self {
        case .readyOffline: return .ready
        case .preparing, .checkingAds, .waitingToPrepare, .downloading: return .preparing
        case .downloadedNotPrepared: return .notPrepared
        case .adCheckDelayed: return .delayed
        case .needsAttention, .waitingToDownload: return .needsAttention
        case .notDownloaded: return .notPrepared
        }
    }

    private static func percent(_ progress: Double) -> Int {
        Int((min(max(progress, 0), 1) * 100).rounded())
    }

    private static func delayedText(retryAt: Date?) -> String {
        guard let retryAt else { return "Ad check delayed · Retrying automatically" }
        let remaining = retryAt.timeIntervalSinceNow
        guard remaining > 0 else { return "Ad check delayed · Retrying now" }
        if remaining < 60 { return "Ad check delayed · Retrying in under 1 min" }
        if remaining < 3_600 { return "Ad check delayed · Retrying in ~\(Int((remaining / 60).rounded())) min" }
        return "Ad check delayed · Retrying in ~\(Int((remaining / 3_600).rounded())) hr"
    }
}

enum QueueStatusTint: Equatable { case ready, secondary, accent, warning, danger }

struct EpisodeAvailability: Equatable {
    let localAudio: LocalAudioAvailability
    let preparation: CleanPlaybackPreparation
    let readiness: EpisodeReadinessStatus

    var hasLocalAudio: Bool {
        if case .downloaded = localAudio { return true }
        return false
    }
}

struct EpisodeAvailabilityInput {
    let downloadState: DownloadState
    let hasVerifiedLocalFile: Bool
    let isAnalysisReady: Bool
    let durableJob: AnalysisJob?
    let foregroundJob: AnalysisJob?
    /// A listener or automatic planner has claimed this episode even if the
    /// serial worker has not created its durable job record yet.
    let hasActiveWorkOwner: Bool

    init(
        downloadState: DownloadState,
        hasVerifiedLocalFile: Bool,
        isAnalysisReady: Bool,
        durableJob: AnalysisJob?,
        foregroundJob: AnalysisJob?,
        hasActiveWorkOwner: Bool = false
    ) {
        self.downloadState = downloadState
        self.hasVerifiedLocalFile = hasVerifiedLocalFile
        self.isAnalysisReady = isAnalysisReady
        self.durableJob = durableJob
        self.foregroundJob = foregroundJob
        self.hasActiveWorkOwner = hasActiveWorkOwner
    }
}

/// Pure resolver: callers repair stale persistence separately, while this type
/// makes stale data safe to present immediately.
enum EpisodeAvailabilityResolver {
    static func resolve(_ input: EpisodeAvailabilityInput) -> EpisodeAvailability {
        let activeJob = input.foregroundJob ?? input.durableJob
        let preparation = preparation(for: activeJob)
        let localAudio = localAudio(for: input, job: activeJob)

        if input.hasVerifiedLocalFile, input.isAnalysisReady {
            return EpisodeAvailability(localAudio: .downloaded, preparation: .ready, readiness: .readyOffline)
        }

        if !input.hasVerifiedLocalFile {
            if case let .downloading(progress) = localAudio {
                return EpisodeAvailability(localAudio: localAudio, preparation: preparation, readiness: .downloading(progress: progress))
            }
            if case let .failed(detail) = localAudio {
                return EpisodeAvailability(localAudio: localAudio, preparation: preparation, readiness: .needsAttention(detail: detail))
            }
            if case let .needsAttention(detail) = preparation {
                return EpisodeAvailability(localAudio: localAudio, preparation: preparation, readiness: .needsAttention(detail: detail))
            }
            return EpisodeAvailability(
                localAudio: localAudio,
                preparation: preparation,
                readiness: input.hasActiveWorkOwner ? .waitingToDownload : .notDownloaded
            )
        }

        switch preparation {
        case .preparing: return EpisodeAvailability(localAudio: .downloaded, preparation: preparation, readiness: .preparing)
        case .checkingAds: return EpisodeAvailability(localAudio: .downloaded, preparation: preparation, readiness: .checkingAds)
        case .adCheckDelayed(let retryAt): return EpisodeAvailability(localAudio: .downloaded, preparation: preparation, readiness: .adCheckDelayed(retryAt: retryAt))
        case .needsAttention(let detail): return EpisodeAvailability(localAudio: .downloaded, preparation: preparation, readiness: .needsAttention(detail: detail))
        case .queued: return EpisodeAvailability(localAudio: .downloaded, preparation: preparation, readiness: .waitingToPrepare)
        case .notRequested, .ready: return EpisodeAvailability(localAudio: .downloaded, preparation: preparation, readiness: .downloadedNotPrepared)
        }
    }

    private static func localAudio(for input: EpisodeAvailabilityInput, job: AnalysisJob?) -> LocalAudioAvailability {
        if input.hasVerifiedLocalFile { return .downloaded }
        if case let .downloading(progress) = input.downloadState { return .downloading(progress: progress) }
        if job?.stage == .downloading { return .downloading(progress: job?.estimate.progress) }
        if input.downloadState == .failed { return .failed(detail: job?.detail) }
        return .notDownloaded
    }

    private static func preparation(for job: AnalysisJob?) -> CleanPlaybackPreparation {
        guard let job else { return .notRequested }
        switch job.stage {
        case .queued, .downloading: return .queued
        case .transcribing: return .preparing
        case .checkingAds: return .checkingAds
        case .ready: return .ready
        case .adCheckDelayed: return .adCheckDelayed(retryAt: job.retryAfter)
        case .needsAttention: return .needsAttention(detail: job.detail)
        }
    }
}

enum DownloadSummaryCategory: CaseIterable, Hashable {
    case ready, preparing, notPrepared, delayed, needsAttention

    var label: String {
        switch self {
        case .ready: return "ready"
        case .preparing: return "preparing"
        case .notPrepared: return "not prepared"
        case .delayed: return "delayed"
        case .needsAttention: return "needs attention"
        }
    }
}

struct DownloadsSummary: Equatable {
    let total: Int
    let counts: [DownloadSummaryCategory: Int]

    var text: String {
        DownloadSummaryCategory.allCases.compactMap { category in
            guard let count = counts[category], count > 0 else { return nil }
            return "\(count) \(category.label)"
        }.joined(separator: " · ")
    }

    var accessibilityValue: String {
        guard total > 0 else { return "No downloads" }
        return "\(total) downloads: \(text)."
    }
}

struct QueueEpisodeMetadata: Equatable {
    let episodeID: String
    let title: String
    let podcastTitle: String
    let publicationDate: Date
    let isPlayed: Bool
}

struct QueueEpisodePresentation: Identifiable, Equatable {
    let episodeID: String
    let title: String
    let podcastTitle: String
    let availability: EpisodeAvailability
    var id: String { episodeID }
}

struct QueueStatusPresentation: Equatable {
    let text: String
    let accessibilityValue: String
}

struct QueuePresentation: Equatable {
    let upNext: [QueueEpisodePresentation]
    let downloads: [QueueEpisodePresentation]
    let downloadsSummary: DownloadsSummary
    let activeStatus: QueueStatusPresentation?
}

struct QueuePresentationInput {
    let manualQueueIDs: [String]
    let downloadedEpisodeIDs: Set<String>
    let nowPlayingEpisodeID: String?
    let metadataByEpisodeID: [String: QueueEpisodeMetadata]
    let jobsByEpisodeID: [String: AnalysisJob]
    let availabilityByEpisodeID: [String: EpisodeAvailability]
    let foregroundJob: AnalysisJob?
    let pendingQueueActivationEpisodeID: String?
}

enum QueuePresentationBuilder {
    static func build(_ input: QueuePresentationInput) -> QueuePresentation {
        let queueIDs = Set(input.manualQueueIDs)
        let upNext = input.manualQueueIDs.compactMap { row(for: $0, input: input) }
        let downloads = input.downloadedEpisodeIDs
            .filter { id in
                id != input.nowPlayingEpisodeID && !queueIDs.contains(id) && input.metadataByEpisodeID[id]?.isPlayed == false
            }
            .compactMap { row(for: $0, input: input) }
            .sorted { lhs, rhs in
                let lhsDate = input.jobsByEpisodeID[lhs.episodeID]?.updatedAt ?? input.metadataByEpisodeID[lhs.episodeID]?.publicationDate ?? .distantPast
                let rhsDate = input.jobsByEpisodeID[rhs.episodeID]?.updatedAt ?? input.metadataByEpisodeID[rhs.episodeID]?.publicationDate ?? .distantPast
                return lhsDate == rhsDate ? lhs.episodeID < rhs.episodeID : lhsDate > rhsDate
            }
        return QueuePresentation(
            upNext: upNext,
            downloads: downloads,
            downloadsSummary: summary(for: downloads),
            activeStatus: QueueStatusResolver.resolve(
                foreground: input.foregroundJob,
                pendingEpisodeID: input.pendingQueueActivationEpisodeID,
                metadataByEpisodeID: input.metadataByEpisodeID,
                availabilityByEpisodeID: input.availabilityByEpisodeID,
                upNext: upNext
            )
        )
    }

    private static func row(for id: String, input: QueuePresentationInput) -> QueueEpisodePresentation? {
        guard let metadata = input.metadataByEpisodeID[id] else { return nil }
        let availability = input.availabilityByEpisodeID[id]
            ?? EpisodeAvailability(localAudio: .notDownloaded, preparation: .notRequested, readiness: .waitingToDownload)
        return QueueEpisodePresentation(episodeID: id, title: metadata.title, podcastTitle: metadata.podcastTitle, availability: availability)
    }

    private static func summary(for downloads: [QueueEpisodePresentation]) -> DownloadsSummary {
        var counts = Dictionary(uniqueKeysWithValues: DownloadSummaryCategory.allCases.map { ($0, 0) })
        for row in downloads { counts[row.availability.readiness.summaryCategory, default: 0] += 1 }
        return DownloadsSummary(total: downloads.count, counts: counts)
    }
}

enum QueueStatusResolver {
    static func resolve(
        foreground: AnalysisJob?,
        pendingEpisodeID: String?,
        metadataByEpisodeID: [String: QueueEpisodeMetadata],
        availabilityByEpisodeID: [String: EpisodeAvailability],
        upNext: [QueueEpisodePresentation]
    ) -> QueueStatusPresentation? {
        if let foreground, let availability = availabilityByEpisodeID[foreground.episodeID], !availability.readiness.isReadyOffline {
            return status(availability.readiness, title: foreground.title)
        }
        if let pendingEpisodeID,
           let availability = availabilityByEpisodeID[pendingEpisodeID],
           let title = metadataByEpisodeID[pendingEpisodeID]?.title,
           !availability.readiness.isReadyOffline {
            return status(availability.readiness, title: title)
        }
        guard let row = upNext.first(where: { !$0.availability.readiness.isReadyOffline }) else { return nil }
        return status(row.availability.readiness, title: row.title)
    }

    private static func status(_ readiness: EpisodeReadinessStatus, title: String) -> QueueStatusPresentation {
        QueueStatusPresentation(text: "\(readiness.text) · \(title)", accessibilityValue: "\(readiness.text), \(title)")
    }
}
