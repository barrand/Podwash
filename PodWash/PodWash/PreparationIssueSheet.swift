//
//  PreparationIssueSheet.swift
//  PodWash
//

import SwiftUI

struct PreparationIssueSheet: View {
    let issue: PreparationIssue
    let onRetry: () -> Void
    let onPlayOriginal: () -> Void
    let onDone: () -> Void

    private var presentation: PreparationIssuePresentation {
        PreparationIssuePresentationMapper.map(issue)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text(issue.episodeTitle)
                    .font(.headline)
                    .lineLimit(2)

                Text(presentation.explanation)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Preparation error code")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(presentation.diagnosticCode)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .accessibilityLabel("Preparation error code")
                        .accessibilityValue(presentation.diagnosticCode)
                        .accessibilityIdentifier("preparationIssueCode")
                }

                Spacer(minLength: 0)

                VStack(spacing: 10) {
                    if presentation.allowsRetry {
                        Button("Try Again", action: onRetry)
                            .buttonStyle(.borderedProminent)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("preparationIssueRetry")
                    }
                    if presentation.allowsOriginalPlayback {
                        Button("Play Original Audio", action: onPlayOriginal)
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("preparationIssuePlayOriginal")
                    }
                    Button("Done", action: onDone)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("preparationIssueDone")
                }
            }
            .padding()
            .navigationTitle("Couldn’t prepare this episode")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("preparationIssueSheet")
        }
        .presentationDetents([.medium])
    }
}
