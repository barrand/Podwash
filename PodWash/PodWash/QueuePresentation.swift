//
//  QueuePresentation.swift
//  PodWash
//

import Foundation

struct QueueEpisodeMetadata: Equatable {
    let episodeID: String
    let title: String
    let podcastTitle: String
    let publicationDate: Date
    let isPlayed: Bool
}

enum QueueRowActivity: Equatable {
    case downloading(progress: Double?)
    case preparing
    case checkingAds
    case delayed
    case needsAttention

    var text: String {
        switch self {
        case .downloading(let progress):
            return PreparationStatusCopy.downloading(progress: progress)
        case .preparing: return PreparationStatusCopy.preparing
        case .checkingAds: return PreparationStatusCopy.checkingAds
        case .delayed: return "Ad check delayed"
        case .needsAttention: return "Needs attention"
        }
    }

    var progress: Double? {
        if case .downloading(let progress) = self { return progress }
        return nil
    }

    var showsIndeterminateProgress: Bool {
        self == .preparing || self == .checkingAds
    }
}

struct QueueEpisodePresentation: Identifiable, Equatable {
    let episodeID: String
    let title: String
    let podcastTitle: String
    let activity: QueueRowActivity?
    let isDownloaded: Bool

    var id: String { episodeID }
}

struct QueueStatusPresentation: Equatable {
    let text: String
    let accessibilityValue: String
}

struct QueuePresentation: Equatable {
    let upNext: [QueueEpisodePresentation]
    let downloads: [QueueEpisodePresentation]
    let activeStatus: QueueStatusPresentation?
}

struct QueuePresentationInput {
    let manualQueueIDs: [String]
    let downloadedEpisodeIDs: Set<String>
    let nowPlayingEpisodeID: String?
    let metadataByEpisodeID: [String: QueueEpisodeMetadata]
    let jobsByEpisodeID: [String: AnalysisJob]
    let foregroundJob: AnalysisJob?
}

enum QueuePresentationBuilder {
    static func build(_ input: QueuePresentationInput) -> QueuePresentation {
        let queueIDs = Set(input.manualQueueIDs)
        let upNext = input.manualQueueIDs.compactMap {
            row(for: $0, input: input, downloaded: input.downloadedEpisodeIDs.contains($0))
        }
        let downloads = input.downloadedEpisodeIDs
            .filter { id in
                id != input.nowPlayingEpisodeID
                    && !queueIDs.contains(id)
                    && input.metadataByEpisodeID[id]?.isPlayed == false
            }
            .compactMap { row(for: $0, input: input, downloaded: true) }
            .sorted { lhs, rhs in
                let lhsDate = input.jobsByEpisodeID[lhs.episodeID]?.updatedAt
                    ?? input.metadataByEpisodeID[lhs.episodeID]?.publicationDate
                    ?? .distantPast
                let rhsDate = input.jobsByEpisodeID[rhs.episodeID]?.updatedAt
                    ?? input.metadataByEpisodeID[rhs.episodeID]?.publicationDate
                    ?? .distantPast
                return lhsDate == rhsDate ? lhs.episodeID < rhs.episodeID : lhsDate > rhsDate
            }
        return QueuePresentation(
            upNext: upNext,
            downloads: downloads,
            activeStatus: QueueStatusResolver.resolve(foreground: input.foregroundJob, upNext: upNext, jobs: input.jobsByEpisodeID)
        )
    }

    private static func row(for id: String, input: QueuePresentationInput, downloaded: Bool) -> QueueEpisodePresentation? {
        guard let metadata = input.metadataByEpisodeID[id] else { return nil }
        return QueueEpisodePresentation(
            episodeID: id,
            title: metadata.title,
            podcastTitle: metadata.podcastTitle,
            activity: activity(for: input.jobsByEpisodeID[id]),
            isDownloaded: downloaded
        )
    }

    private static func activity(for job: AnalysisJob?) -> QueueRowActivity? {
        guard let job else { return nil }
        switch job.stage {
        case .ready: return nil
        case .queued, .transcribing: return .preparing
        case .downloading: return .downloading(progress: job.estimate.progress)
        case .checkingAds: return .checkingAds
        case .adCheckDelayed: return .delayed
        case .needsAttention: return .needsAttention
        }
    }
}

enum QueueStatusResolver {
    static func resolve(foreground: AnalysisJob?, upNext: [QueueEpisodePresentation], jobs: [String: AnalysisJob]) -> QueueStatusPresentation? {
        let job: AnalysisJob?
        if let foreground, foreground.stage != .ready {
            job = foreground
        } else {
            job = upNext.compactMap { jobs[$0.episodeID] }.first { $0.stage != .ready }
        }
        guard let job else { return nil }
        let activity = QueuePresentationBuilder.activityForStatus(job)
        return QueueStatusPresentation(text: "\(activity) · \(job.title)", accessibilityValue: "\(activity), \(job.title)")
    }
}

fileprivate extension QueuePresentationBuilder {
    static func activityForStatus(_ job: AnalysisJob) -> String {
        activity(for: job)?.text ?? "Ready"
    }
}
