//
//  OfflineRenderRMS.swift
//  PodWashTests
//
//  Slice 04 — offline-render RMS harness (ADR-002 §7, ADR-000 §2).
//
//  Renders a local WAV fixture through the *same* `AVMutableAudioMix` that
//  `IntervalScheduler.makeAudioMix(...)` builds (the object the player attaches),
//  drains the PCM into a `[Float]` in [-1, 1], and computes non-overlapping 10 ms
//  windowed RMS anchored at absolute asset time t=0. Classification helpers let the
//  AC2/AC3/AC5 assertions stay spec-derived (interval list + ADR-002 §4 ramp
//  placement) rather than code-derived — no golden is produced from scheduler output.
//
//  This is a QA test-target helper ONLY. It does not implement production behavior;
//  it references `IntervalScheduler` (added by the Engineer in a later effort), so
//  until that symbol exists this file is expected to fail to compile — that is the
//  intended TDD red state.
//

import AVFoundation
import Foundation
@testable import PodWash

/// One non-overlapping 10 ms RMS window, indexed in absolute asset time (anchored
/// at t=0 so a window's `[startTime, endTime]` is comparable to interval bounds
/// regardless of where the reader started).
struct RMSWindow {
    /// Absolute window index k: the window spans samples `[k·441, (k+1)·441)`.
    let index: Int
    /// Absolute start time in seconds (`k · 441 / 44100`).
    let startTime: TimeInterval
    /// Absolute end time in seconds (`(k+1) · 441 / 44100`).
    let endTime: TimeInterval
    /// `sqrt(mean(sample²))` over the 441 samples, full scale in [0, 1].
    let rms: Float
}

/// Which side of a mute interval a fade sits on (ADR-002 §4 places fades OUTSIDE
/// the interval: a down-ramp over `[s−f, s]` and an up-ramp over `[e, e+f]`).
enum FadeKind {
    /// The down-ramp preceding a mute interval's `start` (`1 → 0` over `[s−f, s]`).
    case muteOnset
    /// The up-ramp following a mute interval's `end` (`0 → 1` over `[e, e+f]`).
    case muteRelease
}

enum OfflineRenderError: Error, CustomStringConvertible {
    case fixtureMissing(String)
    case noMixReturned
    case noAudioTrack
    case readerCouldNotStart(Error?)
    case readerFailed(Error?)
    case noSamples

    var description: String {
        switch self {
        case .fixtureMissing(let name):
            return "OfflineRenderRMS setup failure: fixture '\(name)' not found in test bundle. "
                + "Generate it per PodWash/PodWashTests/Fixtures/audio/sine-300hz-5s.provenance.md."
        case .noMixReturned:
            return "OfflineRenderRMS setup failure: IntervalScheduler.makeAudioMix returned nil "
                + "for a schedule that contains .mute intervals (expected a non-nil mix)."
        case .noAudioTrack:
            return "OfflineRenderRMS setup failure: fixture asset has no audio track."
        case .readerCouldNotStart(let err):
            return "OfflineRenderRMS setup failure: AVAssetReader.startReading() returned false "
                + "(\(String(describing: err)))."
        case .readerFailed(let err):
            return "OfflineRenderRMS setup failure: AVAssetReader failed during draining "
                + "(\(String(describing: err)))."
        case .noSamples:
            return "OfflineRenderRMS setup failure: no PCM samples were drained from the reader."
        }
    }
}

/// The rendered PCM plus its windowed-RMS series and spec-derived classifiers.
struct OfflineRenderRMS {

    // MARK: - Constants (ADR-002 §7)

    /// Fixture / render sample rate (Hz).
    static let sampleRate: Double = 44_100
    /// 10 ms window = 441 samples at 44.1 kHz (non-overlapping, anchored at t=0).
    static let windowSampleCount: Int = 441
    /// Settle margin `M` used ONLY to classify windows (interior / exterior /
    /// don't-care transition), per ADR-002 §4/§7 "Revision (2026-07-08)".
    /// `AVAssetReaderAudioMixOutput` smooths commanded volume ramps over a ~20 ms
    /// floor and lags the transition, so a fade placed outside `[s, e]` bleeds
    /// ~20 ms into the interior. `M = 30 ms` covers that bleed: interior windows
    /// are classified as `⊆ [s + M, e − M]` and exterior windows as ≥ `M` from any
    /// boundary; the `[s − M, s + M]` / `[e − M, e + M]` bands are don't-care.
    static let settleMargin: Double = 0.030

    /// Mono PCM samples, Float32 in [-1, 1], in render order.
    let samples: [Float]
    /// Absolute asset time (s) of `samples[0]` — 0 unless a `reader.timeRange`
    /// start was requested. NOTE (ADR-002 §6 "Revision"): the reader must NOT be
    /// started inside a mute interval — it drops the pre-start ramp state and
    /// renders base volume — so AC5 renders from t=0 and asserts the interior at
    /// the seek target on the full-context render.
    let startTime: TimeInterval
    /// Non-overlapping 10 ms windows fully covered by `samples`, absolute-indexed.
    let windows: [RMSWindow]
    /// The interval list this render was built against (used by classifiers).
    let intervals: [CensorInterval]

    // MARK: - Render (ADR-000 §2 / ADR-002 §7)

    /// Loads the fixture, builds the mix via `IntervalScheduler.makeAudioMix`, and
    /// renders through `AVAssetReaderAudioMixOutput` using the *same* mix instance.
    ///
    /// - Parameter startTime: optional absolute start for the reader's `timeRange`.
    ///   When set, `samples[0]` corresponds to this absolute time and windows remain
    ///   anchored at absolute t=0. Do NOT set it to a point inside a mute interval:
    ///   the reader renders base volume there (ADR-002 §6). AC5 leaves it `nil`
    ///   (render from t=0) and asserts the interior window at the seek target.
    static func render(
        fixtureNamed name: String,
        fixtureExtension: String,
        intervals: [CensorInterval],
        fadeDuration: Double,
        startTime: TimeInterval? = nil,
        loadedBy testClass: AnyClass
    ) async throws -> OfflineRenderRMS {
        let bundle = Bundle(for: testClass)
        guard let url = bundle.url(forResource: name, withExtension: fixtureExtension, subdirectory: "Fixtures/audio")
            ?? bundle.url(forResource: name, withExtension: fixtureExtension) else {
            throw OfflineRenderError.fixtureMissing("\(name).\(fixtureExtension)")
        }

        let asset = AVURLAsset(url: url)

        // Same API the engine calls — the SAME mix object is rendered (ADR-000 §2).
        guard let mix = try await IntervalScheduler.makeAudioMix(
            for: asset,
            intervals: intervals,
            fadeDuration: fadeDuration
        ) else {
            throw OfflineRenderError.noMixReturned
        }

        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw OfflineRenderError.noAudioTrack }

        let reader = try AVAssetReader(asset: asset)

        // Deterministic LPCM Float32, mono, 44.1 kHz, interleaved (single channel):
        // samples land directly in [-1, 1] so RMS compares straight to 0.01 / 0.25.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: Int(sampleRate),
        ]

        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.audioMix = mix                     // the SAME instance
        reader.add(output)

        var renderStart: TimeInterval = 0
        if let startTime {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: startTime, preferredTimescale: CMTimeScale(sampleRate)),
                duration: .positiveInfinity
            )
            renderStart = startTime
        }

        guard reader.startReading() else {
            throw OfflineRenderError.readerCouldNotStart(reader.error)
        }

        var samples: [Float] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(sampleBuffer) }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            guard length > 0 else { continue }
            var data = Data(count: length)
            let copied: OSStatus = data.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: length,
                    destination: raw.baseAddress!
                )
            }
            guard copied == noErr else { continue }
            let floatCount = length / MemoryLayout<Float>.size
            data.withUnsafeBytes { raw in
                let base = raw.bindMemory(to: Float.self)
                samples.append(contentsOf: UnsafeBufferPointer(start: base.baseAddress, count: floatCount))
            }
        }

        if reader.status == .failed {
            throw OfflineRenderError.readerFailed(reader.error)
        }
        guard !samples.isEmpty else { throw OfflineRenderError.noSamples }

        let windows = Self.computeWindows(samples: samples, startTime: renderStart)
        return OfflineRenderRMS(
            samples: samples,
            startTime: renderStart,
            windows: windows,
            intervals: intervals
        )
    }

    // MARK: - Windowed RMS (anchored at absolute t=0)

    private static func computeWindows(samples: [Float], startTime: TimeInterval) -> [RMSWindow] {
        let n = samples.count
        let firstAbsSample = Int((startTime * sampleRate).rounded())
        // First absolute window index whose 441 samples are all present in `samples`.
        var k = Int((Double(firstAbsSample) / Double(windowSampleCount)).rounded(.up))
        var result: [RMSWindow] = []
        while true {
            let absStart = k * windowSampleCount
            let localStart = absStart - firstAbsSample
            let localEnd = localStart + windowSampleCount
            if localStart < 0 { k += 1; continue }
            if localEnd > n { break }
            var sumSq = 0.0
            for j in localStart..<localEnd {
                let v = Double(samples[j])
                sumSq += v * v
            }
            let rms = Float((sumSq / Double(windowSampleCount)).squareRoot())
            result.append(RMSWindow(
                index: k,
                startTime: Double(absStart) / sampleRate,
                endTime: Double(absStart + windowSampleCount) / sampleRate,
                rms: rms
            ))
            k += 1
        }
        return result
    }

    // MARK: - Classifiers (spec-derived, ADR-002 §7)

    private static let eps = 1e-9

    /// The **interior** windows of an interval: those lying entirely within the
    /// settle-inset region `[start + M, end − M]` (`M = settleMargin`), NOT the raw
    /// `[start, end]`. The renderer's ~20 ms ramp smoothing bleeds into the first
    /// ~20 ms of the interior (ADR-002 §4 "Revision"), so only the settled interior
    /// is provably silent (RMS < 0.01). The `[s − M, s + M]` / `[e − M, e + M]`
    /// transition bands are excluded as don't-care.
    func windowsFullyInside(_ interval: CensorInterval) -> [RMSWindow] {
        let low = interval.start + Self.settleMargin
        let high = interval.end - Self.settleMargin
        return windows.filter {
            $0.startTime >= low - Self.eps && $0.endTime <= high + Self.eps
        }
    }

    /// Windows lying entirely within a raw absolute time range (NO settle inset).
    /// Used by AC5 to target the interior window at the seek point (`[1.2, 1.3]`),
    /// which the caller has already verified sits inside `[s + M, e − M]`.
    func windows(fullyWithin range: ClosedRange<TimeInterval>) -> [RMSWindow] {
        windows.filter {
            $0.startTime >= range.lowerBound - Self.eps && $0.endTime <= range.upperBound + Self.eps
        }
    }

    /// Windows that are outside *every* interval by at least `margin` seconds on
    /// each side (i.e. clear of the transition band `[s − margin, e + margin]`).
    /// With `margin == settleMargin` these are the windows AC2 asserts as full
    /// volume (RMS > 0.25); measured min RMS on the pinned fixture is 0.6364.
    func windowsOutside(by margin: Double) -> [RMSWindow] {
        windows.filter { window in
            intervals.allSatisfy { interval in
                let before = window.endTime <= interval.start - margin + Self.eps
                let after = window.startTime >= interval.end + margin - Self.eps
                return before || after
            }
        }
    }

    /// Measures the fade transition width at a mute-interval boundary from the
    /// windowed-RMS series (ADR-002 §7 "AC3 duration").
    ///
    /// This measures the *rendered* transition (after `AVAssetReaderAudioMixOutput`
    /// smoothing), not the commanded ramp geometry. For a `.muteOnset` (down-ramp
    /// before `boundary` = interval start): width is the gap from the last
    /// full-volume window's end to the first silent window's start. For a
    /// `.muteRelease` (up-ramp after `boundary` = interval end): the gap from the
    /// last silent window's end to the first full-volume window's start. With the
    /// default `fadeDuration = 0.020 s` matched to the render floor, the measured
    /// width is ≈ 20 ms (ADR-002 §4/§7 "Empirical validation").
    ///
    /// `fullThreshold = 0.5` sits between a partly-attenuated transition-band window
    /// (~amplitude/√6 ≈ 0.367 at amplitude 0.9) and a full-scale window (~0.636) so
    /// a partial ramp window is not misclassified as full; `silentThreshold` matches
    /// AC2's mute bound.
    func measuredFadeWidth(
        boundary: Double,
        kind: FadeKind,
        fullThreshold: Float = 0.5,
        silentThreshold: Float = 0.01
    ) -> TimeInterval? {
        switch kind {
        case .muteOnset:
            guard let lastFull = windows.last(where: {
                $0.endTime <= boundary + Self.eps && $0.rms > fullThreshold
            }) else { return nil }
            guard let firstSilent = windows.first(where: {
                $0.startTime >= lastFull.endTime - Self.eps && $0.rms < silentThreshold
            }) else { return nil }
            return firstSilent.startTime - lastFull.endTime
        case .muteRelease:
            guard let firstFull = windows.first(where: {
                $0.startTime >= boundary - Self.eps && $0.rms > fullThreshold
            }) else { return nil }
            guard let lastSilent = windows.last(where: {
                $0.endTime <= firstFull.startTime + Self.eps && $0.rms < silentThreshold
            }) else { return nil }
            return firstFull.startTime - lastSilent.endTime
        }
    }

    /// Maximum absolute adjacent-sample difference over raw PCM within `±windowRadius`
    /// 10 ms windows of `boundary` (ADR-002 §7 "AC3 continuity"). On the pinned 300 Hz
    /// / amplitude-0.9 fixture the sine's inherent slew is ≈ 0.0385; a mix-induced
    /// click (e.g. a hard cut) shows up as a larger step.
    func maxAdjacentDelta(aroundTime boundary: Double, windowRadius: Int = 1) -> Float {
        let windowDuration = Double(Self.windowSampleCount) / Self.sampleRate
        let lo = boundary - Double(windowRadius) * windowDuration
        let hi = boundary + Double(windowRadius) * windowDuration
        let firstAbsSample = Int((startTime * Self.sampleRate).rounded())
        let loIdx = max(0, Int((lo * Self.sampleRate).rounded()) - firstAbsSample)
        let hiIdx = min(samples.count, Int((hi * Self.sampleRate).rounded()) - firstAbsSample)
        var maxDelta: Float = 0
        var i = loIdx + 1
        while i < hiIdx {
            let d = abs(samples[i] - samples[i - 1])
            if d > maxDelta { maxDelta = d }
            i += 1
        }
        return maxDelta
    }

    // MARK: - Slice 16 overlay composite (test harness)

    /// Recomputes windowed RMS after software-mixing overlay PCM into `mixedSamples`.
    /// Caller must preserve `samples.count`; used by `OverlayOfflineComposite` (ADR-017 §5).
    func replacingSamples(_ mixedSamples: [Float]) -> OfflineRenderRMS {
        precondition(mixedSamples.count == samples.count, "mixed sample count must match base render")
        let windows = Self.computeWindows(samples: mixedSamples, startTime: startTime)
        return OfflineRenderRMS(
            samples: mixedSamples,
            startTime: startTime,
            windows: windows,
            intervals: intervals
        )
    }
}
