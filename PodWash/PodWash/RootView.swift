//
//  RootView.swift
//  PodWash
//
//  Slice 03/06/09/13/19/22/23 — Routes fixture-mode UI tests and production AppShellView.
//

import SwiftUI
import UIKit

struct RootView: View {
    let persistence: PersistenceController
    let remoteCommands: RemoteCommandCoordinator

    @State private var fixtureEngine: PlaybackEngine?
    @State private var fixtureFeedViewModel: EpisodeListViewModel?
    @State private var fixtureAnalysisViewModel: AnalysisUIViewModel?
    @State private var fixtureDownloadManager: DownloadManager?
    @State private var queueStore: QueueStore?
    @State private var fixtureSettingsStore: SettingsStore?
    @State private var discoverViewModel: DiscoverViewModel?
    @State private var appShellModel: AppShellModel?

    init(
        persistence: PersistenceController,
        remoteCommands: RemoteCommandCoordinator
    ) {
        self.persistence = persistence
        self.remoteCommands = remoteCommands
    }

    var body: some View {
        Group {
            if FixtureSkipOverride.isEnabled {
                if let fixtureEngine {
                    SkipOverridePlaybackView(engine: fixtureEngine)
                } else {
                    ProgressView()
                        .accessibilityIdentifier("playback.loading")
                }
            } else if FixtureSettings.isEnabled {
                if let fixtureSettingsStore {
                    NavigationStack {
                        SettingsView(store: fixtureSettingsStore)
                    }
                } else {
                    ProgressView()
                        .accessibilityIdentifier("settings.loading")
                }
            } else if FixtureAudio.isEnabled {
                if let fixtureEngine {
                    PlaybackControlsView(engine: fixtureEngine)
                } else {
                    ProgressView()
                        .accessibilityIdentifier("playback.loading")
                }
            } else if FixtureFeed.isEnabled || FixtureAnalysis.isEnabled || FixtureAnalysisTimeline.isEnabled || FixtureQueue.isEnabled || FixtureQueue.shouldPreserveOnLaunch {
                if let fixtureFeedViewModel, let fixtureAnalysisViewModel, let fixtureDownloadManager, let queueStore {
                    PodcastDetailView(
                        viewModel: fixtureFeedViewModel,
                        analysisViewModel: fixtureAnalysisViewModel,
                        downloadManager: fixtureDownloadManager,
                        queueStore: queueStore
                    )
                } else {
                    ProgressView()
                        .accessibilityIdentifier("feed.loading")
                }
            } else if FixtureDiscover.isEnabled {
                if let discoverViewModel {
                    NavigationStack {
                        DiscoverView(viewModel: discoverViewModel)
                    }
                } else {
                    ProgressView()
                        .accessibilityIdentifier("discover.loading")
                        .accessibilityLabel("Loading discover")
                }
            } else if let appShellModel {
                AppShellView(model: appShellModel)
            } else {
                ProgressView()
                    .accessibilityIdentifier("shell.loading")
            }
        }
        // CarPlay Info.plist declares phone UIWindowScene + CPTemplateApplicationScene
        // (ADR-016). An empty system window can become key while SwiftUI's WindowGroup
        // stays visible-but-not-key; XCTest then synthesizes taps that miss UIKit
        // UISwitch controls (AnalysisProgressUITests recording: toggle stays off).
        .background(KeyWindowActivator())
        .task {
            await loadFixtureSkipOverrideIfNeeded()
            loadFixtureSettingsIfNeeded()
            await loadFixtureAudioIfNeeded()
            await loadFixtureFeedIfNeeded()
            loadFixtureDiscoverIfNeeded()
            loadAppShellIfNeeded()
        }
    }

    private func loadFixtureSkipOverrideIfNeeded() async {
        guard FixtureSkipOverride.isEnabled, fixtureEngine == nil else { return }
        guard let url = FixtureSkipOverride.bundledURL() else { return }
        let engine = PlaybackEngine(
            url: url,
            title: FixtureSkipOverride.fixtureTitle,
            artist: FixtureSkipOverride.fixtureArtist
        )
        await engine.applySchedule(
            IntervalSchedule(intervals: [FixtureSkipOverride.stubSkipInterval])
        )
        fixtureEngine = engine
        remoteCommands.bind(engine)
        // Auto-play is started from SkipOverridePlaybackView.onAppear after the
        // skip-override callback is wired (avoids a nil-handler race at t=2.0 s).
    }

    private func loadFixtureSettingsIfNeeded() {
        guard FixtureSettings.isEnabled, fixtureSettingsStore == nil else { return }
        FixtureSettings.prepareFreshDefaults()
        fixtureSettingsStore = SettingsStore()
    }

    private func loadFixtureAudioIfNeeded() async {
        guard FixtureAudio.isEnabled, fixtureEngine == nil else { return }
        guard let url = FixtureAudio.bundledURL() else { return }
        let engine = PlaybackEngine(
            url: url,
            title: FixtureAudio.fixtureTitle,
            artist: FixtureAudio.fixtureArtist
        )
        fixtureEngine = engine
        remoteCommands.bind(engine)
    }

    private func loadFixtureFeedIfNeeded() async {
        guard FixtureFeed.isEnabled || FixtureAnalysis.isEnabled || FixtureAnalysisTimeline.isEnabled || FixtureQueue.isEnabled || FixtureQueue.shouldPreserveOnLaunch else { return }
        guard fixtureFeedViewModel == nil else { return }

        FixtureDownload.clearDownloadsDirectoryIfNeeded()

        let context = persistence.viewContext
        let store = PodcastStore(context: context)
        // Wipe prior UITest subscriptions (e.g. Discover) so fixture episode IDs
        // do not collide with CDEpisode's global uniqueness constraint.
        try? store.clear()
        let feedViewModel = EpisodeListViewModel(parser: RSSParser(), store: store)
        let cleaningStore = CleaningToggleStore(context: context)
        let analyzer: any EpisodeAnalyzing = FixtureAnalysisTimeline.isEnabled
            ? FixtureAnalysisTimeline.makeSteppedAnalyzer()
            : InstantEpisodeAnalyzer()
        let analysisViewModel = AnalysisUIViewModel(
            store: CleaningToggleStoreAdapter(cleaningStore),
            analyzer: analyzer,
            autoAnalyzeOnEpisodeEnable: FixtureAnalysis.isEnabled || FixtureAnalysisTimeline.isEnabled
        )
        let downloadStateStore = DownloadStateStore(context: context)
        let downloadManager = DownloadManager(
            downloadsDirectory: DownloadPaths.productionDownloadsDirectory,
            stateStore: InMemoryDownloadStateStore(backing: downloadStateStore)
        )
        let queue = QueueStore(context: context)
        if FixtureQueue.shouldResetOnLaunch {
            try? queue.clear()
        }

        fixtureFeedViewModel = feedViewModel
        fixtureAnalysisViewModel = analysisViewModel
        fixtureDownloadManager = downloadManager
        queueStore = queue

        guard let data = FixtureFeed.bundledData() else { return }
        await feedViewModel.load(data: data)
    }

    private func loadFixtureDiscoverIfNeeded() {
        guard FixtureDiscover.isEnabled, discoverViewModel == nil else { return }
        let store = PodcastStore(context: persistence.viewContext)
        try? store.clear()
        discoverViewModel = DiscoverViewModel(
            searchClient: FixtureDiscover.makeSearchClient(),
            parser: FixtureDiscover.makeParser(),
            store: store
        )
    }

    private func loadAppShellIfNeeded() {
        guard !FixtureSkipOverride.isEnabled,
              !FixtureSettings.isEnabled,
              !FixtureAudio.isEnabled,
              !(FixtureFeed.isEnabled || FixtureAnalysis.isEnabled || FixtureAnalysisTimeline.isEnabled || FixtureQueue.isEnabled || FixtureQueue.shouldPreserveOnLaunch),
              !FixtureDiscover.isEnabled
        else { return }
        guard appShellModel == nil else { return }

        let model = AppShellModel(persistence: persistence, remoteCommands: remoteCommands)
        // Seed/clear via the shell's store so LibraryViewModel reads the same context rows.
        if FixtureLibrary.isEnabled {
            try? FixtureLibrary.prepareSeededStore(model.podcastStore)
        } else if FixtureLibrary.isEmptyEnabled {
            try? FixtureLibrary.prepareEmptyStore(model.podcastStore)
        }
        appShellModel = model
    }
}

/// Promotes the SwiftUI content window to key when CarPlay multi-scene manifests
/// leave an empty `UIWindowScene` as key (XCTest hit delivery otherwise misses
/// UIKit controls that are only visible in the non-key WindowGroup).
private struct KeyWindowActivator: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        DispatchQueue.main.async {
            Self.activateKeyWindow(from: view)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            Self.activateKeyWindow(from: uiView)
        }
    }

    private static func activateKeyWindow(from view: UIView) {
        if let window = view.window {
            if !window.isKeyWindow {
                window.makeKeyAndVisible()
            }
            return
        }
        // Fallback before the representable is attached: pick the phone scene window
        // that already hosts a root view controller (skip empty system scenes).
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes where scene.session.role == .windowApplication {
            if let window = scene.windows.first(where: { $0.rootViewController != nil }) {
                window.makeKeyAndVisible()
                return
            }
        }
    }
}
