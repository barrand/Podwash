//
//  LibraryView.swift
//  PodWash
//
//  Slice 23 — Subscription list + empty state (ADR-015 §2, slice-23-ux.md).
//

import SwiftUI

struct LibraryView: View {
    @Bindable var viewModel: LibraryViewModel
    var onDiscover: () -> Void

    var body: some View {
        Group {
            if viewModel.subscriptionCount == 0 {
                emptyState
            } else {
                subscriptionList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("libraryRoot")
        .accessibilityLabel("Library")
        .onAppear { viewModel.reload() }
    }

    private var subscriptionList: some View {
        List {
            ForEach(Array(viewModel.subscriptions.enumerated()), id: \.element.id) { index, summary in
                NavigationLink(value: summary) {
                    HStack(spacing: 12) {
                        libraryArtwork(summary.artworkURL)
                        Text(summary.title)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .accessibilityIdentifier("libraryCell_\(index)")
                .accessibilityLabel(summary.title)
                .accessibilityHint("Opens episodes for this podcast.")
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("libraryList")
        .accessibilityLabel("Subscriptions")
        .accessibilityValue("\(viewModel.subscriptionCount)")
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Text("No subscriptions yet")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Discover podcasts to build your library.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            // Combined region so XCTest resolves libraryEmptyState + Discover label
            // without requiring children: .contain on a mostly-hidden stack.
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("libraryEmptyState")
            .accessibilityLabel("No subscriptions yet. Discover podcasts to build your library.")

            Button("Discover podcasts", action: onDiscover)
                .accessibilityIdentifier("libraryEmptyDiscoverButton")
                .accessibilityLabel("Discover podcasts")
                .accessibilityHint("Opens the Discover tab.")
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func libraryArtwork(_ artworkURL: URL?) -> some View {
        if artworkURL != nil {
            Image(systemName: "photo.artframe")
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "mic.circle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}
