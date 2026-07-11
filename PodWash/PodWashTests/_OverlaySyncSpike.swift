//
//  _OverlaySyncSpike.swift — THROWAWAY measurement for ADR-017.
//  Delete after recording results. Not a Done-gate test.
//

import AVFoundation
import XCTest

final class OverlaySyncSpike: XCTestCase {

    /// Measures AVPlayer boundary-observer fire time vs commanded interval bounds
    /// on the pinned Slice 04 fixture. Prints a SPIKE RESULT block for the ADR.
    func testMeasureBoundaryObserverJitter() async throws {
        let bundle = Bundle(for: OverlaySyncSpike.self)
        guard let url = bundle.url(
            forResource: "sine-300hz-5s",
            withExtension: "wav",
            subdirectory: "Fixtures/audio"
        ) ?? bundle.url(forResource: "sine-300hz-5s", withExtension: "wav") else {
            XCTFail("sine-300hz-5s.wav missing")
            return
        }

        let intervals: [(start: Double, end: Double)] = [(1.0, 1.5), (3.0, 3.4)]
        let commandedStarts = intervals.map(\.start)
        let commandedEnds = intervals.map(\.end)
        let allBounds = commandedStarts + commandedEnds

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false

        // Wait until ready.
        let ready = expectation(description: "item ready")
        let obs = item.observe(\.status, options: [.new]) { item, _ in
            if item.status == .readyToPlay { ready.fulfill() }
        }
        await fulfillment(of: [ready], timeout: 10)
        obs.invalidate()

        var fireTimes: [Double] = []
        let lock = NSLock()
        let times = allBounds.map {
            NSValue(time: CMTime(seconds: $0, preferredTimescale: 600))
        }

        let token = player.addBoundaryTimeObserver(forTimes: times, queue: .main) {
            let t = player.currentTime().seconds
            lock.lock()
            fireTimes.append(t)
            lock.unlock()
        }

        player.play()

        // Wait until past last boundary + margin.
        let done = expectation(description: "past last bound")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 15)
        player.pause()
        player.removeTimeObserver(token)

        lock.lock()
        let observed = fireTimes.sorted()
        lock.unlock()

        // Pair chronologically: sort commanded bounds so zip matches fire order.
        let commandedSorted = allBounds.sorted()
        XCTAssertGreaterThanOrEqual(
            observed.count,
            commandedSorted.count,
            "Expected ≥\(commandedSorted.count) fires, got \(observed.count): \(observed)"
        )

        let paired = Array(observed.prefix(commandedSorted.count))
        var maxAbsError = 0.0
        var errors: [(commanded: Double, observed: Double, absError: Double)] = []
        for (cmd, obsT) in zip(commandedSorted, paired) {
            let err = abs(obsT - cmd)
            maxAbsError = max(maxAbsError, err)
            errors.append((cmd, obsT, err))
        }

        // Secondary path: AVAudioPlayer prepare+play latency from a schedule call
        // (simulates overlay start after boundary fire).
        let beepURL = try makeTempBeepWAV()
        let audioPlayer = try AVAudioPlayer(contentsOf: beepURL)
        audioPlayer.prepareToPlay()
        let t0 = CFAbsoluteTimeGetCurrent()
        XCTAssertTrue(audioPlayer.play())
        // Sample currentTime until > 0 or timeout — proxy for audible start.
        var startLatency = 0.0
        let deadline = CFAbsoluteTimeGetCurrent() + 0.5
        while CFAbsoluteTimeGetCurrent() < deadline {
            if audioPlayer.isPlaying, audioPlayer.currentTime > 0 {
                startLatency = CFAbsoluteTimeGetCurrent() - t0
                break
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        audioPlayer.stop()
        try? FileManager.default.removeItem(at: beepURL)

        print("=== SPIKE RESULT overlay-sync ===")
        print("device: simulator")
        print("fixture: sine-300hz-5s.wav")
        print("commanded_bounds_sorted: \(commandedSorted)")
        print("observed_fires: \(paired)")
        for e in errors {
            print(String(format: "bound %.3f → observed %.4f  |err|=%.4f s",
                         e.commanded, e.observed, e.absError))
        }
        print(String(format: "max_abs_boundary_error_s: %.4f", maxAbsError))
        print(String(format: "avaudioplayer_start_latency_s: %.4f", startLatency))
        print(String(format: "combined_budget_s (boundary+start): %.4f",
                     maxAbsError + startLatency))
        print(String(format: "ac_tolerance_s: 0.050"))
        print(String(format: "passes_50ms: %@",
                     (maxAbsError + startLatency) <= 0.050 ? "YES" : "NO"))
        print("=== END SPIKE RESULT ===")

        // Soft assert — spike documents reality; ADR decides tolerance.
        XCTAssertLessThanOrEqual(maxAbsError, 0.050,
                                 "Boundary-only error exceeds ±50 ms AC")
        XCTAssertLessThanOrEqual(maxAbsError + startLatency, 0.050,
                                 "Boundary+AVAudioPlayer start exceeds ±50 ms AC")
    }

    /// Minimal 1 kHz sine WAV (0.2 s, peak 0.35) for AVAudioPlayer latency probe.
    private func makeTempBeepWAV() throws -> URL {
        let sampleRate = 44_100.0
        let duration = 0.2
        let n = Int(sampleRate * duration)
        var samples = [Int16](repeating: 0, count: n)
        let peak: Double = 0.35
        let freq = 1000.0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            var env = 1.0
            if t < 0.005 { env = t / 0.005 }
            else if t > duration - 0.005 { env = (duration - t) / 0.005 }
            let s = sin(2 * Double.pi * freq * t) * peak * env
            samples[i] = Int16((s * Double(Int16.max)).rounded())
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("spike-beep-\(UUID().uuidString).wav")
        let data = try Self.pcm16MonoWAV(samples: samples, sampleRate: Int(sampleRate))
        try data.write(to: url)
        return url
    }

    private static func pcm16MonoWAV(samples: [Int16], sampleRate: Int) throws -> Data {
        let dataSize = samples.count * 2
        var data = Data()
        func appendASCII(_ s: String) { data.append(contentsOf: s.utf8) }
        func appendU32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func appendU16(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        appendASCII("RIFF")
        appendU32(UInt32(36 + dataSize))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendU32(16)
        appendU16(1) // PCM
        appendU16(1) // mono
        appendU32(UInt32(sampleRate))
        appendU32(UInt32(sampleRate * 2))
        appendU16(2)
        appendU16(16)
        appendASCII("data")
        appendU32(UInt32(dataSize))
        for s in samples {
            var le = s.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        return data
    }
}
