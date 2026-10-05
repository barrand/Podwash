//
//  PreparationFailureRecovery.swift
//  PodWash
//
//  One typed, listener-safe presentation of terminal episode preparation errors.
//

import Foundation

extension AnalysisJob {
    /// Maps legacy checkpoints written before `failureReason` existed. New job
    /// writers must always set the typed value for terminal failures.
    var resolvedFailureReason: PreparationFailureReason? {
        guard stage == .needsAttention else { return nil }
        if let failureReason { return failureReason }
        if let cloudFailure { return .cloud(cloudFailure) }
        switch detail {
        case "No downloadable audio": return .noDownloadableAudio
        case "Download failed": return .downloadFailed
        default: return .localPreparationFailed
        }
    }
}

struct PreparationIssue: Identifiable, Equatable {
    let episodeID: String
    let episodeTitle: String
    let reason: PreparationFailureReason
    let hasVerifiedLocalAudio: Bool

    var id: String { episodeID }
}

struct PreparationIssuePresentation: Equatable {
    let shortStatus: String
    let explanation: String
    let diagnosticCode: String
    let allowsRetry: Bool
    let allowsOriginalPlayback: Bool
}

enum PreparationIssuePresentationMapper {
    static func map(_ issue: PreparationIssue) -> PreparationIssuePresentation {
        let allowsOriginal = issue.hasVerifiedLocalAudio && issue.reason.allowsOriginalPlayback
        switch issue.reason {
        case .noDownloadableAudio:
            return PreparationIssuePresentation(
                shortStatus: "Audio unavailable",
                explanation: "The publisher did not provide downloadable audio for this episode, so PodWash can’t prepare it.",
                diagnosticCode: "PW-PREP-NO-AUDIO",
                allowsRetry: false,
                allowsOriginalPlayback: false
            )
        case .downloadFailed:
            return PreparationIssuePresentation(
                shortStatus: "Download failed",
                explanation: "PodWash couldn’t download the episode. Check your connection and try again.",
                diagnosticCode: "PW-PREP-DOWNLOAD",
                allowsRetry: true,
                allowsOriginalPlayback: false
            )
        case .localPreparationFailed:
            return PreparationIssuePresentation(
                shortStatus: "Local preparation failed",
                explanation: "The episode downloaded, but PodWash couldn’t finish preparing clean playback.",
                diagnosticCode: "PW-PREP-LOCAL",
                allowsRetry: true,
                allowsOriginalPlayback: allowsOriginal
            )
        case let .cloud(category):
            return PreparationIssuePresentation(
                shortStatus: "Ad check failed",
                explanation: "The episode downloaded, but the ad check couldn’t finish. You can try again or play the original audio.",
                diagnosticCode: "PW-PREP-CLOUD-\(category.diagnosticCodeComponent)",
                allowsRetry: true,
                allowsOriginalPlayback: allowsOriginal
            )
        }
    }
}

extension PreparationFailureReason {
    var allowsOriginalPlayback: Bool {
        switch self {
        case .localPreparationFailed, .cloud: return true
        case .noDownloadableAudio, .downloadFailed: return false
        }
    }
}

private extension CloudAdDetectionFailureCategory {
    var diagnosticCodeComponent: String {
        rawValue.reduce(into: "") { result, character in
            if character.isUppercase, !result.isEmpty { result.append("-") }
            result.append(contentsOf: character.uppercased())
        }
    }
}
