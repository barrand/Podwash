//
//  MonotonicClock.swift
//  PodWash
//
//  Slice 12 — Injectable monotonic clock for SleepTimer (avoids shadowing
//  `_Concurrency.Clock`). Test doubles live in the test target.
//

import Foundation

/// Monotonic time source for `SleepTimer`. Named to avoid clashing with Swift's
/// `_Concurrency.Clock`.
protocol MonotonicClock: AnyObject {
    var now: TimeInterval { get }
    /// Invoked after `now` moves forward so timers can re-evaluate deadlines.
    var onAdvance: (() -> Void)? { get set }
}

/// Wall-clock-backed clock that ticks while a sleep timer may be armed.
@MainActor
final class SystemMonotonicClock: MonotonicClock {
    nonisolated(unsafe) private(set) var now: TimeInterval
    nonisolated(unsafe) var onAdvance: (() -> Void)?

    /// `nonisolated(unsafe)`: only touched on the main actor; `deinit` must invalidate
    /// without hopping through `swift_task_deinitOnExecutorImpl` (test-host abort).
    private nonisolated(unsafe) var timer: Timer?

    init() {
        now = ProcessInfo.processInfo.systemUptime
    }

    /// Starts periodic ticks so `SleepTimer` can fire on the main run loop.
    func startTicking(interval: TimeInterval = 0.25) {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            // Hop onto the MainActor executor (Timer run-loop callbacks are not
            // MainActor-isolated); SleepTimer.evaluate assumes MainActor.
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        now = ProcessInfo.processInfo.systemUptime
        onAdvance?()
    }

    // Avoid MainActor/TaskLocal deinit crash (same pattern as QueueCoordinator).
    nonisolated deinit {
        timer?.invalidate()
    }
}
