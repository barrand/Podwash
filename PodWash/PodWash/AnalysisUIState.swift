//
//  AnalysisUIState.swift
//  PodWash
//
//  Slice 09 — Cleaning UI display states (PRD §3, slice-09-ux.md).
//

import Foundation

/// Mutually exclusive badge / progress display states for the cleaning UI.
enum AnalysisUIState: String, Equatable, CaseIterable {
    case off
    case channelOn
    case episodeOn
    case analyzing

    /// Legal state-machine transitions exercised by `AnalysisUIViewModel.transition(to:)`.
    var legalNextStates: Set<AnalysisUIState> {
        switch self {
        case .off:
            [.channelOn, .episodeOn]
        case .channelOn:
            [.off, .analyzing]
        case .episodeOn:
            [.off, .analyzing]
        case .analyzing:
            [.channelOn, .episodeOn]
        }
    }
}
