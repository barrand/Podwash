//
//  ContentSegmenting.swift
//  PodWash
//
//  Cloud Gemini ad-span response mapped to playback intervals.
//

import Foundation

/// Positive-class superfluous / tangential span (seconds from episode start).
/// Slice 19 maps these to `CensorInterval` with the user-selected action.
nonisolated struct ContentSegment: Codable, Equatable, Sendable {
    let start: Double
    let end: Double
}
