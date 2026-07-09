//
//  TimedWord.swift
//  PodWash
//
//  Slice 02 — Matching engine.
//  Shared word-level transcript schema pinned by ADR-000 §4. ASR (Slice 05)
//  produces this type; the matcher (Slice 02) consumes it; fixtures encode it.
//  Schema changes require a superseding ADR.
//

import Foundation

/// A single ASR-produced token with its start/end offset (seconds from episode
/// start). Matches the Codable JSON schema in ADR-000 §4 exactly:
/// `{ "word": String, "start": Double, "end": Double }`.
nonisolated struct TimedWord: Codable, Equatable {
    let word: String
    let start: Double
    let end: Double
}
