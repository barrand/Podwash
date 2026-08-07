//
//  PreparationShelfView.swift
//  PodWash
//

import SwiftUI

/// A compact entry point to the listener's upcoming playback queue.
struct QueueStatusButton: View {
    let jobs: [AnalysisJob]
    let onOpen: () -> Void

    var body: some View {
        let ready = jobs.filter(\.isReadyForAutomaticPlayback).count
        let active = jobs.first { $0.stage != .ready }
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                Text("Queue")
                    .fontWeight(.semibold)
                Text(statusText(active: active))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("queueButton")
        .accessibilityLabel("Queue")
        .accessibilityValue(accessibilityValue(active: active, ready: ready))
        .accessibilityHint("Shows upcoming episodes and their preparation status.")
    }

    private func statusText(active: AnalysisJob?) -> String {
        guard !jobs.isEmpty else { return "Empty" }
        if let active {
            return "\(jobs.count) items · \(active.compactShelfStatus())"
        }
        return "\(jobs.count) items · all ready"
    }

    private func accessibilityValue(active: AnalysisJob?, ready: Int) -> String {
        guard !jobs.isEmpty else { return "Empty" }
        let status = active?.compactShelfStatus() ?? "all ready"
        return "\(jobs.count) items, \(ready) ready, \(status)"
    }
}

struct PreparationDetailView: View {
    let jobs: [AnalysisJob]
    let onRetry: (String) -> Void
    let onPlayWithAds: (String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if jobs.isEmpty {
                    ContentUnavailableView(
                        "Your queue is empty",
                        systemImage: "text.line.first.and.arrowtriangle.forward",
                        description: Text("Add episodes from a podcast to play them next.")
                    )
                    .accessibilityIdentifier("queueEmpty")
                } else {
                    ForEach(jobs) { job in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(job.title).fontWeight(.semibold)
                                Spacer()
                                Text(job.stage.userLabel).foregroundStyle(.secondary)
                            }
                            if let progress = job.estimate.progress, job.stage == .downloading {
                                ProgressView(value: progress)
                            }
                            if job.stage == .adCheckDelayed || job.stage == .needsAttention {
                                Text(job.detail ?? (job.stage == .adCheckDelayed
                                    ? "Ad check delayed · Retrying automatically"
                                    : "Ad check needs attention"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Button("Retry now") { onRetry(job.episodeID) }
                                    Button("Play with ads") { onPlayWithAds(job.episodeID) }
                                }
                                .buttonStyle(.bordered)
                            } else if let detail = job.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                            #if DEBUG
                            debugCloudDiagnostics(for: job)
                            #endif
                        }
                        .accessibilityIdentifier("preparationJob_\(job.episodeID)")
                    }
                }
            }
            .navigationTitle("Queue")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDismiss)
                }
            }
        }
    }

    #if DEBUG
    @ViewBuilder
    private func debugCloudDiagnostics(for job: AnalysisJob) -> some View {
        if job.stage == .checkingAds || job.stage == .adCheckDelayed || job.stage == .needsAttention {
            VStack(alignment: .leading, spacing: 2) {
                Text("Debug cloud diagnostics")
                    .font(.caption2.weight(.semibold))
                Text("stage=\(job.stage.rawValue) attempts=\(job.retryCount + 1)")
                if let failure = job.cloudFailure {
                    Text("failure=\(failure.rawValue)")
                }
                if let retryAfter = job.retryAfter {
                    Text("retry=\(retryAfter.formatted(date: .omitted, time: .shortened))")
                }
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(6)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityIdentifier("preparationCloudDiagnostics_\(job.episodeID)")
            .accessibilityLabel("Debug cloud diagnostics")
            .accessibilityValue(debugCloudAccessibilityValue(for: job))
        }
    }

    private func debugCloudAccessibilityValue(for job: AnalysisJob) -> String {
        let failure = job.cloudFailure?.rawValue ?? "none"
        return "stage:\(job.stage.rawValue),attempts:\(job.retryCount + 1),failure:\(failure)"
    }
    #endif
}
