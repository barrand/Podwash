//
//  AudioMixRampInspector.swift
//  PodWashTests
//
//  Slice 08 — Test helper: extract mute ramp boundary times from an
//  AVMutableAudioMix for AC1 ±0.001 s asserts (ADR-006 §3, ADR-002 §4).
//

import AVFoundation
import Foundation

enum AudioMixRampInspector {

    /// Down-ramp ends (cached interval `start` values): ramps with startVolume > 0 → endVolume == 0.
    static func muteOnsetBoundaries(from mix: AVAudioMix, duration: TimeInterval) -> [TimeInterval] {
        guard let params = mix.inputParameters.first else { return [] }
        return scanBoundaries(
            in: params,
            duration: duration,
            matches: { startVol, endVol in startVol > 0.5 && endVol < 0.5 },
            boundary: { $0.end.seconds }
        )
    }

    /// Up-ramp starts (cached interval `end` values): ramps with startVolume == 0 → endVolume > 0.
    static func muteReleaseBoundaries(from mix: AVAudioMix, duration: TimeInterval) -> [TimeInterval] {
        guard let params = mix.inputParameters.first else { return [] }
        return scanBoundaries(
            in: params,
            duration: duration,
            matches: { startVol, endVol in startVol < 0.5 && endVol > 0.5 },
            boundary: { $0.start.seconds }
        )
    }

    private static func scanBoundaries(
        in params: AVAudioMixInputParameters,
        duration: TimeInterval,
        matches: (Float, Float) -> Bool,
        boundary: (CMTimeRange) -> TimeInterval
    ) -> [TimeInterval] {
        var seen = Set<Int>()
        var result: [TimeInterval] = []
        var t = 0.0
        let step = 0.001
        while t <= duration + step {
            var startVol: Float = 0
            var endVol: Float = 0
            var range = CMTimeRange.zero
            let time = CMTime(seconds: t, preferredTimescale: 44_100)
            if params.getVolumeRamp(for: time, startVolume: &startVol, endVolume: &endVol, timeRange: &range),
               matches(startVol, endVol) {
                let b = boundary(range)
                let key = Int((b * 1000).rounded())
                if seen.insert(key).inserted {
                    result.append(b)
                }
            }
            t += step
        }
        return result.sorted()
    }
}
