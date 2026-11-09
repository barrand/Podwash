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
    case needsAttention(reason: PreparationFailureReason?)
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
    case needsAttention(reason: PreparationFailureReason?)

    var isReadyOffline: Bool { self == .readyOffline }

    var preparationFailureReason: PreparationFailureReason? {
        guard case let .needsAttention(reason) = self else { return nil }
        return reason
    }
}

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
    let requiresFreshPreparation: Bool

    init(
        downloadState: DownloadState,
        hasVerifiedLocalFile: Bool,
        isAnalysisReady: Bool,
        durableJob: AnalysisJob?,
        foregroundJob: AnalysisJob?,
        hasActiveWorkOwner: Bool = false,
        requiresFreshPreparation: Bool = false
    ) {
        self.downloadState = downloadState
        self.hasVerifiedLocalFile = hasVerifiedLocalFile
        self.isAnalysisReady = isAnalysisReady
        self.durableJob = durableJob
        self.foregroundJob = foregroundJob
        self.hasActiveWorkOwner = hasActiveWorkOwner
        self.requiresFreshPreparation = requiresFreshPreparation
    }
}

/// Pure resolver: callers repair stale persistence separately, while this type
/// makes stale data safe to present immediately.
enum EpisodeAvailabilityResolver {
    static func resolve(_ input: EpisodeAvailabilityInput) -> EpisodeAvailability {
        let activeJob = input.foregroundJob ?? input.durableJob
        let preparation = preparation(for: activeJob)
        let localAudio = localAudio(for: input, job: activeJob)

        if input.hasVerifiedLocalFile, input.isAnalysisReady, !input.requiresFreshPreparation {
            return EpisodeAvailability(localAudio: .downloaded, preparation: .ready, readiness: .readyOffline)
        }

        if !input.hasVerifiedLocalFile {
            if case let .downloading(progress) = localAudio {
                return EpisodeAvailability(localAudio: localAudio, preparation: preparation, readiness: .downloading(progress: progress))
            }
            if case .failed = localAudio {
                return EpisodeAvailability(localAudio: localAudio, preparation: preparation, readiness: .needsAttention(reason: .downloadFailed))
            }
            if case let .needsAttention(reason) = preparation {
                return EpisodeAvailability(localAudio: localAudio, preparation: preparation, readiness: .needsAttention(reason: reason))
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
        case .needsAttention(let reason): return EpisodeAvailability(localAudio: .downloaded, preparation: preparation, readiness: .needsAttention(reason: reason))
        case .queued, .notRequested, .ready:
            return EpisodeAvailability(localAudio: .downloaded, preparation: preparation,
                readiness: input.hasActiveWorkOwner ? .waitingToPrepare : .downloadedNotPrepared)
        }
    }

    private static func localAudio(for input: EpisodeAvailabilityInput, job: AnalysisJob?) -> LocalAudioAvailability {
        if input.hasVerifiedLocalFile { return .downloaded }
        if case let .downloading(progress) = input.downloadState { return .downloading(progress: progress) }
        if job?.stage == .downloading { return .downloading(progress: job?.estimate.progress) }
        if input.downloadState == .failed {
            if input.hasActiveWorkOwner, job?.stage == .queued { return .notDownloaded }
            return .failed(detail: job?.detail)
        }
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
        case .needsAttention: return .needsAttention(reason: job.resolvedFailureReason)
        }
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
    enum Origin: Equatable { case manual, autoplay }
    let episodeID: String
    let title: String
    let podcastTitle: String
    let availability: EpisodeAvailability
    let origin: Origin
    var id: String { episodeID }
}

struct QueuePresentation: Equatable {
    let upNext: [QueueEpisodePresentation]
    let autoplay: [QueueEpisodePresentation]
    let isSmartAutoplayEnabled: Bool
}

struct QueuePresentationInput {
    let manualQueueIDs: [String]
    let autoplay: [ComingUpItem]
    let isSmartAutoplayEnabled: Bool
    let metadataByEpisodeID: [String: QueueEpisodeMetadata]
    let availabilityByEpisodeID: [String: EpisodeAvailability]

    init(
        manualQueueIDs: [String],
        autoplay: [ComingUpItem] = [],
        isSmartAutoplayEnabled: Bool = true,
        metadataByEpisodeID: [String: QueueEpisodeMetadata],
        availabilityByEpisodeID: [String: EpisodeAvailability]
    ) {
        self.manualQueueIDs = manualQueueIDs
        self.autoplay = autoplay
        self.isSmartAutoplayEnabled = isSmartAutoplayEnabled
        self.metadataByEpisodeID = metadataByEpisodeID
        self.availabilityByEpisodeID = availabilityByEpisodeID
    }
}

enum QueuePresentationBuilder {
    static func build(_ input: QueuePresentationInput) -> QueuePresentation {
        let upNext = input.manualQueueIDs.compactMap { row(for: $0, origin: .manual, input: input) }
        let autoplay = input.autoplay.compactMap { row(for: $0.episodeID, origin: .autoplay, input: input) }
        return QueuePresentation(
            upNext: upNext,
            autoplay: autoplay,
            isSmartAutoplayEnabled: input.isSmartAutoplayEnabled
        )
    }

    private static func row(for id: String, origin: QueueEpisodePresentation.Origin,
                            input: QueuePresentationInput) -> QueueEpisodePresentation? {
        guard let metadata = input.metadataByEpisodeID[id] else { return nil }
        let availability = input.availabilityByEpisodeID[id]
            ?? EpisodeAvailability(localAudio: .notDownloaded, preparation: .notRequested, readiness: .notDownloaded)
        return QueueEpisodePresentation(episodeID: id, title: metadata.title, podcastTitle: metadata.podcastTitle,
                                        availability: availability, origin: origin)
    }
}
