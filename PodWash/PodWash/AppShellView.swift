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
    @State private var libraryNavigationPath = NavigationPath()
    /// Measured `UITabBar` height so the mini-player inset clears tab-bar hit targets (task-010).
    @State private var tabBarHeight: CGFloat = 54

    init(model: AppShellModel) {
        self.model = model
        _libraryViewModel = State(initialValue: LibraryViewModel(store: model.podcastStore))

        let useStubbedNetwork = FixtureLibrary.usesInMemoryPersistence
            || FixtureTranscript.usesInMemoryPersistence
            || FixtureProgressivePlayback.isEnabled
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

            discoverTab
                .tabItem {
                    Label("Discover", systemImage: "magnifyingglass")
                }
                .tag(AppShellTab.discover)
        }
        .background(BrandTheme.surface)
        .background {
            Color.clear
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("themePrimarySurface")
                .accessibilityLabel("Brand surface")
                .accessibilityValue("1")
        }
        .onChange(of: selectedTab) { oldTab, newTab in
            if newTab == .library, oldTab != .library {
                libraryNavigationPath = NavigationPath()
                librarySettingsRoute = nil
            }
            if oldTab == .discover, newTab != .discover {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil,
                    from: nil,
                    for: nil
                )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.isMiniPlayerVisible, let engine = model.engine {
                VStack(spacing: 0) {
                    MiniPlayerBar(
                        engine: engine,
                        episodeTitle: model.nowPlayingEpisodeTitle,
                        podcastTitle: model.nowPlayingPodcastTitle,
                        timelineColors: model.miniPlayerTimelineColors,
                        isPreparingPlayback: model.isPreparingPlayback,
                        onExpand: { model.expandFullPlayer() },
                        onTogglePlayPause: { model.toggleMiniPlayerPlayPause() }
                    )
                    // iOS 26 TabView bottom inset overlaps the tab bar unless we reserve its height.
                    Color.clear
                        .frame(height: tabBarHeight)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
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
                    PlaybackControlsView(
                        engine: engine,
                        timelineColors: model.fullPlayerTimelineColors,
                        isPreparingPlayback: model.isPreparingPlayback,
                        episodeDuration: model.superSeekDuration,
                        processedEnd: model.superSeekProcessedEnd,
                        onTogglePlayPause: { model.toggleMiniPlayerPlayPause() },
                        onSeekTo: { model.seekClampedToProcessedFrontier(to: $0) },
                        onSeekBy: { model.seekClampedToProcessedFrontier(by: $0) }
                    )
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") {
                                    model.isFullPlayerPresented = false
                                }
                            }
                        }
                }
                // Content-tree leading control (not ToolbarItem). ToolbarItem wraps
                // the button so `descendants(.any)["playback.viewTranscript"]` matches
                // Other + Button and `.tap()` fails — same pattern as settingsButton.
                .overlay(alignment: .topLeading) {
                    if model.nowPlayingTranscriptExists {
                        Button {
                            model.presentTranscriptForNowPlaying()
                        } label: {
                            Image(systemName: "text.alignleft")
                                .font(.body.weight(.medium))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("playback.viewTranscript")
                        .accessibilityLabel("View transcript")
                        .accessibilityHint("Shows the episode transcript.")
                        .padding(.leading, 8)
                        .safeAreaPadding(.top)
                    }
                }
                .sheet(item: nestedTranscriptSheetItem) { _ in
                    transcriptSheetContent
                }
            }
        }
        .sheet(item: rootTranscriptSheetItem) { _ in
            transcriptSheetContent
        }
        .background(TabBarAccessibilityConfigurator(tabBarHeight: $tabBarHeight))
    }

    @ViewBuilder
    private var transcriptSheetContent: some View {
        if let viewModel = model.transcriptSheetViewModel {
            TranscriptView(viewModel: viewModel) {
                model.dismissTranscript()
            }
        }
    }

    /// Transcript sheet when full player is closed (episode-row entry).
    private var rootTranscriptSheetItem: Binding<TranscriptSheetToken?> {
        Binding(
            get: {
                guard !model.isFullPlayerPresented else { return nil }
                return model.transcriptSheetEpisodeID.map { TranscriptSheetToken(id: $0) }
            },
            set: { newValue in
                if newValue == nil {
                    model.dismissTranscript()
                }
            }
        )
    }

    /// Nested transcript sheet on top of the full-player sheet.
    private var nestedTranscriptSheetItem: Binding<TranscriptSheetToken?> {
        Binding(
            get: {
                guard model.isFullPlayerPresented else { return nil }
                return model.transcriptSheetEpisodeID.map { TranscriptSheetToken(id: $0) }
            },
            set: { newValue in
                if newValue == nil {
                    model.dismissTranscript()
                }
            }
        )
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
        NavigationStack(path: $libraryNavigationPath) {
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
                store: FeedScopedCleaningToggleStore(
                    store: model.cleaningStore,
                    feedURL: summary.feedURL
                ),
                analyzer: model.episodeAnalyzer,
                autoAnalyzeOnEpisodeEnable: false,
                progressRelay: model.analysisProgressRelay
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
            },
            transcriptExists: { model.transcriptExists(for: $0) },
            onViewTranscript: { model.presentTranscript(for: $0) }
        )
        .navigationTitle(summary.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Identifiable token for transcript sheet presentation.
private struct TranscriptSheetToken: Identifiable {
    let id: String
}

/// Applies tab-bar accessibility identifiers that SwiftUI `tabItem` does not always expose.
private struct TabBarAccessibilityConfigurator: UIViewRepresentable {
    @Binding var tabBarHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(tabBarHeight: $tabBarHeight)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            Self.apply(from: view, coordinator: context.coordinator)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            Self.apply(from: uiView, coordinator: context.coordinator)
        }
    }

    final class Coordinator {
        var tabBarHeight: Binding<CGFloat>

        init(tabBarHeight: Binding<CGFloat>) {
            self.tabBarHeight = tabBarHeight
        }
    }

    private static func apply(from view: UIView, coordinator: Coordinator) {
        guard let tabBar = findTabBar(from: view) else { return }
        let measuredHeight = tabBar.bounds.height
        if measuredHeight > 0, coordinator.tabBarHeight.wrappedValue != measuredHeight {
            coordinator.tabBarHeight.wrappedValue = measuredHeight
        }
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
