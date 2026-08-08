//
//  AppShellView.swift
//  PodWash
//
//  Slice 23 — Production TabView + mini-player overlay (ADR-015 §2).
//

import AVFoundation
import SwiftUI
import UIKit

enum AppShellTab: Hashable {
    case library
    case queue
    case discover
}

/// Pushed Settings destination (toolbar Button → navigationDestination).
private enum ShellSettingsRoute: Hashable, Identifiable {
    case settings
    var id: Self { self }
}

struct AppShellView: View {
    @Bindable var model: AppShellModel
    @Environment(\.scenePhase) private var scenePhase
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
            || FixtureMuteMarkers.isAnyEnabled
            || FixturePrerollAdBands.isAnyEnabled
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

            queueTab
                .tabItem {
                    Label("Queue", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                .tag(AppShellTab.queue)

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
            if showsMiniPlayerInShellInset, let engine = model.engine {
                shellMiniPlayerBar(engine: engine, reservesTabBarClearance: true)
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
                        showsCompleteSeekBarPaint: model.isPlayerSeekBarAnalysisComplete,
                        analysisProgress: model.analysisProgressFraction,
                        isPreparingPlayback: model.isPreparingPlayback,
                        episodeDuration: model.superSeekDuration,
                        processedEnd: model.superSeekProcessedEnd,
                        muteIntervals: model.nowPlayingMuteIntervals,
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
        .task {
            model.restoreNowPlayingSessionIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .inactive || newPhase == .background {
                model.flushPlaybackPosition()
            }
        }
    }

    /// Root transcript sheet covers the tab `safeAreaInset`; host the same bar inside the sheet (task-029).
    private var showsMiniPlayerInTranscriptInset: Bool {
        model.isMiniPlayerVisible
            && model.transcriptSheetEpisodeID != nil
            && !model.isFullPlayerPresented
    }

    private var showsMiniPlayerInShellInset: Bool {
        model.isMiniPlayerVisible && !showsMiniPlayerInTranscriptInset
    }

    @ViewBuilder
    private func shellMiniPlayerBar(engine: PlaybackEngine, reservesTabBarClearance: Bool) -> some View {
        VStack(spacing: 0) {
            MiniPlayerBar(
                engine: engine,
                episodeTitle: model.nowPlayingEpisodeTitle,
                podcastTitle: model.nowPlayingPodcastTitle,
                showsCompleteSeekBarPaint: model.isPlayerSeekBarAnalysisComplete,
                analysisProgress: model.analysisProgressFraction,
                isPreparingPlayback: model.isPreparingPlayback,
                isPreparingNextEpisode: model.isPreparingNextEpisode,
                preparingNextAnnouncement: model.preparingNextAnnouncement,
                queuePresentation: model.queuePresentation,
                episodeDuration: model.superSeekDuration,
                processedEnd: model.superSeekProcessedEnd,
                muteIntervals: model.nowPlayingMuteIntervals,
                showsSuperSeekBar: !reservesTabBarClearance,
                onExpand: { model.expandFullPlayer() },
                onTogglePlayPause: { model.toggleMiniPlayerPlayPause() },
                onSeekTo: { model.seekClampedToProcessedFrontier(to: $0) },
                onSkipToNextShow: { model.skipToNextShow() },
                onOpenPreparation: { selectedTab = .queue }
            )
            .onChange(of: model.preparingAnnouncementGeneration) { _, _ in
                if let text = model.preparingNextAnnouncement {
                    PreparingSpeech.announce(text)
                }
            }
            if reservesTabBarClearance {
                // iOS 26 TabView bottom inset overlaps the tab bar unless we reserve its height.
                // The Super Seek Bar belongs in that reservation, immediately above the tabs.
                shellMiniPlayerSeekBar(engine: engine)
                .frame(height: tabBarHeight, alignment: .top)
                // This reservation shares the tab bar's space; leave its unused
                // portion clear so UIKit can render the tab controls.
                .background(Color.clear)
            }
        }
    }

    private var queueTab: some View {
        QueueTabView(
            presentation: model.queuePresentation,
            // TabView's UIKit-backed List does not consistently inherit the shell's
            // bottom inset. Reserve the mini-player card inside Queue itself so the
            // last queued row can always scroll fully above it.
            bottomContentClearance: showsMiniPlayerInShellInset
                ? MiniPlayerBar.shellOverlayClearance
                : 0,
            onMove: { offsets, destination in
                guard let source = offsets.first,
                      source < model.queuePresentation.upNext.count
                else { return }
                let target = destination > source ? destination - 1 : destination
                model.moveUpNext(
                    episodeID: model.queuePresentation.upNext[source].episodeID,
                    to: target
                )
            },
            onPlayNow: { model.playReadyEpisodeNow($0) },
            onMoveToTop: { model.moveUpNextToTop(episodeID: $0) },
            onRemoveFromUpNext: { model.removeFromUpNextWithUndo(episodeID: $0) },
            onMarkPlayed: { model.markPlayedWithUndo(episodeID: $0) },
            onRestore: { model.restoreQueueMutation($0) },
            onCommitPlayed: { model.commitQueueMutation($0) },
            onRemoveDownload: { model.removeDownloadAndPreparation(episodeID: $0) },
            onAddToUpNext: { model.addAndPrepare(episodeID: $0) },
            onClearUpNext: { model.clearUpNext() },
            onRestoreUpNext: { model.restoreUpNext($0) },
            onRetry: { model.retryPreparation(episodeID: $0) },
            onPlayWithAds: { model.playWithAds(episodeID: $0) }
        )
    }

    private func shellMiniPlayerSeekBar(engine: PlaybackEngine) -> some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let _ = engine.uiRefreshToken
            MiniPlayerSeekBar(
                showsCompleteContentTrack: model.isPlayerSeekBarAnalysisComplete,
                adBands: miniPlayerAdBands(for: engine),
                elapsed: engine.avPlayer.currentTime().seconds,
                duration: miniPlayerDuration(for: engine),
                processedEnd: miniPlayerProcessedEnd(for: engine),
                muteMarkers: miniPlayerMuteMarkers(for: engine),
                muteMarkerCountForAccessibility: miniPlayerMuteMarkerCount(for: engine),
                analysisProgress: model.analysisProgressFraction,
                onSeekTo: { model.seekClampedToProcessedFrontier(to: $0) }
            )
        }
        // Only the seek-bar strip itself overlays tab content. Do not paint the
        // whole tab-bar reservation or Library / Queue / Discover disappear.
        .background(BrandTheme.surface)
    }

    private func miniPlayerDuration(for engine: PlaybackEngine) -> Double {
        model.superSeekDuration > 0 ? model.superSeekDuration : engine.duration
    }

    private func miniPlayerProcessedEnd(for engine: PlaybackEngine) -> Double {
        let duration = miniPlayerDuration(for: engine)
        return model.superSeekProcessedEnd > 0 ? model.superSeekProcessedEnd : duration
    }

    private func miniPlayerAdBands(for engine: PlaybackEngine) -> [AdBand] {
        guard model.isPlayerSeekBarAnalysisComplete else { return [] }
        return SuperSeekBarModel.adBands(
            from: model.nowPlayingMuteIntervals,
            duration: miniPlayerDuration(for: engine)
        )
    }

    private func miniPlayerMuteMarkers(for engine: PlaybackEngine) -> [MuteMarker] {
        guard model.isPlayerSeekBarAnalysisComplete else { return [] }
        return SuperSeekBarModel.muteMarkers(
            from: model.nowPlayingMuteIntervals,
            duration: miniPlayerDuration(for: engine)
        )
    }

    private func miniPlayerMuteMarkerCount(for engine: PlaybackEngine) -> Int? {
        model.isPlayerSeekBarAnalysisComplete ? miniPlayerMuteMarkers(for: engine).count : nil
    }

    @ViewBuilder
    private var transcriptSheetContent: some View {
        if let viewModel = model.transcriptSheetViewModel {
            TranscriptView(
                viewModel: viewModel,
                playbackEngine: model.transcriptSheetPlaybackEngine,
                openPlaybackPosition: model.transcriptSheetOpenPlaybackPosition
            ) {
                model.dismissTranscript()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showsMiniPlayerInTranscriptInset, let engine = model.engine {
                    shellMiniPlayerBar(engine: engine, reservesTabBarClearance: false)
                }
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
            && selectedTab != .queue
            && librarySettingsRoute == nil
            && discoverSettingsRoute == nil
    }

    private func openSettingsForSelectedTab() {
        switch selectedTab {
        case .library:
            librarySettingsRoute = .settings
        case .queue:
            break
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
        VStack(spacing: 0) {
            Toggle(isOn: Binding(
                get: { model.isBinge(feedURL: summary.feedURL) },
                set: { model.setBinge($0, feedURL: summary.feedURL) }
            )) {
                Text("Binge")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .accessibilityIdentifier("bingeToggle")
            .accessibilityLabel("Binge")
            .accessibilityHint("Play oldest unplayed episodes first and stay in this show.")
            .accessibilityValue(model.isBinge(feedURL: summary.feedURL) ? "1" : "0")

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
                onPlayQueuedEpisode: { model.playQueuedEpisodeNow($0) },
                onAddAndPrepare: { model.addAndPrepare(episodeID: $0) },
                transcriptExists: { model.transcriptExists(for: $0) },
                onViewTranscript: { model.presentTranscript(for: $0) },
                transcriptAffordanceGeneration: model.transcriptAffordanceGeneration,
                cleaningSummary: { model.cleaningSummary(for: $0) }
            )
        }
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

    private static func apply(from view: UIView, coordinator: Coordinator, attempt: Int = 0) {
        guard let tabBar = findTabBar(from: view) else {
            // The representable can be updated before SwiftUI has attached the TabView's
            // UIKit hierarchy, particularly during a cold restored mini-player session.
            // Retry briefly so the identifiers describe the actual controls, not a
            // transient view-tree state.
            guard attempt < 10 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                apply(from: view, coordinator: coordinator, attempt: attempt + 1)
            }
            return
        }
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

        // On recent iOS versions XCTest queries the private tab-bar button views
        // rather than UITabBarItem. Use the public accessibility surface of those
        // views too, keeping the visible Library and Discover controls addressable.
        let controls = tabBar.subviews
            .filter(\.isAccessibilityElement)
            .sorted { $0.frame.minX < $1.frame.minX }
        guard controls.count >= 2 else { return }
        controls[0].accessibilityIdentifier = "tabLibrary"
        controls[0].accessibilityLabel = "Library"
        controls[1].accessibilityIdentifier = "tabDiscover"
        controls[1].accessibilityLabel = "Discover"
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
