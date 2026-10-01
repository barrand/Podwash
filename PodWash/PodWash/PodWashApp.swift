//
//  PodWashApp.swift
//  PodWash
//
//  Created by Bryce Barrand on 7/8/26.
//

import SwiftUI

/// App entry point — must remain `@main` so the PodWash.app bundle has a valid
/// executable product for the simulator test host (install/launch).
/// With `ENABLE_DEBUG_DYLIB`, the stub loads `PodWash.debug.dylib`; a partial
/// build that links but skips CodeSign leaves that dylib unsigned and aborts at
/// dyld (SBMainWorkspace / signal abrt before XCTest connects).
@main
struct PodWashApp: App {
    /// Production Core Data stack (ADR-007). Constructed once at launch so the
    /// installable binary always wires a real `PersistenceController` (queue +
    /// resume types live in the same model). Library UITest fixtures use an
    /// isolated in-memory store (ADR-015 §6).
    private let persistence: PersistenceController

    /// Lock-screen / Control Center transport (ADR-011). Activated once at launch.
    private let remoteCommands: RemoteCommandCoordinator
    /// One process-wide AVAudioSession owner. Engines are rebound as episodes change.
    private let audioSessionManager: AudioSessionManager

    init() {
        PodWashAnalytics.initialize()
        FirebaseCloudBootstrap.configure()
        // UI fixtures must reset preferences before any composition object can
        // read them. Doing this from RootView's asynchronous task was late
        // enough for a first manual download to inherit prior consent state.
        FixtureSettings.prepareFreshDefaults()
        if FixtureRuntime.isFixtureLaunch,
           !FixtureNowPlayingSession.shouldPreserveOnLaunch,
           !FixtureQueue.shouldPreserveOnLaunch {
            // Jobs/intent belong to the same fixture lifetime as the catalog.
            // A prior interrupted UI run must not secretly prepare a fresh
            // first-download fixture before it can exercise consent.
            UserDefaults.standard.removeObject(forKey: "podwash.episodePreparationPreferences.v1")
            UserDefaults.standard.removeObject(forKey: "podwash.analysisJobs.v1")
        }
        if FixtureDownload.isEnabled {
            FixtureDownload.clearDownloadsDirectoryIfNeeded()
        }
        // Fresh temp-SQLite per launch (ADR-015 §6). Fixed identifiers reuse durable
        // files across UITest launches and can leave seeded rows in the empty fixture.
        if FixtureRuntime.isFixtureLaunch {
            // ADR-027 §8 — seed + preserve relaunch share one temp-SQLite id.
            persistence = PersistenceController.inMemory(
                identifier: FixtureRuntime.persistenceIdentifier
            )
        } else if FixtureLibrary.isEmptyEnabled {
            persistence = PersistenceController.inMemory(
                identifier: "uitest-library-empty-\(UUID().uuidString)"
            )
        } else if FixtureLibrary.isEnabled
                    || FixtureTranscript.isAnyEnabled
                    || FixtureMuteMarkers.isAnyEnabled
                    || FixturePrerollAdBands.isAnyEnabled {
            persistence = PersistenceController.inMemory(
                identifier: "uitest-library-\(UUID().uuidString)"
            )
        } else {
            persistence = PersistenceController.production()
        }
        let commands = RemoteCommandCoordinator(commands: MPRemoteCommandCenterAdapter())
        commands.activate()
        remoteCommands = commands
        audioSessionManager = AudioSessionManager()
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                persistence: persistence,
                remoteCommands: remoteCommands,
                audioSessionManager: audioSessionManager
            )
                .preferredColorScheme(.dark)
        }
    }
}
