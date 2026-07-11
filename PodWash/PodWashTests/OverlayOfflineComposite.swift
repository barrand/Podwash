//
//  OverlayOfflineComposite.swift
//  PodWashTests
//
//  Slice 16 — Offline verification for overlay energy (ADR-017 §5 / AC3).
//
//  Renders the muted episode via `OfflineRenderRMS`, then software-mixes the pinned
//  beep fixture into mute intervals. Expected interior RMS thresholds come from the
//  beep's analytic peak (0.35 → RMS ≈ 0.247) and Slice 04 mute baseline (< 0.01),
//  not from OverlayEngine output.
//

import AVFoundation
import Foundation
@testable import PodWash

enum OverlayOfflineCompositeError: Error, CustomStringConvertible {
    case overlayFixtureMissing(String)
    case couldNotLoadOverlaySamples(String)
    case sampleRateMismatch(expected: Double, actual: Double)

    var description: String {
        switch self {
        case .overlayFixtureMissing(let name):
            return "OverlayOfflineComposite: missing overlay fixture '\(name)' in test bundle."
        case .couldNotLoadOverlaySamples(let detail):
            return "OverlayOfflineComposite: could not load overlay PCM — \(detail)"
        case .sampleRateMismatch(let expected, let actual):
            return "OverlayOfflineComposite: overlay sample rate \(actual) != render rate \(expected)."
        }
    }
}

enum OverlayOfflineComposite {

    /// Offline render for AC3: mute baseline + optional software-mixed beep interiors.
    static func render(
        fixtureNamed name: String,
        fixtureExtension: String,
        intervals: [CensorInterval],
        mode: MuteOverlayMode,
        fadeDuration: Double,
        overlayFixtureNamed overlayName: String = "beep-1khz",
        overlayFixtureExtension: String = "wav",
        loadedBy testClass: AnyClass
    ) async throws -> OfflineRenderRMS {
        let muted = try await OfflineRenderRMS.render(
            fixtureNamed: name,
            fixtureExtension: fixtureExtension,
            intervals: intervals,
            fadeDuration: fadeDuration,
            loadedBy: testClass
        )

        guard mode == .beep else {
            return muted
        }

        let overlaySamples = try loadMonoFloatSamples(
            named: overlayName,
            extension: overlayFixtureExtension,
            loadedBy: testClass
        )

        let mixed = mixOverlay(
            base: muted.samples,
            overlay: overlaySamples,
            renderStartTime: muted.startTime,
            muteIntervals: intervals.filter { $0.action == .mute }
        )
        return muted.replacingSamples(mixed)
    }

    // MARK: - PCM load / mix

    private static func loadMonoFloatSamples(
        named name: String,
        extension ext: String,
        loadedBy testClass: AnyClass
    ) throws -> [Float] {
        let bundle = Bundle(for: testClass)
        guard let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/audio")
            ?? bundle.url(forResource: name, withExtension: ext) else {
            throw OverlayOfflineCompositeError.overlayFixtureMissing("\(name).\(ext)")
        }

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate == OfflineRenderRMS.sampleRate else {
            throw OverlayOfflineCompositeError.sampleRateMismatch(
                expected: OfflineRenderRMS.sampleRate,
                actual: format.sampleRate
            )
        }

        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw OverlayOfflineCompositeError.couldNotLoadOverlaySamples("empty or unreadable file")
        }

        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            throw OverlayOfflineCompositeError.couldNotLoadOverlaySamples("no float channel data")
        }

        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    /// Adds overlay PCM into `base` for each mute interval (loops overlay if shorter).
    private static func mixOverlay(
        base: [Float],
        overlay: [Float],
        renderStartTime: TimeInterval,
        muteIntervals: [CensorInterval]
    ) -> [Float] {
        guard !overlay.isEmpty, !muteIntervals.isEmpty else { return base }

        var mixed = base
        let sampleRate = OfflineRenderRMS.sampleRate
        let firstAbsSample = Int((renderStartTime * sampleRate).rounded())

        for interval in muteIntervals {
            let startSample = max(0, Int((interval.start * sampleRate).rounded()) - firstAbsSample)
            let endSample = min(
                mixed.count,
                Int((interval.end * sampleRate).rounded()) - firstAbsSample
            )
            guard startSample < endSample else { continue }

            var overlayIndex = 0
            for i in startSample..<endSample {
                mixed[i] += overlay[overlayIndex]
                overlayIndex += 1
                if overlayIndex >= overlay.count {
                    overlayIndex = 0
                }
            }
        }

        return mixed
    }
}
