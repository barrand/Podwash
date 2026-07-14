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
    // Avoid MainActor/TaskLocal deinit crash (same pattern as QueueCoordinator).
    // Under SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor, unmarked classes still need this.
    nonisolated deinit {}

    func activatePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            Task { @MainActor in
                PlaybackDiagnostics.logAudioSessionActivated(
                    category: AVAudioSession.Category.playback.rawValue,
                    mode: AVAudioSession.Mode.spokenAudio.rawValue,
                    error: nil
                )
            }
        } catch {
            Task { @MainActor in
                PlaybackDiagnostics.logAudioSessionActivated(
                    category: AVAudioSession.Category.playback.rawValue,
                    mode: AVAudioSession.Mode.spokenAudio.rawValue,
                    error: error
                )
            }
        }
    }
}
