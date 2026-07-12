//
//  DiscoverView.swift
//  PodWash
//
//  Slice 22 — Discover screen (slice-22-ux.md, ADR-014 §7).
//

import SwiftUI

struct DiscoverView: View {
    @Bindable var viewModel: DiscoverViewModel
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search podcasts", text: searchBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isSearchFocused)
                .padding(12)
                .accessibilityIdentifier("discoverSearchField")
                .accessibilityLabel("Search podcasts")
                .accessibilityHint("Search the podcast directory.")

            resultsRegion
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("discoverRoot")
        .accessibilityLabel("Discover")
        .navigationTitle("Discover")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    isSearchFocused = false
                }
            }
        }
        .task {
            if viewModel.loadPhase == .idle {
                await viewModel.loadPopular()
            }
        }
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { viewModel.searchTerm },
            set: { viewModel.scheduleSearch(term: $0) }
        )
    }

    @ViewBuilder
    private var resultsRegion: some View {
        if showsSearchResults {
            searchContent
        } else {
            popularContent
        }
    }

    private var isSearchActive: Bool {
        !viewModel.searchTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Search mode when results exist, search is in flight/failed, or a completed empty search.
    private var showsSearchResults: Bool {
        !viewModel.searchResults.isEmpty
            || viewModel.searchPhase == .loading
            || viewModel.searchPhase == .failed
            || (viewModel.searchPhase == .loaded && isSearchActive)
    }

    @ViewBuilder
    private var popularContent: some View {
        switch viewModel.loadPhase {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("discoverPopular.loading")
                .accessibilityLabel("Loading popular podcasts")
        case .failed:
            VStack(spacing: 12) {
                Text("Couldn’t load podcasts")
                    .accessibilityIdentifier("discoverPopular.error")
                    .accessibilityLabel("Popular load error")
                Button("Retry") {
                    Task { await viewModel.loadPopular() }
                }
                .accessibilityIdentifier("discoverPopular.retry")
                .accessibilityLabel("Retry")
                .accessibilityHint("Loads the popular podcast list again.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded where viewModel.popularResults.isEmpty:
            Text("No podcasts found")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("discoverPopular.empty")
                .accessibilityLabel("No podcasts")
        case .loaded:
            resultList(
                results: viewModel.popularResults,
                cellPrefix: "popularCell"
            )
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        if viewModel.searchPhase == .loading {
            ProgressView()
                .padding()
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("discoverSearch.loading")
                .accessibilityLabel("Searching")
        }

        switch viewModel.searchPhase {
        case .failed:
            VStack(spacing: 12) {
                Text("Search failed")
                    .accessibilityIdentifier("discoverSearch.error")
                    .accessibilityLabel("Search error")
                Button("Retry") {
                    Task { await viewModel.search(term: viewModel.searchTerm) }
                }
                .accessibilityIdentifier("discoverSearch.retry")
                .accessibilityLabel("Retry")
                .accessibilityHint("Runs the search again.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded where viewModel.searchResults.isEmpty && isSearchActive:
            Text("No results")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("discoverSearch.empty")
                .accessibilityLabel("No search results")
        case .loaded where !viewModel.searchResults.isEmpty:
            resultList(
                results: viewModel.searchResults,
                cellPrefix: "searchResultCell"
            )
        default:
            if viewModel.searchResults.isEmpty && !isSearchActive {
                popularContent
            } else {
                EmptyView()
            }
        }
    }

    private func resultList(
        results: [PodcastSearchResult],
        cellPrefix: String
    ) -> some View {
        List {
            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                DiscoverResultRow(
                    result: result,
                    index: index,
                    cellPrefix: cellPrefix,
                    isSubscribed: viewModel.isSubscribed(feedURL: result.feedURL),
                    isLoading: viewModel.subscribeState == .loading(index: index),
                    onSubscribe: {
                        Task { await viewModel.subscribe(atIndex: index) }
                    }
                )
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
    }
}

private struct DiscoverResultRow: View {
    let result: PodcastSearchResult
    let index: Int
    let cellPrefix: String
    let isSubscribed: Bool
    let isLoading: Bool
    let onSubscribe: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            artwork
            Text(result.title)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            trailingControl
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(cellPrefix)_\(index)")
        .accessibilityLabel(result.title)
    }

    @ViewBuilder
    private var artwork: some View {
        if let artworkURL = result.artworkURL {
            AsyncImage(url: artworkURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    placeholderArtwork
                }
            }
            .frame(width: 48, height: 48)
            .clipped()
            .accessibilityHidden(true)
        } else {
            placeholderArtwork
        }
    }

    private var placeholderArtwork: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(.quaternary)
            .frame(width: 48, height: 48)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var trailingControl: some View {
        ZStack {
            if isLoading {
                ProgressView()
            }
            Button(action: onSubscribe) {
                Text(isSubscribed ? "Subscribed" : "Subscribe")
                    .opacity(isLoading ? 0 : 1)
            }
            .disabled(isLoading)
            .accessibilityIdentifier("subscribeButton_\(index)")
            .accessibilityLabel(isSubscribed ? "Subscribed" : "Subscribe")
            .accessibilityValue(isSubscribed ? "1" : "0")
            .accessibilityHint(isSubscribed ? "" : "Adds this podcast to your subscriptions.")
        }
    }
}
