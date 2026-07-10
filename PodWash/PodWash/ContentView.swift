//
//  ContentView.swift
//  PodWash
//
//  Default non-fixture shell (SwiftData template removed in Slice 11 — ADR-007).
//  Slice 13 — Settings entry from app chrome.
//

import SwiftUI

struct ContentView: View {
    @State private var settingsStore = SettingsStore()

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("PodWash")
                    .font(.largeTitle)
                    .fontWeight(.semibold)
                Text("Add a podcast feed to get started.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .navigationTitle("PodWash")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView(store: settingsStore)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityIdentifier("settingsButton")
                    .accessibilityLabel("Settings")
                    .accessibilityHint("Opens cleaning and playback defaults.")
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
