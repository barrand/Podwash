//
//  ContentView.swift
//  PodWash
//
//  Default non-fixture shell (SwiftData template removed in Slice 11 — ADR-007).
//

import SwiftUI

struct ContentView: View {
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
        }
    }
}

#Preview {
    ContentView()
}
