//
//  OverlayEventRecording.swift
//  PodWash
//
//  Slice 16 — Injectable overlay start/stop recording (ADR-017 §3).
//

import Foundation

/// Player-timeline overlay events (seconds on the AVPlayer clock).
protocol OverlayEventRecording: AnyObject {
    func overlayStart(at time: TimeInterval, assetID: String)
    func overlayStop(at time: TimeInterval)
}
