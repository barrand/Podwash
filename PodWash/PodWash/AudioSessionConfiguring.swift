//
//  AudioSessionConfiguring.swift
//  PodWash
//
//  Shared audio-session configuration and lifecycle observation.
//

import AVFoundation
import Foundation

/// The small surface PlaybackEngine needs to cooperate with the system audio session.
/// Kept separate from event binding so focused engine tests can inject a simple spy.
protocol AudioSessionConfiguring: AnyObject {
    /// Configures and activates playback. `false` means playback must remain paused.
    func activatePlaybackSession() -> Bool
    /// Releases the session after a listener-initiated, terminal pause.
    func deactivatePlaybackSession()
}

enum AudioSessionEvent: Equatable {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case outputDisconnected
    case noSuitableOutput
    case mediaServicesLost
    case mediaServicesReset
}

@MainActor
protocol AudioSessionEventHandling: AnyObject {
    func handleAudioSessionEvent(_ event: AudioSessionEvent)
}

@MainActor
protocol AudioSessionManaging: AudioSessionConfiguring {
    /// Replaces the active playback target. The manager deliberately retains it weakly.
    func bind(_ handler: (any AudioSessionEventHandling)?)
    /// Clears the binding only when it still refers to this object.
    func unbind(_ handler: any AudioSessionEventHandling)
}

/// Tiny AVAudioSession adapter so manager tests never have to mutate the shared session.
@MainActor
protocol SystemAudioSessionControlling: AnyObject {
    func configurePlayback() throws
    func activate() throws
    func deactivateNotifyingOthers() throws
}

@MainActor
final class AVAudioSessionSystemController: SystemAudioSessionControlling {
    /// One-shot silence-host session bounce per process (avoids repeated deactivate on every play).
    private static var didBounceSessionForSilence = false

    func configurePlayback() throws {
        let session = AVAudioSession.sharedInstance()
        let silence = HostAudioSilence.isEnabled
        // XCTest/UI tests need a mixing session so their muted AVPlayer fixtures do not
        // poison the shared process session. Production stays a normal spoken-audio player.
        let options: AVAudioSession.CategoryOptions = silence ? [.mixWithOthers] : []
        let mode: AVAudioSession.Mode = silence ? .default : .spokenAudio
        if silence, !Self.didBounceSessionForSilence {
            Self.didBounceSessionForSilence = true
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        try session.setCategory(.playback, mode: mode, options: options)
    }

    func activate() throws {
        try AVAudioSession.sharedInstance().setActive(true)
    }

    func deactivateNotifyingOthers() throws {
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// The sole production observer of AVAudioSession lifecycle notifications. It is created at
/// app launch, then rebound to whichever PlaybackEngine owns the active episode.
@MainActor
final class AudioSessionManager: AudioSessionManaging {
    private let system: any SystemAudioSessionControlling
    private let notificationCenter: NotificationCenter
    private weak var handler: (any AudioSessionEventHandling)?
    private var observerTokens: [NSObjectProtocol] = []

    convenience init(notificationCenter: NotificationCenter = .default) {
        self.init(system: AVAudioSessionSystemController(), notificationCenter: notificationCenter)
    }

    init(
        system: any SystemAudioSessionControlling,
        notificationCenter: NotificationCenter = .default
    ) {
        self.system = system
        self.notificationCenter = notificationCenter
        installObservers()
    }

    nonisolated deinit {
        // NotificationCenter removal is thread-safe; avoiding an actor hop matches the
        // project-wide deinit discipline used by PlaybackEngine and QueueCoordinator.
        for token in observerTokens {
            notificationCenter.removeObserver(token)
        }
    }

    func bind(_ handler: (any AudioSessionEventHandling)?) {
        self.handler = handler
    }

    func unbind(_ handler: any AudioSessionEventHandling) {
        if self.handler === handler {
            self.handler = nil
        }
    }

    func activatePlaybackSession() -> Bool {
        do {
            try system.configurePlayback()
            try system.activate()
            PlaybackDiagnostics.logAudioSessionActivated(
                category: AVAudioSession.Category.playback.rawValue,
                mode: HostAudioSilence.isEnabled ? AVAudioSession.Mode.default.rawValue : AVAudioSession.Mode.spokenAudio.rawValue,
                error: nil
            )
            return true
        } catch {
            PlaybackDiagnostics.logAudioSessionActivated(
                category: AVAudioSession.Category.playback.rawValue,
                mode: HostAudioSilence.isEnabled ? AVAudioSession.Mode.default.rawValue : AVAudioSession.Mode.spokenAudio.rawValue,
                error: error
            )
            return false
        }
    }

    func deactivatePlaybackSession() {
        do {
            try system.deactivateNotifyingOthers()
            PlaybackDiagnostics.logAudioSessionDeactivated(error: nil)
        } catch {
            PlaybackDiagnostics.logAudioSessionDeactivated(error: error)
        }
    }

    private func installObservers() {
        let add: (Notification.Name, @escaping (Notification) -> Void) -> Void = { [weak self] name, callback in
            guard let self else { return }
            let token = self.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { notification in
                Task { @MainActor [weak self] in
                    guard self != nil else { return }
                    callback(notification)
                }
            }
            self.observerTokens.append(token)
        }

        add(AVAudioSession.interruptionNotification) { [weak self] notification in
            self?.handleInterruption(notification)
        }
        add(AVAudioSession.routeChangeNotification) { [weak self] notification in
            self?.handleRouteChange(notification)
        }
        add(AVAudioSession.mediaServicesWereLostNotification) { [weak self] _ in
            self?.emit(.mediaServicesLost)
        }
        add(AVAudioSession.mediaServicesWereResetNotification) { [weak self] _ in
            self?.emit(.mediaServicesReset)
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else {
            PlaybackDiagnostics.warning("audioSession interruption malformed")
            return
        }
        switch type {
        case .began:
            emit(.interruptionBegan)
        case .ended:
            let optionRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionRaw)
            emit(.interruptionEnded(shouldResume: options.contains(.shouldResume)))
        @unknown default:
            PlaybackDiagnostics.warning("audioSession interruption unknown")
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        else {
            PlaybackDiagnostics.warning("audioSession route malformed")
            return
        }
        switch reason {
        case .oldDeviceUnavailable:
            emit(.outputDisconnected)
        case .noSuitableRouteForCategory:
            emit(.noSuitableOutput)
        default:
            PlaybackDiagnostics.info("audioSession route reason=\(reason.rawValue) action=none")
        }
    }

    private func emit(_ event: AudioSessionEvent) {
        PlaybackDiagnostics.logAudioSessionEvent(event)
        handler?.handleAudioSessionEvent(event)
    }
}
