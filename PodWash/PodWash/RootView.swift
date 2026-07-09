//
//  RootView.swift
//  PodWash
//
//  Slice 03 — Routes fixture-mode UI tests to the player shell.
//

import SwiftUI

struct RootView: View {
    @State private var fixtureEngine: PlaybackEngine?

    var body: some View {
        Group {
            if FixtureAudio.isEnabled {
                if let fixtureEngine {
                    PlaybackControlsView(engine: fixtureEngine)
                } else {
                    ProgressView()
                        .accessibilityIdentifier("playback.loading")
                }
            } else {
                ContentView()
            }
        }
        .task {
            guard FixtureAudio.isEnabled, fixtureEngine == nil else { return }
            guard let url = FixtureAudio.bundledURL() else { return }
            fixtureEngine = PlaybackEngine(
                url: url,
                title: FixtureAudio.fixtureTitle,
                artist: FixtureAudio.fixtureArtist
            )
        }
    }
}
