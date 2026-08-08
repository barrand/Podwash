//
//  QueuePresentation.swift
//  PodWash
//

import Foundation

struct QueueEpisodePresentation: Identifiable, Equatable {
    let episodeID: String
    let title: String
    let podcastTitle: String
    let job: AnalysisJob?
    let isReadyOffline: Bool

    var id: String { episodeID }

    var statusText: String {
        guard let job else { return "Waiting to prepare" }
        if job.stage == .ready, job.detail == "Cleaning is off" {
            return "Ready to play · ad checks off"
        }
        return job.stage.userLabel
    }

    var progress: Double? {
        job?.stage == .downloading ? job?.estimate.progress : nil
    }
}

struct QueueStatusPresentation: Equatable {
    let text: String
    let accessibilityValue: String
}

struct QueuePresentation: Equatable {
    let upNext: [QueueEpisodePresentation]
    let readyToPlay: [QueueEpisodePresentation]
    let preparingCount: Int
    let activeStatus: QueueStatusPresentation?
}

enum QueueStatusResolver {
    static func resolve(
        foreground: AnalysisJob?,
        upNext: [QueueEpisodePresentation],
        automatic: [QueueEpisodePresentation]
    ) -> QueueStatusPresentation? {
        var jobs: [AnalysisJob] = []
        if let foreground { jobs.append(foreground) }
        jobs += upNext.compactMap(\.job)
        jobs += automatic.compactMap(\.job)
        guard let job = jobs.first(where: { $0.stage != .ready }) else { return nil }
        let detail = detailText(for: job)
        return QueueStatusPresentation(
            text: "\(detail) · \(job.title)",
            accessibilityValue: "\(detail), \(job.title)"
        )
    }

    static func detailText(for job: AnalysisJob) -> String {
        guard job.stage == .downloading, let progress = job.estimate.progress else {
            return job.stage.userLabel
        }
        return "Downloading \(Int((min(max(progress, 0), 1) * 100).rounded()))%"
    }
}
