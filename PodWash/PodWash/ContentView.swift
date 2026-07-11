//
//  ContentView.swift
//  PodWash
//
//  Placeholder retired in Slice 23 — production shell is AppShellView (ADR-015).
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        Text("Use AppShellView")
            .accessibilityHidden(true)
    }
}

#Preview {
    Text("AppShellView preview requires PersistenceController")
}
