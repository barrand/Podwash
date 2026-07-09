//
//  IntervalScheduler.swift
//  PodWash
//
//  Slice 04 — Interval mute/skip (ADR-002). Pure builder of the
//  `AVMutableAudioMix` (mute ramps) from `[CensorInterval]` plus skip-interval
//  helpers. No AVPlayer coupling — the mix is a value the engine and the
//  offline-render test share (ADR-000 §2 "same mix" guarantee).
//

import AVFoundation
import Foundation

/// A censor schedule handed to `PlaybackEngine`. Wraps `IntervalBuilder` output
/// verbatim — `intervals` is the merged `[CensorInterval]` from Slice 02 with no
/// additional padding/merge math applied here (AC1).
struct IntervalSchedule: Equatable {
    let intervals: [CensorInterval]
    let fadeDuration: Double

    init(
        intervals: [CensorInterval],
        fadeDuration: Double = IntervalScheduler.defaultFadeDuration
    ) {
        self.intervals = intervals
        self.fadeDuration = fadeDuration
    }
}

enum IntervalSchedulerError: Error {
    case noAudioTrack
}

enum IntervalScheduler {

    /// Default fade ramp window applied on each side of every mute interval.
    /// 20 ms matches the renderer's ~20 ms volume-smoothing floor so the measured
    /// fade width equals the configured value (ADR-002 §4 Revision).
    nonisolated static let defaultFadeDuration: Double = 0.020   // 20 ms — ADR-002 §4 Revision

    /// Fine timescale so ramp edges land accurately for the 10 ms-window RMS test.
    nonisolated private static let rampTimescale: CMTimeScale = 44_100

    /// Builds the SAME `AVMutableAudioMix` the player attaches, so the
    /// offline-render test (ADR-000 §2) can render with the identical object.
    /// Consumes `CensorInterval` values directly (AC1). Ramps are applied for
    /// `.mute` intervals only; `.skip` intervals are ignored here (handled by
    /// seek-past on the engine).
    ///
    /// Returns `nil` when there are no `.mute` intervals. Throws `.noAudioTrack`
    /// if the asset has no audio track.
    nonisolated static func makeAudioMix(
        for asset: AVAsset,
        intervals: [CensorInterval],
        fadeDuration: Double = defaultFadeDuration
    ) async throws -> AVMutableAudioMix? {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw IntervalSchedulerError.noAudioTrack
        }

        let mutes = intervals
            .filter { $0.action == .mute }
            .sorted { $0.start < $1.start }
        guard !mutes.isEmpty else { return nil }

        let params = AVMutableAudioMixInputParameters(track: track)
        params.setVolume(1.0, at: .zero)

        let fade = max(0, fadeDuration)

        for i in mutes.indices {
            let interval = mutes[i]
            let s = interval.start
            let e = interval.end

            // Down-ramp `1 → 0` over `[s − f, s]` (fade sits OUTSIDE the interval,
            // ADR-002 §4). Clamp to t=0 and, if the previous interval is closer
            // than 2·f, split the gap at its midpoint so ramps never overlap.
            var downStart = max(0, s - fade)
            if i > 0 {
                let midpoint = (mutes[i - 1].end + s) / 2.0
                downStart = max(downStart, midpoint)
            }

            // Up-ramp `0 → 1` over `[e, e + f]`. Clamp against the next interval's
            // down-ramp at the gap midpoint (same reasoning as above).
            var upEnd = e + fade
            if i < mutes.count - 1 {
                let midpoint = (e + mutes[i + 1].start) / 2.0
                upEnd = min(upEnd, midpoint)
            }

            let downRange = CMTimeRange(
                start: CMTime(seconds: downStart, preferredTimescale: rampTimescale),
                end: CMTime(seconds: s, preferredTimescale: rampTimescale)
            )
            params.setVolumeRamp(fromStartVolume: 1.0, toEndVolume: 0.0, timeRange: downRange)

            let upRange = CMTimeRange(
                start: CMTime(seconds: e, preferredTimescale: rampTimescale),
                end: CMTime(seconds: upEnd, preferredTimescale: rampTimescale)
            )
            params.setVolumeRamp(fromStartVolume: 0.0, toEndVolume: 1.0, timeRange: upRange)
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }

    /// The `.skip` subset, sorted ascending by start — feeds the engine's boundary
    /// observer. Consumes `CensorInterval` directly (AC1).
    nonisolated static func skipIntervals(from intervals: [CensorInterval]) -> [CensorInterval] {
        intervals
            .filter { $0.action == .skip }
            .sorted { $0.start < $1.start }
    }

    /// The first `.skip` interval whose `start` is at/after `time` and whose `end`
    /// is still ahead of `time` (the next skip the playhead will enter). `nil` if
    /// none.
    nonisolated static func nextSkip(
        after time: TimeInterval,
        in intervals: [CensorInterval]
    ) -> CensorInterval? {
        skipIntervals(from: intervals).first { $0.start >= time && $0.end > time }
    }
}
