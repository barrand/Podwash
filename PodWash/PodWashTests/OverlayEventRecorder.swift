//
//  OverlayEventRecorder.swift
//  PodWashTests
//
//  Slice 16 — Test double for OverlayEventRecording (ADR-017 §3).
//  Records overlay start/stop in player-timeline seconds for sync assertions.
//
//  Provenance: event pairing logic is spec-derived from ADR-017 §4 (start at
//  interval start, stop at interval end). No dependency on OverlayEngine output.
//

import Foundation
@testable import PodWash

/// Records `overlayStart` / `overlayStop` calls for Slice 16 sync ACs.
final class OverlayEventRecorder: OverlayEventRecording {

    struct StartEvent: Equatable {
        let time: TimeInterval
        let assetID: String
    }

    struct StopEvent: Equatable {
        let time: TimeInterval
    }

    private(set) var startEvents: [StartEvent] = []
    private(set) var stopEvents: [StopEvent] = []
    private(set) var activeOverlayCount: Int = 0

    private var activeIntervals: [(start: TimeInterval, end: TimeInterval)] = []

    func reset() {
        startEvents.removeAll()
        stopEvents.removeAll()
        activeOverlayCount = 0
        activeIntervals.removeAll()
    }

    func overlayStart(at time: TimeInterval, assetID: String) {
        startEvents.append(StartEvent(time: time, assetID: assetID))
        activeOverlayCount += 1
        activeIntervals.append((start: time, end: .infinity))
    }

    func overlayStop(at time: TimeInterval) {
        stopEvents.append(StopEvent(time: time))
        activeOverlayCount = max(0, activeOverlayCount - 1)
        if let lastIndex = activeIntervals.lastIndex(where: { $0.end.isInfinite }) {
            let open = activeIntervals[lastIndex]
            activeIntervals[lastIndex] = (start: open.start, end: time)
        }
    }

    /// True when any recorded active span overlaps `range` (half-open [start, end)).
    func wasActive(during range: ClosedRange<TimeInterval>) -> Bool {
        for span in activeIntervals {
            let spanEnd = span.end.isInfinite ? Double.greatestFiniteMagnitude : span.end
            if span.start < range.upperBound && spanEnd > range.lowerBound {
                return true
            }
        }
        return false
    }

    /// Sample count proxy for AC2 exterior windows: returns non-zero when overlay
    /// was active during the window (10 ms windows use the same timebase).
    func overlayActiveSampleCount(inWindow range: ClosedRange<TimeInterval>) -> Int {
        wasActive(during: range) ? 1 : 0
    }
}
