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
