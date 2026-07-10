//
//  SleepTimer.swift
//  PodWash
//
//  Slice 12 — Sleep timer with injectable MonotonicClock; pauses once on deadline.
//

import Foundation

/// Minimal pause surface so unit tests can inject a spy instead of `PlaybackEngine`.
@MainActor
protocol PlaybackPausing: AnyObject {
    func pause()
}

/// Arms a one-shot pause deadline against an injectable monotonic clock.
@MainActor
final class SleepTimer {
    static let presets: [TimeInterval] = [900, 1800, 3600]

    // nonisolated(unsafe): avoid MainActor TaskLocal hop when releasing in deinit
    // (XCTest host otherwise hits BUG_IN_CLIENT_OF_LIBMALLOC via swift_task_deinitOnExecutorImpl).
    nonisolated(unsafe) private let engine: any PlaybackPausing
    nonisolated(unsafe) private let clock: any MonotonicClock

    nonisolated(unsafe) private var deadline: TimeInterval?
    nonisolated(unsafe) private var hasFired = false

    /// Called after a successful deadline fire (exactly once per arm).
    nonisolated(unsafe) var onFire: (() -> Void)?

    /// `nil` when off / cancelled / already fired; otherwise the armed preset seconds.
    nonisolated(unsafe) private(set) var armedPresetSeconds: TimeInterval?

    init(engine: any PlaybackPausing, clock: any MonotonicClock) {
        self.engine = engine
        self.clock = clock
        let prior = clock.onAdvance
        clock.onAdvance = { [weak self] in
            prior?()
            MainActor.assumeIsolated {
                self?.evaluate()
            }
        }
    }

    // Avoid MainActor/TaskLocal deinit crash (same pattern as QueueCoordinator).
    nonisolated deinit {}

    func arm(seconds: TimeInterval) {
        hasFired = false
        armedPresetSeconds = seconds
        deadline = clock.now + seconds
        evaluate()
    }

    func extend(by seconds: TimeInterval) {
        guard deadline != nil, !hasFired else { return }
        // AC3: at T=30, extend(+120) fires at T=150 → deadline becomes now + by.
        deadline = clock.now + seconds
        evaluate()
    }

    func cancel() {
        deadline = nil
        armedPresetSeconds = nil
        hasFired = false
    }

    /// Cycles `off → 900 → 1800 → 3600 → off` and arms/cancels accordingly.
    func cyclePreset() {
        let next: TimeInterval?
        switch armedPresetSeconds {
        case nil:
            next = 900
        case 900:
            next = 1800
        case 1800:
            next = 3600
        default:
            next = nil
        }

        if let next {
            arm(seconds: next)
        } else {
            cancel()
        }
    }

    /// Accessibility value for the sleep-timer control: `"off"` or preset seconds.
    var accessibilityValue: String {
        guard let armedPresetSeconds else { return "off" }
        return String(Int(armedPresetSeconds))
    }

    private func evaluate() {
        guard let deadline, !hasFired else { return }
        guard clock.now >= deadline else { return }

        hasFired = true
        self.deadline = nil
        armedPresetSeconds = nil
        engine.pause()
        onFire?()
    }
}
