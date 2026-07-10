//
//  PlaybackTransporting.swift
//  PodWash
//
//  Slice 14 — Thin play/pause/seek surface for remote → engine forwarding (ADR-011).
//

import Foundation

/// Separate from `PlaybackPausing` (Slice 12 — pause-only). Do not widen that protocol.
@MainActor
protocol PlaybackTransporting: AnyObject {
    func play()
    func pause()
    func seek(to seconds: TimeInterval, completion: (() -> Void)?)
    func seek(by delta: TimeInterval)
}
