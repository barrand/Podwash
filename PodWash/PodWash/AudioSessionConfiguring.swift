//
//  AudioSessionConfiguring.swift
//  PodWash
//
//  Slice 14 — Injectable AVAudioSession activation (ADR-011 §5).
//

import AVFoundation
import Foundation

protocol AudioSessionConfiguring: AnyObject {
    func activatePlaybackSession()
}

/// Production adapter: `.playback` + `.spokenAudio`, then `setActive(true)`.
final class AVAudioSessionPlaybackConfigurator: AudioSessionConfiguring {
    /// One-shot silence-host session bounce per process (avoids repeated deactivate on every play).
    private static var didBounceSessionForSilence = false

    // Avoid MainActor/TaskLocal deinit crash (same pattern as QueueCoordinator).
    // Under SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor, unmarked classes still need this.
    nonisolated deinit {}

    func activatePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        let silence = HostAudioSilence.isEnabled
        // Under XCTest / UITest silence, mixWithOthers + a one-shot deactivate bounce
        // clears a poisoned shared session from a prior test (muted AVPlayer then
        // reports .playing while the playhead never moves).
        let options: AVAudioSession.CategoryOptions = silence ? [.mixWithOthers] : []
        let mode: AVAudioSession.Mode = silence ? .default : .spokenAudio
        do {
            if silence, !Self.didBounceSessionForSilence {
                Self.didBounceSessionForSilence = true
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }
            try session.setCategory(.playback, mode: mode, options: options)
            try session.setActive(true)
            Task { @MainActor in
                PlaybackDiagnostics.logAudioSessionActivated(
                    category: AVAudioSession.Category.playback.rawValue,
                    mode: mode.rawValue,
                    error: nil
                )
            }
        } catch {
            Task { @MainActor in
                PlaybackDiagnostics.logAudioSessionActivated(
                    category: AVAudioSession.Category.playback.rawValue,
                    mode: mode.rawValue,
                    error: error
                )
            }
        }
    }
}
