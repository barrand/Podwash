//
//  AnalysisJob.swift
//  PodWash
//
//  Durable, user-facing preparation state for download + local analysis + ad detection.
//

import Foundation

enum AnalysisJobStage: String, Codable, CaseIterable, Sendable {
    case queued
    case downloading
    case transcribing
    case checkingAds
    case ready
    case adCheckDelayed
    case needsAttention

    var userLabel: String {
        switch self {
        case .queued: return "Waiting to prepare"
        case .downloading: return "Downloading"
        case .transcribing: return "Preparing clean playback"
        case .checkingAds: return "Checking for ads"
        case .ready: return "Ready"
        case .adCheckDelayed: return "Ad check delayed"
        case .needsAttention: return "Needs attention"
        }
    }
}

struct AnalysisJobEstimate: Codable, Equatable, Sendable {
    /// A value is published only for measured local work (download / transcription).
    var secondsRemaining: TimeInterval?
    var progress: Double?
}

struct AnalysisJob: Codable, Equatable, Identifiable, Sendable {
    let episodeID: String
    var title: String
    var stage: AnalysisJobStage
    var estimate: AnalysisJobEstimate
    var updatedAt: Date
    var retryAfter: Date?
    var detail: String?
    /// Never contains transcript data; used for recovery and listener-safe copy.
    var cloudFailure: CloudAdDetectionFailureCategory? = nil
    var retryCount: Int = 0

    var id: String { episodeID }

    var isReadyForAutomaticPlayback: Bool { stage == .ready }
    var isDelayed: Bool { stage == .adCheckDelayed }

    /// Short, listener-facing status for the single-line preparation shelf.
    /// The numbered steps describe the normal clean-playback path; terminal and
    /// recovery states deliberately stay unnumbered so we do not imply progress
    /// that cannot be measured.
    func compactShelfStatus(now: Date = Date()) -> String {
        switch stage {
        case .queued:
            return "1/4 Waiting to prepare"
        case .downloading:
            return compactProgressStatus(step: "2/4 Downloading")
        case .transcribing:
            return compactProgressStatus(step: "3/4 Preparing clean playback")
        case .checkingAds:
            return "4/4 Checking for ads · \(Self.elapsedText(since: updatedAt, now: now))"
        case .ready:
            return "Ready"
        case .adCheckDelayed:
            guard let retryAfter else { return "4/4 Ad check delayed · retrying automatically" }
            let remaining = retryAfter.timeIntervalSince(now)
            return remaining <= 0
                ? "4/4 Ad check delayed · retrying now"
                : "4/4 Ad check delayed · retrying in \(Self.remainingTimeText(remaining))"
        case .needsAttention:
            return detail.map { "Needs attention · \($0)" } ?? "Needs attention"
        }
    }

    private func compactProgressStatus(step: String) -> String {
        var parts = [step]
        if let progress = estimate.progress {
            parts.append("\(Int((min(max(progress, 0), 1) * 100).rounded()))%")
        }
        if let remaining = estimate.secondsRemaining, remaining > 0 {
            parts.append("\(Self.remainingTimeText(remaining)) left")
        }
        return parts.joined(separator: " · ")
    }

    private static func elapsedText(since start: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(start))
        if seconds < 60 { return "\(Int(seconds.rounded()))s elapsed" }
        return "\(Int((seconds / 60).rounded()))m elapsed"
    }

    private static func remainingTimeText(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "under 1 min" }
        if seconds < 3_600 { return "~\(Int((seconds / 60).rounded())) min" }
        return "~\(Int((seconds / 3_600).rounded())) hr"
    }
}

/// Small checkpoint store. Live byte/chunk updates stay in memory; only recovery-relevant
/// transitions are persisted so relaunches can explain and resume work without Core Data migration.
struct AnalysisJobStore: Sendable {
    private let defaults: UserDefaults
    private let key = "podwash.analysisJobs.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [String: AnalysisJob] {
        guard let data = defaults.data(forKey: key),
              let jobs = try? JSONDecoder().decode([String: AnalysisJob].self, from: data)
        else { return [:] }
        return jobs
    }

    func save(_ jobs: [String: AnalysisJob]) {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        defaults.set(data, forKey: key)
    }
}
