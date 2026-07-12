//
//  AppShellView.swift
//  PodWash
//
//  Slice 23 — Production TabView + mini-player overlay (ADR-015 §2).
//

import SwiftUI
import UIKit

enum AppShellTab: Hashable {
    case library
    case discover
}

/// Pushed Settings destination (toolbar Button → navigationDestination).
private enum ShellSettingsRoute: Hashable, Identifiable {
    case settings
    var id: Self { self }
}

struct AppShellView: View {
    @Bindable var model: AppShellModel
    @State private var selectedTab: AppShellTab = .library
    @State private var libraryViewModel: LibraryViewModel
    @State private var discoverViewModel: DiscoverViewModel
    @State private var librarySettingsRoute: ShellSettingsRoute?
    @State private var discoverSettingsRoute: ShellSettingsRoute?

    init(model: AppShellModel) {
        self.model = model
        _libraryViewModel = State(initialValue: LibraryViewModel(store: model.podcastStore))

        let useStubbedNetwork = FixtureLibrary.usesInMemoryPersistence
        let searchClient = useStubbedNetwork
            ? FixtureDiscover.makeSearchClient()
            : ITunesSearchClient()
        let parser = useStubbedNetwork
            ? FixtureDiscover.makeParser()
            : RSSParser()
        _discoverViewModel = State(
            initialValue: DiscoverViewModel(
                searchClient: searchClient,
                parser: parser,
                store: model.podcastStore
            )
        )
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            libraryTab
                .tabItem {
                    Label("Library", systemImage: "books.vertical")
                }
                .tag(AppShellTab.library)
                .accessibilityIdentifier("tabLibrary")
                .accessibilityLabel("Library")
                .accessibilityHint("Shows your subscribed podcasts.")

            discoverTab
                .tabItem {
                    Label("Discover", systemImage: "magnifyingglass")
                }
                .tag(AppShellTab.discover)
                .accessibilityIdentifier("tabDiscover")
                .accessibilityLabel("Discover")
                .accessibilityHint("Search and subscribe to podcasts.")
        }
        .background(BrandTheme.surface)
        .background {
            Color.clear
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("themePrimarySurface")
                .accessibilityLabel("Brand surface")
                .accessibilityValue("1")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.isMiniPlayerVisible, let engine = model.engine {
                MiniPlayerBar(
                    engine: engine,
                    episodeTitle: model.nowPlayingEpisodeTitle,
                    podcastTitle: model.nowPlayingPodcastTitle,
                    onExpand: { model.expandFullPlayer() },
                    onTogglePlayPause: { model.toggleMiniPlayerPlayPause() }
                )
            }
        }
        // Content-tree Settings control (not ToolbarItem). iOS 26 nav-bar glass +
        // toolbar Image buttons often report exists&&!isHittable under XCTest; a
        // plain SwiftUI Button overlaid in the safe-area trailing slot stays hittable.
        // Use alignment overlay (not GeometryReader) so only the 44pt control steals hits.
        .overlay(alignment: .topTrailing) {
            if showsShellSettingsButton {
                Button {
                    openSettingsForSelectedTab()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.body.weight(.medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("settingsButton")
                .accessibilityLabel("Settings")
                .accessibilityHint("Opens cleaning and playback defaults.")
                .padding(.trailing, 8)
                .safeAreaPadding(.top)
            }
        }
        .sheet(isPresented: $model.isFullPlayerPresented) {
            if let engine = model.engine {
                NavigationStack {
                    PlaybackControlsView(engine: engine)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") {
                                    model.isFullPlayerPresented = false
                                }
                            }
                        }
                }
            }
        }
        .background(TabBarAccessibilityConfigurator())
    }

    /// Hide when a pushed Settings screen or full player would cover the affordance.
    private var showsShellSettingsButton: Bool {
        !model.isFullPlayerPresented
            && librarySettingsRoute == nil
            && discoverSettingsRoute == nil
    }

    private func openSettingsForSelectedTab() {
        switch selectedTab {
        case .library:
            librarySettingsRoute = .settings
        case .discover:
            discoverSettingsRoute = .settings
        }
    }

    private var libraryTab: some View {
        NavigationStack {
            LibraryView(viewModel: libraryViewModel, onDiscover: { selectedTab = .discover })
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: PodcastSummary.self) { summary in
                    LibraryPodcastDetailView(model: model, summary: summary)
                }
                .navigationDestination(item: $librarySettingsRoute) { _ in
                    SettingsView(store: model.settingsStore)
                }
                // Reserve trailing nav-bar space so the overlay gear aligns with chrome.
                // Brand wordmark replaces literal "Library" nav title (slice-21-ux.md).
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text(BrandTheme.approvedDisplayName)
                            .font(.headline)
                            .foregroundStyle(BrandTheme.onSurface)
                            .accessibilityIdentifier("brandWordmark")
                            .accessibilityLabel(BrandTheme.approvedDisplayName)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Color.clear
                            .frame(width: 44, height: 44)
                            .accessibilityHidden(true)
                    }
                }
        }
    }

    private var discoverTab: some View {
        NavigationStack {
            DiscoverView(viewModel: discoverViewModel)
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(item: $discoverSettingsRoute) { _ in
                    SettingsView(store: model.settingsStore)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Color.clear
                            .frame(width: 44, height: 44)
                            .accessibilityHidden(true)
                    }
                }
        }
    }
}

/// Hosts existing PodcastDetailView for a library subscription (store-backed, no network).
private struct LibraryPodcastDetailView: View {
    @Bindable var model: AppShellModel
    let summary: PodcastSummary

    @State private var feedViewModel: EpisodeListViewModel
    @State private var analysisViewModel: AnalysisUIViewModel

    init(model: AppShellModel, summary: PodcastSummary) {
        self.model = model
        self.summary = summary
        let feedVM = EpisodeListViewModel(parser: RSSParser(), store: model.podcastStore)
        feedVM.loadFromStore(feedURL: summary.feedURL)
        _feedViewModel = State(initialValue: feedVM)
        _analysisViewModel = State(
            initialValue: AnalysisUIViewModel(
                store: CleaningToggleStoreAdapter(model.cleaningStore),
                analyzer: model.episodeAnalyzer,
                autoAnalyzeOnEpisodeEnable: false
            )
        )
    }

    var body: some View {
        PodcastDetailView(
            viewModel: feedViewModel,
            analysisViewModel: analysisViewModel,
            downloadManager: model.downloadManager,
            queueStore: model.queueStore,
            onPlayEpisode: { episode in
                model.playEpisode(
                    episode,
                    podcastTitle: summary.title,
                    feedURL: summary.feedURL
                )
            }
        )
        .navigationTitle(summary.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Applies tab-bar accessibility identifiers that SwiftUI `tabItem` does not always expose.
private struct TabBarAccessibilityConfigurator: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            Self.applyIdentifiers(from: view)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            Self.applyIdentifiers(from: uiView)
        }
    }

    private static func applyIdentifiers(from view: UIView) {
        guard let tabBar = findTabBar(from: view) else { return }
        guard let items = tabBar.items, items.count >= 2 else { return }
        items[0].accessibilityIdentifier = "tabLibrary"
        items[0].accessibilityLabel = "Library"
        items[0].accessibilityHint = "Shows your subscribed podcasts."
        items[1].accessibilityIdentifier = "tabDiscover"
        items[1].accessibilityLabel = "Discover"
        items[1].accessibilityHint = "Search and subscribe to podcasts."
    }

    private static func findTabBar(from view: UIView) -> UITabBar? {
        var current: UIView? = view
        while let c = current {
            if let tabBar = c as? UITabBar { return tabBar }
            for sub in c.subviews {
                if let tabBar = sub as? UITabBar { return tabBar }
                if let nested = findTabBar(in: sub) { return nested }
            }
            current = c.superview
        }
        // Walk up to window and search.
        if let window = view.window {
            return findTabBar(in: window)
        }
        return nil
    }

    private static func findTabBar(in root: UIView) -> UITabBar? {
        if let tabBar = root as? UITabBar { return tabBar }
        for sub in root.subviews {
            if let found = findTabBar(in: sub) { return found }
        }
        return nil
    }
}
