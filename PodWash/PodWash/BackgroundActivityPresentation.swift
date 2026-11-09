import Foundation

/// A live activity snapshot, independent of manual queue membership.
struct BackgroundActivityPresentation: Equatable {
    let episodeID: String?
    let title: String
    let status: String
    let symbol: String
    let additionalCount: Int
    let failureID: String?

    var isFailure: Bool { failureID != nil }
    var text: String { title.isEmpty ? status : "\(status): \(title)" }
    var accessibilityLabel: String {
        guard additionalCount > 0 else { return text }
        return text + ", \(additionalCount) more " + (additionalCount == 1 ? "activity" : "activities")
    }
}

struct ActivityDownload {
    let episodeID: String
    let title: String
    let progress: Double
}

enum BackgroundActivityResolver {
    static func resolve(
        foreground: AnalysisJob?,
        ownedJobs: [AnalysisJob],
        downloads: [ActivityDownload],
        isRefreshingFeeds: Bool,
        dismissedFailureIDs: Set<String> = []
    ) -> BackgroundActivityPresentation? {
        struct Candidate {
            let episodeID: String?
            let title: String
            let status: String
            let symbol: String
            let priority: Int
            let failureID: String?
        }
        var candidates: [Candidate] = []
        var jobs = Dictionary(ownedJobs.map { ($0.episodeID, $0) }, uniquingKeysWith: { a, _ in a })
        if let foreground, [.transcribing, .checkingAds, .needsAttention].contains(foreground.stage) {
            jobs[foreground.episodeID] = foreground
        }
        let downloadingIDs = Set(downloads.map(\.episodeID))
        for job in jobs.values {
            let status: String
            let symbol: String
            var failureID: String?
            switch job.stage {
            case .transcribing:
                status = "Preparing"
                symbol = "waveform"
            case .checkingAds:
                status = "Checking for ads"
                symbol = "sparkles"
            case .needsAttention:
                let id = "\(job.episodeID):\(job.updatedAt.timeIntervalSince1970)"
                guard !dismissedFailureIDs.contains(id) else { continue }
                failureID = id
                status = job.resolvedFailureReason == .downloadFailed ? "Download failed" : "Preparation needs attention"
                symbol = "exclamationmark.circle"
            // Queued, delayed retries, and completed records are not running work.
            case .queued, .downloading, .ready, .adCheckDelayed:
                continue
            }
            // A new download supersedes an old preparation checkpoint.
            guard !downloadingIDs.contains(job.episodeID) else { continue }
            candidates.append(Candidate(episodeID: job.episodeID, title: job.title, status: status,
                symbol: symbol, priority: failureID != nil ? 0 : (foreground?.episodeID == job.episodeID ? 1 : 2),
                failureID: failureID))
        }
        for download in downloads {
            let progress = download.progress
            let percent = progress.isFinite ? Int((min(1, max(0, progress)) * 100).rounded()) : nil
            candidates.append(Candidate(episodeID: download.episodeID, title: download.title,
                status: percent.map { "Downloading · \($0)%" } ?? "Downloading", symbol: "arrow.down.circle",
                priority: foreground?.episodeID == download.episodeID ? 1 : 2, failureID: nil))
        }
        if isRefreshingFeeds {
            candidates.append(Candidate(episodeID: nil, title: "", status: "Refreshing podcasts",
                symbol: "arrow.trianglehead.2.clockwise.rotate.90", priority: 3, failureID: nil))
        }
        candidates.sort {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return ($0.episodeID ?? "") < ($1.episodeID ?? "")
        }
        guard let first = candidates.first else { return nil }
        return BackgroundActivityPresentation(episodeID: first.episodeID, title: first.title,
            status: first.status, symbol: first.symbol, additionalCount: candidates.count - 1,
            failureID: first.failureID)
    }
}
