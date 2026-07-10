//
//  EpisodePlaying.swift
//  PodWash
//
//  Slice 11 — Injectable player seam for queue auto-advance (ADR-009 §5).
//

import Foundation

@MainActor
protocol EpisodePlaying: AnyObject {
    /// Start or switch playback to `episodeID` (resolve URL upstream in production).
    func play(episodeID: String)
    func pause()
    func seek(to seconds: TimeInterval)
}
