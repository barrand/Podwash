//
//  EpisodeListView.swift
//  PodWash
//
//  Slice 06/09 — Episode list UI (slice-06-ux.md, slice-09-ux.md).
//

import SwiftUI
import UIKit

struct EpisodeListView: View {
    let feed: PodcastFeed
    @Bindable var analysisViewModel: AnalysisUIViewModel
    var downloadManager: DownloadManager
    var queueStore: QueueStore
    var onQueueChanged: () -> Void
    var onPlayEpisode: ((Episode) -> Void)? = nil
    var transcriptExists: ((String) -> Bool)? = nil
    var onViewTranscript: ((String) -> Void)? = nil
    var transcriptAffordanceGeneration: Int = 0
    var cleaningSummary: ((String) -> EpisodeCleaningSummary?)? = nil

    var body: some View {
        // Observe generation so representable refreshes when analysis UI changes.
        let _ = analysisViewModel.contentGeneration
        let _ = transcriptAffordanceGeneration
        return EpisodeTableViewRepresentable(
            feed: feed,
            analysisViewModel: analysisViewModel,
            downloadManager: downloadManager,
            queueStore: queueStore,
            onQueueChanged: onQueueChanged,
            onPlayEpisode: onPlayEpisode,
            transcriptExists: transcriptExists,
            onViewTranscript: onViewTranscript,
            transcriptAffordanceGeneration: transcriptAffordanceGeneration,
            cleaningSummary: cleaningSummary
        )
        .background(BrandTheme.surface)
    }
}

private struct EpisodeTableViewRepresentable: UIViewControllerRepresentable {
    let feed: PodcastFeed
    var analysisViewModel: AnalysisUIViewModel
    var downloadManager: DownloadManager
    var queueStore: QueueStore
    var onQueueChanged: () -> Void
    var onPlayEpisode: ((Episode) -> Void)?
    var transcriptExists: ((String) -> Bool)?
    var onViewTranscript: ((String) -> Void)?
    /// Explicit input so SwiftUI always calls `updateUIViewController` after backfill.
    var transcriptAffordanceGeneration: Int
    var cleaningSummary: ((String) -> EpisodeCleaningSummary?)?

    func makeUIViewController(context: Context) -> EpisodeTableViewController {
        EpisodeTableViewController(
            feed: feed,
            analysisViewModel: analysisViewModel,
            downloadManager: downloadManager,
            queueStore: queueStore,
            onQueueChanged: onQueueChanged,
            onPlayEpisode: onPlayEpisode,
            transcriptExists: transcriptExists,
            onViewTranscript: onViewTranscript,
            cleaningSummary: cleaningSummary
        )
    }

    func updateUIViewController(_ controller: EpisodeTableViewController, context: Context) {
        controller.update(
            feed: feed,
            analysisViewModel: analysisViewModel,
            downloadManager: downloadManager,
            queueStore: queueStore,
            onQueueChanged: onQueueChanged,
            onPlayEpisode: onPlayEpisode,
            transcriptExists: transcriptExists,
            onViewTranscript: onViewTranscript,
            transcriptAffordanceGeneration: transcriptAffordanceGeneration,
            cleaningSummary: cleaningSummary
        )
    }
}

private final class EpisodeTableViewController: UITableViewController {
    private var feed: PodcastFeed
    private var analysisViewModel: AnalysisUIViewModel
    private var downloadManager: DownloadManager
    private var queueStore: QueueStore
    private var onQueueChanged: () -> Void
    private var onPlayEpisode: ((Episode) -> Void)?
    private var transcriptExists: ((String) -> Bool)?
    private var onViewTranscript: ((String) -> Void)?
    private var cleaningSummary: ((String) -> EpisodeCleaningSummary?)?
    private var transcriptAffordanceGeneration = 0

    init(
        feed: PodcastFeed,
        analysisViewModel: AnalysisUIViewModel,
        downloadManager: DownloadManager,
        queueStore: QueueStore,
        onQueueChanged: @escaping () -> Void,
        onPlayEpisode: ((Episode) -> Void)?,
        transcriptExists: ((String) -> Bool)?,
        onViewTranscript: ((String) -> Void)?,
        cleaningSummary: ((String) -> EpisodeCleaningSummary?)?
    ) {
        self.feed = feed
        self.analysisViewModel = analysisViewModel
        self.downloadManager = downloadManager
        self.queueStore = queueStore
        self.onQueueChanged = onQueueChanged
        self.onPlayEpisode = onPlayEpisode
        self.transcriptExists = transcriptExists
        self.onViewTranscript = onViewTranscript
        self.cleaningSummary = cleaningSummary
        super.init(style: .plain)
        analysisViewModel.onAnalyzingEpisodeIDChanged = { [weak self] in
            guard let self else { return }
            self.refreshAnalysisDisplayOnVisibleRows()
        }
        analysisViewModel.primingEpisodeProvider = { [weak self] in
            self?.feed.episodes.first?.id
        }
        analysisViewModel.startAnalysisIfChannelCleaningAlreadyEnabled()
        downloadManager.onStateChanged = { [weak self] in
            guard let self else { return }
            self.refreshDownloadDisplayOnVisibleRows()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(EpisodeTableViewCell.self, forCellReuseIdentifier: EpisodeTableViewCell.reuseID)
        // Fixed height tall enough for title + date + analysis/download progress.
        // Avoid automaticDimension and beginUpdates (both can keep XCTest non-idle
        // until after the fixture analyzing window closes, dropping `analysisTimeline`).
        tableView.rowHeight = 140
        tableView.estimatedRowHeight = 140
        // Deliver touches to in-cell controls immediately — default delay makes
        // download / cleaning controls feel dead on device (Library path).
        tableView.delaysContentTouches = false
        applyListAccessibility()
        analysisViewModel.startAnalysisIfChannelCleaningAlreadyEnabled()
    }

    func update(
        feed: PodcastFeed,
        analysisViewModel: AnalysisUIViewModel,
        downloadManager: DownloadManager,
        queueStore: QueueStore,
        onQueueChanged: @escaping () -> Void,
        onPlayEpisode: ((Episode) -> Void)?,
        transcriptExists: ((String) -> Bool)?,
        onViewTranscript: ((String) -> Void)?,
        transcriptAffordanceGeneration: Int = 0,
        cleaningSummary: ((String) -> EpisodeCleaningSummary?)?
    ) {
        let feedChanged = self.feed != feed
        self.feed = feed
        self.analysisViewModel = analysisViewModel
        self.downloadManager = downloadManager
        self.queueStore = queueStore
        self.onQueueChanged = onQueueChanged
        self.onPlayEpisode = onPlayEpisode
        self.transcriptExists = transcriptExists
        self.onViewTranscript = onViewTranscript
        self.transcriptAffordanceGeneration = transcriptAffordanceGeneration
        self.cleaningSummary = cleaningSummary
        analysisViewModel.onAnalyzingEpisodeIDChanged = { [weak self] in
            guard let self else { return }
            self.refreshAnalysisDisplayOnVisibleRows()
        }
        analysisViewModel.primingEpisodeProvider = { [weak self] in
            self?.feed.episodes.first?.id
        }
        analysisViewModel.startAnalysisIfChannelCleaningAlreadyEnabled()
        downloadManager.onStateChanged = { [weak self] in
            guard let self else { return }
            self.refreshDownloadDisplayOnVisibleRows()
        }
        applyListAccessibility()
        if feedChanged {
            tableView.reloadData()
        } else {
            // Only refresh analysis here. Download chrome is pushed via
            // `downloadManager.onStateChanged` — re-applying it on every
            // analysis generation clobbers the transient `analysisTimeline` AX
            // surface before XCTest goes idle.
            refreshAnalysisDisplayOnVisibleRows()
            refreshQueueDisplayOnVisibleRows()
            // `transcriptAffordanceGeneration` is an explicit representable input so
            // SwiftUI invokes this update after task-020 backfill completes.
            refreshTranscriptDisplayOnVisibleRows()
        }
        layoutEpisodeTableIfReady()
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard let onPlayEpisode else { return }
        onPlayEpisode(feed.episodes[indexPath.row])
    }

    private func playHandler(for indexPath: IndexPath) -> () -> Void {
        { [weak self] in
            guard let self, let onPlayEpisode = self.onPlayEpisode else { return }
            onPlayEpisode(self.feed.episodes[indexPath.row])
        }
    }

    private func refreshDownloadDisplayOnVisibleRows() {
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            guard let cell = tableView.cellForRow(at: indexPath) as? EpisodeTableViewCell else { continue }
            let episode = feed.episodes[indexPath.row]
            cell.applyDownloadDisplay(
                downloadManager: downloadManager,
                episodeID: episode.id,
                index: indexPath.row
            )
        }
        layoutEpisodeTableIfReady()
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }

    private func refreshQueueDisplayOnVisibleRows() {
        let queued = Set(queueStore.queueEpisodeIDs())
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            guard let cell = tableView.cellForRow(at: indexPath) as? EpisodeTableViewCell else { continue }
            let episode = feed.episodes[indexPath.row]
            cell.applyQueueDisplay(isQueued: queued.contains(episode.id), index: indexPath.row)
        }
    }

    private func refreshTranscriptDisplayOnVisibleRows() {
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            guard let cell = tableView.cellForRow(at: indexPath) as? EpisodeTableViewCell else { continue }
            let episode = feed.episodes[indexPath.row]
            let showsTranscript = transcriptExists?(episode.id) ?? false
            cell.applyTranscriptAffordance(
                showsTranscript: showsTranscript,
                onViewTranscript: showsTranscript ? viewTranscriptHandler(for: indexPath) : nil
            )
        }
        layoutEpisodeTableIfReady()
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }

    private func refreshAnalysisDisplayOnVisibleRows() {
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            guard let cell = tableView.cellForRow(at: indexPath) as? EpisodeTableViewCell else { continue }
            let episode = feed.episodes[indexPath.row]
            cell.applyAnalysisDisplay(
                analysisViewModel: analysisViewModel,
                episodeID: episode.id,
                cleaningSummary: cleaningSummary
            )
        }
        layoutEpisodeTableIfReady()
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }

    /// Avoids UITableView layout-outside-hierarchy warnings and zero-width constraint
    /// recoveries while SwiftUI is still embedding the representable.
    private func layoutEpisodeTableIfReady() {
        guard tableView.window != nil, tableView.bounds.width > 0 else { return }
        tableView.layoutIfNeeded()
    }

    private func queueAddHandler(for indexPath: IndexPath) -> () -> Void {
        { [weak self] in
            guard let self else { return }
            let episode = self.feed.episodes[indexPath.row]
            try? self.queueStore.add(episode.id)
            self.onQueueChanged()
            self.refreshQueueDisplayOnVisibleRows()
        }
    }

    private func downloadButtonHandler(for indexPath: IndexPath) -> () -> Void {
        { [weak self] in
            guard let self else { return }
            let episode = self.feed.episodes[indexPath.row]
            let state = self.downloadManager.state(for: episode.id)

            switch state {
            case .notDownloaded, .failed:
                guard let remoteURL = episode.audioURL else {
                    // Never silently no-op — show failed affordance so the user can retry.
                    self.downloadManager.markFailed(episodeID: episode.id)
                    self.refreshDownloadDisplayOnVisibleRows()
                    return
                }
                // Fixture downloads complete synchronously on the main actor — run
                // inline so XCTest sees `downloaded` before post-tap idle settles.
                if FixtureDownload.isEnabled {
                    do {
                        _ = try self.downloadManager.completeFixtureDownloadForUITest(episodeID: episode.id)
                    } catch {
                        self.downloadManager.markFailed(episodeID: episode.id)
                        self.refreshDownloadDisplayOnVisibleRows()
                        return
                    }
                    self.refreshDownloadDisplayOnVisibleRows()
                    // Force a row reload so XCTest picks up accessibilityValue changes
                    // on accessory UIButtons (in-place mutation can be missed).
                    self.tableView.reloadRows(at: [indexPath], with: .none)
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.refreshDownloadDisplayOnVisibleRows()
                    do {
                        _ = try await self.downloadManager.download(
                            episodeID: episode.id,
                            from: remoteURL
                        ) { _ in
                            Task { @MainActor [weak self] in
                                self?.refreshDownloadDisplayOnVisibleRows()
                            }
                        }
                    } catch {
                        // DownloadManager already marks `.failed`; refresh chrome.
                    }
                    self.refreshDownloadDisplayOnVisibleRows()
                }
            case .downloaded:
                try? self.downloadManager.deleteDownload(episodeID: episode.id)
                self.refreshDownloadDisplayOnVisibleRows()
            case .downloading:
                break
            }
        }
    }

    private func viewTranscriptHandler(for indexPath: IndexPath) -> () -> Void {
        { [weak self] in
            guard let self else { return }
            let episode = self.feed.episodes[indexPath.row]
            self.onViewTranscript?(episode.id)
        }
    }

    private func applyListAccessibility() {
        tableView.accessibilityIdentifier = "episodeList"
        tableView.accessibilityLabel = "Episodes"
        tableView.accessibilityValue = "\(feed.episodes.count)"
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        feed.episodes.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: EpisodeTableViewCell.reuseID, for: indexPath) as! EpisodeTableViewCell
        let episode = feed.episodes[indexPath.row]
        let isQueued = queueStore.queueEpisodeIDs().contains(episode.id)
        let showsTranscript = transcriptExists?(episode.id) ?? false
        cell.configure(
            episode: episode,
            index: indexPath.row,
            analysisViewModel: analysisViewModel,
            downloadManager: downloadManager,
            isQueued: isQueued,
            showsTranscript: showsTranscript,
            cleaningSummary: cleaningSummary,
            onDownload: downloadButtonHandler(for: indexPath),
            onQueueAdd: queueAddHandler(for: indexPath),
            onViewTranscript: showsTranscript ? viewTranscriptHandler(for: indexPath) : nil,
            onPlay: onPlayEpisode == nil ? nil : playHandler(for: indexPath)
        )
        return cell
    }
}

final class EpisodeTableViewCell: UITableViewCell {
    static let reuseID = "episode"

    /// Horizontal pins that can yield during UITableView's transient zero-width pass.
    private static let deferredHorizontalPriority = UILayoutPriority(999)

    private let titleLabel = UILabel()
    private let dateLabel = UILabel()
    private let badgeLabel = UILabel()
    private let timelineBar = AnalysisTimelineBarView()
    private let progressAccessibilityHost = UIView()
    private let cleaningSummaryLabel = UILabel()
    private let downloadProgressView = UIActivityIndicatorView(style: .medium)
    private let downloadProgressLabel = UILabel()
    private let downloadProgressStack = UIStackView()
    private let downloadProgressAccessibilityHost = UIView()
    private let textStack = EpisodePlayStackView()
    private let downloadButton = UIButton(type: .system)
    private let queueAddButton = UIButton(type: .system)
    private let transcriptButton = UIButton(type: .system)
    private let accessoryStack = UIStackView()
    private var onDownload: (() -> Void)?
    private var onQueueAdd: (() -> Void)?
    private var onViewTranscript: (() -> Void)?
    private var onPlay: (() -> Void)?
    private var rowIndex: Int = 0
    private var cellAccessibilityValue: String?
    private var layoutTestingWidthConstraint: NSLayoutConstraint?
    private var downloadWidthConstraint: NSLayoutConstraint!
    private var queueAddWidthConstraint: NSLayoutConstraint!
    private var transcriptWidthConstraint: NSLayoutConstraint!
    private var textLeadingConstraint: NSLayoutConstraint!
    private var textTrailingConstraint: NSLayoutConstraint!
    private var accessoryTrailingConstraint: NSLayoutConstraint!
    private var timelineTrailingConstraint: NSLayoutConstraint!
    private var timelineHostHeightConstraint: NSLayoutConstraint!

    override var accessibilityValue: String? {
        get { cellAccessibilityValue }
        set { cellAccessibilityValue = newValue }
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func setupViews() {
        selectionStyle = .none
        isAccessibilityElement = false
        shouldGroupAccessibilityChildren = false
        contentView.isAccessibilityElement = false
        contentView.accessibilityElementsHidden = false
        contentView.shouldGroupAccessibilityChildren = false

        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.numberOfLines = 2

        dateLabel.font = .preferredFont(forTextStyle: .subheadline)
        dateLabel.textColor = .secondaryLabel

        badgeLabel.font = .preferredFont(forTextStyle: .caption2)
        badgeLabel.text = "Episode on"
        badgeLabel.textAlignment = .center
        badgeLabel.backgroundColor = UIColor.tintColor.withAlphaComponent(0.15)
        badgeLabel.layer.cornerRadius = 8
        badgeLabel.clipsToBounds = true
        badgeLabel.isHidden = true
        badgeLabel.accessibilityIdentifier = nil
        badgeLabel.accessibilityLabel = "Episode cleaning on"
        badgeLabel.isAccessibilityElement = false

        timelineBar.isAccessibilityElement = false

        progressAccessibilityHost.isHidden = true
        progressAccessibilityHost.isAccessibilityElement = false
        progressAccessibilityHost.accessibilityLabel = nil
        progressAccessibilityHost.accessibilityHint = nil
        progressAccessibilityHost.isUserInteractionEnabled = false
        progressAccessibilityHost.addSubview(timelineBar)
        timelineBar.translatesAutoresizingMaskIntoConstraints = false
        let timelineTrailing = timelineBar.trailingAnchor.constraint(equalTo: progressAccessibilityHost.trailingAnchor)
        timelineTrailing.priority = Self.deferredHorizontalPriority
        timelineTrailingConstraint = timelineTrailing
        // Task 026: production rows keep height 0. Layout-test seam raises this to 16.
        let timelineHostHeight = progressAccessibilityHost.heightAnchor.constraint(equalToConstant: 0)
        timelineHostHeightConstraint = timelineHostHeight
        NSLayoutConstraint.activate([
            timelineBar.leadingAnchor.constraint(equalTo: progressAccessibilityHost.leadingAnchor),
            timelineTrailing,
            timelineBar.topAnchor.constraint(equalTo: progressAccessibilityHost.topAnchor, constant: 4),
            timelineBar.bottomAnchor.constraint(equalTo: progressAccessibilityHost.bottomAnchor, constant: -4),
            timelineHostHeight,
        ])

        textStack.axis = .vertical
        textStack.isAccessibilityElement = false
        textStack.spacing = 4
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(dateLabel)
        textStack.addArrangedSubview(badgeLabel)
        // Task 026: row timeline host stays out of the production stack so height collapses.
        // `layoutTesting_exposeTimelineBar` re-inserts it for Task 006 width-fill only.
        textStack.addArrangedSubview(cleaningSummaryLabel)
        textStack.addArrangedSubview(downloadProgressAccessibilityHost)

        cleaningSummaryLabel.font = .preferredFont(forTextStyle: .caption1)
        cleaningSummaryLabel.textColor = .secondaryLabel
        cleaningSummaryLabel.numberOfLines = 1
        cleaningSummaryLabel.isHidden = true
        cleaningSummaryLabel.isAccessibilityElement = false
        cleaningSummaryLabel.isUserInteractionEnabled = false
        cleaningSummaryLabel.accessibilityTraits = .staticText
        cleaningSummaryLabel.accessibilityLabel = "Cleaning summary"
        cleaningSummaryLabel.accessibilityHint =
            "Shows how many profanity and ad sections were cleaned and total ad time skipped."

        downloadProgressLabel.font = .preferredFont(forTextStyle: .caption1)
        downloadProgressLabel.text = "Downloading…"
        downloadProgressLabel.textColor = .secondaryLabel
        downloadProgressLabel.isAccessibilityElement = false

        downloadProgressView.hidesWhenStopped = false
        downloadProgressStack.axis = .horizontal
        downloadProgressStack.spacing = 8
        downloadProgressStack.alignment = .center
        downloadProgressStack.addArrangedSubview(downloadProgressView)
        downloadProgressStack.isAccessibilityElement = false
        downloadProgressView.isAccessibilityElement = false

        downloadProgressAccessibilityHost.isHidden = true
        downloadProgressAccessibilityHost.isAccessibilityElement = false
        downloadProgressAccessibilityHost.accessibilityLabel = "Downloading episode"
        downloadProgressAccessibilityHost.isUserInteractionEnabled = false
        downloadProgressAccessibilityHost.addSubview(downloadProgressStack)
        downloadProgressAccessibilityHost.addSubview(downloadProgressLabel)
        downloadProgressStack.translatesAutoresizingMaskIntoConstraints = false
        downloadProgressLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            downloadProgressStack.leadingAnchor.constraint(equalTo: downloadProgressAccessibilityHost.leadingAnchor),
            downloadProgressStack.topAnchor.constraint(equalTo: downloadProgressAccessibilityHost.topAnchor),
            downloadProgressStack.bottomAnchor.constraint(equalTo: downloadProgressAccessibilityHost.bottomAnchor),
            downloadProgressLabel.leadingAnchor.constraint(equalTo: downloadProgressStack.trailingAnchor, constant: 8),
            downloadProgressLabel.trailingAnchor.constraint(lessThanOrEqualTo: downloadProgressAccessibilityHost.trailingAnchor),
            downloadProgressLabel.centerYAnchor.constraint(equalTo: downloadProgressAccessibilityHost.centerYAnchor),
            downloadProgressAccessibilityHost.heightAnchor.constraint(greaterThanOrEqualToConstant: 22),
        ])

        downloadButton.addTarget(self, action: #selector(downloadTapped), for: .touchUpInside)
        downloadButton.isAccessibilityElement = true
        downloadButton.accessibilityTraits = .button
        downloadButton.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(textStyle: .body),
            forImageIn: .normal
        )
        // Fixed 44×44 — a flexible >=44 width let UIStackView .fill expand the
        // queue button across the cell center, so XCTest episodeCell_*.tap() hit
        // "Add to queue" instead of starting playback (Library mini-player miss).
        downloadButton.translatesAutoresizingMaskIntoConstraints = false
        downloadButton.setContentHuggingPriority(.required, for: .horizontal)
        downloadButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let downloadWidth = downloadButton.widthAnchor.constraint(equalToConstant: 44)
        downloadWidth.priority = Self.deferredHorizontalPriority
        downloadWidthConstraint = downloadWidth
        NSLayoutConstraint.activate([
            downloadWidth,
            downloadButton.heightAnchor.constraint(equalToConstant: 44),
        ])

        queueAddButton.addTarget(self, action: #selector(queueAddTapped), for: .touchUpInside)
        queueAddButton.isAccessibilityElement = true
        queueAddButton.accessibilityTraits = .button
        queueAddButton.setImage(UIImage(systemName: "text.badge.plus"), for: .normal)
        queueAddButton.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(textStyle: .body),
            forImageIn: .normal
        )
        queueAddButton.translatesAutoresizingMaskIntoConstraints = false
        queueAddButton.setContentHuggingPriority(.required, for: .horizontal)
        queueAddButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let queueAddWidth = queueAddButton.widthAnchor.constraint(equalToConstant: 44)
        queueAddWidth.priority = Self.deferredHorizontalPriority
        queueAddWidthConstraint = queueAddWidth
        NSLayoutConstraint.activate([
            queueAddWidth,
            queueAddButton.heightAnchor.constraint(equalToConstant: 44),
        ])

        transcriptButton.addTarget(self, action: #selector(transcriptTapped), for: .touchUpInside)
        transcriptButton.isAccessibilityElement = true
        transcriptButton.accessibilityTraits = .button
        transcriptButton.setImage(UIImage(systemName: "text.alignleft"), for: .normal)
        transcriptButton.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(textStyle: .body),
            forImageIn: .normal
        )
        transcriptButton.translatesAutoresizingMaskIntoConstraints = false
        transcriptButton.setContentHuggingPriority(.required, for: .horizontal)
        transcriptButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        transcriptButton.accessibilityIdentifier = "episode.viewTranscript"
        transcriptButton.accessibilityLabel = "View transcript"
        transcriptButton.accessibilityHint = "Shows the episode transcript."
        let transcriptWidth = transcriptButton.widthAnchor.constraint(equalToConstant: 44)
        transcriptWidth.priority = Self.deferredHorizontalPriority
        transcriptWidthConstraint = transcriptWidth
        NSLayoutConstraint.activate([
            transcriptWidth,
            transcriptButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        transcriptButton.isHidden = true

        accessoryStack.axis = .horizontal
        accessoryStack.spacing = 8
        accessoryStack.alignment = .center
        accessoryStack.distribution = .fill
        accessoryStack.addArrangedSubview(transcriptButton)
        accessoryStack.addArrangedSubview(queueAddButton)
        accessoryStack.addArrangedSubview(downloadButton)
        accessoryStack.translatesAutoresizingMaskIntoConstraints = false
        accessoryStack.setContentHuggingPriority(.required, for: .horizontal)
        accessoryStack.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        // Pin accessories in contentView (not UITableView's accessoryView) so SwiftUI
        // representable layout passes position controls on the trailing edge, not over titles.
        contentView.addSubview(textStack)
        contentView.addSubview(accessoryStack)
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let textLeading = textStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16)
        let textTrailing = textStack.trailingAnchor.constraint(equalTo: accessoryStack.leadingAnchor, constant: -8)
        let accessoryTrailing = accessoryStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        textLeading.priority = Self.deferredHorizontalPriority
        textTrailing.priority = Self.deferredHorizontalPriority
        accessoryTrailing.priority = Self.deferredHorizontalPriority
        textLeadingConstraint = textLeading
        textTrailingConstraint = textTrailing
        accessoryTrailingConstraint = accessoryTrailing
        NSLayoutConstraint.activate([
            textLeading,
            textStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            textStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            textTrailing,

            accessoryTrailing,
            accessoryStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            accessoryStack.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

            badgeLabel.heightAnchor.constraint(equalToConstant: 22),
        ])
        contentView.bringSubviewToFront(accessoryStack)

        let playTap = UITapGestureRecognizer(target: self, action: #selector(playTapped))
        playTap.cancelsTouchesInView = false
        textStack.isUserInteractionEnabled = true
        textStack.addGestureRecognizer(playTap)
        // Baseline AX children so buttons stay queryable before any badge host is published.
        updateAccessibilityElements(
            showsAnalysisTimeline: false,
            showsCleaningSummary: false,
            showsDownloadProgress: false,
            showsBadge: false
        )
    }

    override func updateConstraints() {
        updateHorizontalConstraintPriorities()
        super.updateConstraints()
    }

    /// Tighten horizontal pins once the cell has a real width; defer during UITableView's
    /// transient zero-width SwiftUI embed pass so Auto Layout does not recover loudly.
    private func updateHorizontalConstraintPriorities() {
        let tight = contentView.bounds.width > 1
        let priority: UILayoutPriority = tight ? .required : Self.deferredHorizontalPriority
        downloadWidthConstraint.priority = priority
        queueAddWidthConstraint.priority = priority
        transcriptWidthConstraint.priority = priority
        textLeadingConstraint.priority = priority
        textTrailingConstraint.priority = priority
        accessoryTrailingConstraint.priority = priority
        timelineTrailingConstraint.priority = priority

        let compression: UILayoutPriority = tight ? .required : .defaultHigh
        downloadButton.setContentCompressionResistancePriority(compression, for: .horizontal)
        queueAddButton.setContentCompressionResistancePriority(compression, for: .horizontal)
        transcriptButton.setContentCompressionResistancePriority(compression, for: .horizontal)
        accessoryStack.setContentCompressionResistancePriority(compression, for: .horizontal)
    }

    func configure(
        episode: Episode,
        index: Int,
        analysisViewModel: AnalysisUIViewModel,
        downloadManager: DownloadManager,
        isQueued: Bool,
        showsTranscript: Bool,
        cleaningSummary: ((String) -> EpisodeCleaningSummary?)?,
        onDownload: @escaping () -> Void,
        onQueueAdd: @escaping () -> Void,
        onViewTranscript: (() -> Void)?,
        onPlay: (() -> Void)? = nil
    ) {
        self.onDownload = onDownload
        self.onQueueAdd = onQueueAdd
        self.onViewTranscript = onViewTranscript
        self.onPlay = onPlay
        self.rowIndex = index

        titleLabel.text = episode.title
        dateLabel.text = EpisodeListFormatting.localizedDate(from: episode.pubDate)

        downloadButton.accessibilityIdentifier = "downloadButton_\(index)"
        applyQueueDisplay(isQueued: isQueued, index: index)
        applyTranscriptDisplay(showsTranscript: showsTranscript)
        applyAnalysisDisplay(
            analysisViewModel: analysisViewModel,
            episodeID: episode.id,
            cleaningSummary: cleaningSummary
        )
        applyDownloadDisplay(
            downloadManager: downloadManager,
            episodeID: episode.id,
            index: index
        )

        cellAccessibilityValue = EpisodeListFormatting.iso8601String(from: episode.pubDate)

        // Single `episodeCell_*` on the UITableViewCell only — never also on
        // textStack. Duplicate IDs make `app.descendants[.any]["episodeCell_N"]`
        // ambiguous and XCTest `.tap()` fails with "Multiple matching elements".
        // Library play: textStack stays the activatable child; cell center taps
        // route via hitTest / accessibilityActivate. `app.cells[...]` still
        // scopes `episode.viewTranscript` (Slice 26).
        isAccessibilityElement = false
        accessibilityTraits = .none
        accessibilityIdentifier = "episodeCell_\(index)"
        accessoryStack.accessibilityElementsHidden = false
        accessoryStack.isUserInteractionEnabled = true
        queueAddButton.isAccessibilityElement = true
        downloadButton.isAccessibilityElement = true
        transcriptButton.isAccessibilityElement = showsTranscript

        if onPlay != nil {
            accessibilityLabel = nil
            textStack.accessibilityIdentifier = nil
            textStack.isAccessibilityElement = true
            textStack.accessibilityTraits = .button
            textStack.accessibilityLabel = episode.title
            textStack.accessibilityHint = "Plays this episode."
            textStack.accessibilityValue = cellAccessibilityValue
            textStack.onActivate = { [weak self] in self?.onPlay?() }
        } else {
            accessibilityLabel = episode.title
            textStack.accessibilityIdentifier = nil
            textStack.isAccessibilityElement = false
            textStack.accessibilityTraits = .none
            textStack.accessibilityLabel = nil
            textStack.accessibilityHint = nil
            textStack.accessibilityValue = nil
            textStack.onActivate = nil
        }

        titleLabel.isAccessibilityElement = false
        dateLabel.isAccessibilityElement = false
    }

    func applyTranscriptDisplay(showsTranscript: Bool) {
        transcriptButton.isHidden = !showsTranscript
        transcriptButton.isAccessibilityElement = showsTranscript
        transcriptButton.accessibilityIdentifier = showsTranscript ? "episode.viewTranscript" : nil
        transcriptButton.accessibilityLabel = showsTranscript ? "View transcript" : nil
        transcriptButton.accessibilityHint = showsTranscript ? "Shows the episode transcript." : nil
    }

    func applyTranscriptAffordance(showsTranscript: Bool, onViewTranscript: (() -> Void)?) {
        self.onViewTranscript = onViewTranscript
        applyTranscriptDisplay(showsTranscript: showsTranscript)
    }

    func applyQueueDisplay(isQueued: Bool, index: Int) {
        queueAddButton.accessibilityIdentifier = "queueAddButton_\(index)"
        queueAddButton.isEnabled = !isQueued
        queueAddButton.accessibilityValue = isQueued ? "queued" : "notQueued"
        queueAddButton.accessibilityLabel = isQueued ? "In queue" : "Add to queue"
        queueAddButton.accessibilityHint = isQueued ? nil : "Adds this episode to up next."
    }

    func applyDownloadDisplay(
        downloadManager: DownloadManager,
        episodeID: String,
        index: Int
    ) {
        let state = downloadManager.state(for: episodeID)
        let showsProgress: Bool
        let value: String
        let label: String
        let hint: String?
        let symbolName: String
        let isEnabled: Bool

        switch state {
        case .notDownloaded:
            showsProgress = false
            value = "notDownloaded"
            label = "Download episode"
            hint = nil
            symbolName = "arrow.down.circle"
            isEnabled = true
        case .failed:
            showsProgress = false
            value = "failed"
            label = "Download failed"
            hint = "Download failed. Tap to retry."
            symbolName = "exclamationmark.circle"
            isEnabled = true
        case .downloading:
            showsProgress = true
            value = "downloading"
            label = "Downloading episode"
            hint = nil
            symbolName = "arrow.down.circle"
            isEnabled = false
        case .downloaded:
            showsProgress = false
            value = "downloaded"
            label = "Delete download"
            hint = "Removes downloaded audio from this device. Tap to delete."
            symbolName = "trash"
            isEnabled = true
        }

        downloadButton.setImage(UIImage(systemName: symbolName), for: .normal)
        downloadButton.tintColor = (state == .failed || state == .downloaded) ? .systemRed : .tintColor
        downloadButton.isEnabled = isEnabled
        downloadButton.isAccessibilityElement = true
        downloadButton.accessibilityTraits = .button
        downloadButton.accessibilityValue = value
        downloadButton.accessibilityLabel = label
        downloadButton.accessibilityHint = hint
        downloadButton.accessibilityIdentifier = "downloadButton_\(index)"

        downloadProgressAccessibilityHost.isHidden = !showsProgress
        downloadProgressAccessibilityHost.isAccessibilityElement = showsProgress
        downloadProgressAccessibilityHost.accessibilityIdentifier = showsProgress ? "downloadProgress_\(index)" : nil
        downloadProgressAccessibilityHost.accessibilityLabel = "Downloading episode"
        downloadProgressLabel.isHidden = !showsProgress
        if showsProgress && !FixtureDownload.isEnabled {
            downloadProgressView.startAnimating()
        } else {
            downloadProgressView.stopAnimating()
        }

        updateAccessibilityElements(
            showsAnalysisTimeline: false,
            showsCleaningSummary: !cleaningSummaryLabel.isHidden,
            showsDownloadProgress: showsProgress,
            showsBadge: !badgeLabel.isHidden
        )

        setNeedsLayout()
        layoutIfNeeded()
        // Avoid layoutChanged here — callers post once after all visible rows
        // update. Extra posts during the analyzing window race XCTest idle.
    }

    func applyAnalysisDisplay(
        analysisViewModel: AnalysisUIViewModel,
        episodeID: String,
        cleaningSummary: ((String) -> EpisodeCleaningSummary?)?
    ) {
        let isAnalysisInFlight = analysisViewModel.episodeRowShowsTimeline(episodeID: episodeID)
        let showsBadge = analysisViewModel.episodeRowShowsOnBadge(episodeID: episodeID)

        badgeLabel.isHidden = !showsBadge
        badgeLabel.isAccessibilityElement = showsBadge
        badgeLabel.accessibilityIdentifier = showsBadge ? "cleaningBadge_episodeOn" : nil
        badgeLabel.accessibilityLabel = "Episode cleaning on"

        // Task 026: row timeline retired — player super-seek bar owns in-flight chrome.
        progressAccessibilityHost.isHidden = true
        progressAccessibilityHost.isAccessibilityElement = false
        progressAccessibilityHost.accessibilityIdentifier = nil
        progressAccessibilityHost.accessibilityLabel = nil
        progressAccessibilityHost.accessibilityHint = nil
        progressAccessibilityHost.accessibilityValue = nil
        timelineHostHeightConstraint.constant = 0

        // Complete gate: summary only when not in-flight and cache hit (ADR-025 §5).
        let summary = isAnalysisInFlight ? nil : cleaningSummary?(episodeID)
        let showsSummary = summary != nil
        cleaningSummaryLabel.isHidden = !showsSummary
        cleaningSummaryLabel.isAccessibilityElement = showsSummary
        cleaningSummaryLabel.accessibilityIdentifier = showsSummary ? "episode.cleaningSummary" : nil
        if let summary {
            cleaningSummaryLabel.text = CleaningSummaryModel.visibleLabel(from: summary)
            cleaningSummaryLabel.accessibilityLabel = "Cleaning summary"
            cleaningSummaryLabel.accessibilityHint =
                "Shows how many profanity and ad sections were cleaned and total ad time skipped."
            cleaningSummaryLabel.accessibilityValue = CleaningSummaryModel.accessibilityValue(from: summary)
        } else {
            cleaningSummaryLabel.text = nil
            cleaningSummaryLabel.accessibilityValue = nil
        }

        updateAccessibilityElements(
            showsAnalysisTimeline: false,
            showsCleaningSummary: showsSummary,
            showsDownloadProgress: !downloadProgressAccessibilityHost.isHidden,
            showsBadge: showsBadge
        )

        setNeedsLayout()
        layoutIfNeeded()
    }

    private func updateAccessibilityElements(
        showsAnalysisTimeline: Bool,
        showsCleaningSummary: Bool,
        showsDownloadProgress: Bool,
        showsBadge: Bool
    ) {
        // Always keep accessories queryable/tappable. Library play uses `textStack`
        // as the dedicated activatable region (not a collapsed whole-cell AX element).
        isAccessibilityElement = false
        accessoryStack.accessibilityElementsHidden = false
        queueAddButton.isAccessibilityElement = true
        downloadButton.isAccessibilityElement = true
        transcriptButton.isAccessibilityElement = !transcriptButton.isHidden

        var axChildren: [UIView] = []
        if onPlay != nil {
            textStack.isAccessibilityElement = true
            textStack.accessibilityTraits = .button
            axChildren.append(textStack)
        } else {
            textStack.isAccessibilityElement = false
        }
        if !transcriptButton.isHidden {
            axChildren.append(transcriptButton)
        }
        axChildren.append(contentsOf: [queueAddButton, downloadButton])
        if showsDownloadProgress {
            axChildren.append(downloadProgressAccessibilityHost)
        }
        if showsAnalysisTimeline {
            axChildren.append(progressAccessibilityHost)
        }
        if showsBadge {
            axChildren.append(badgeLabel)
        }
        if showsCleaningSummary {
            axChildren.append(cleaningSummaryLabel)
        }
        // Publish AX children on the *cell* (not contentView). After Slice 22 moved
        // accessories into contentView, assigning only timeline to
        // `contentView.accessibilityElements` left nested hosts invisible to
        // XCTest descendant queries even when on-screen.
        accessibilityElements = axChildren
        contentView.accessibilityElements = nil
    }

    @objc private func downloadTapped() {
        onDownload?()
    }

    @objc private func queueAddTapped() {
        onQueueAdd?()
    }

    @objc private func transcriptTapped() {
        onViewTranscript?()
    }

    @objc private func playTapped() {
        onPlay?()
    }

    override func accessibilityActivate() -> Bool {
        // Prefer play-region activation; keep cell activate as a Library fallback
        // when XCTest taps `episodeCell_*` on the cell container.
        if let onPlay {
            onPlay()
            return true
        }
        return super.accessibilityActivate()
    }

    /// Keep accessory 44pt controls tappable; route body taps to play when wired.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard onPlay != nil else {
            return super.hitTest(point, with: event)
        }
        // Prefer accessories so download / queue never lose to play.
        let accessoryPoint = convert(point, to: accessoryStack)
        if accessoryStack.bounds.contains(accessoryPoint),
           let accessoryHit = accessoryStack.hitTest(accessoryPoint, with: event) {
            return accessoryHit
        }
        let textPoint = convert(point, to: textStack)
        if textStack.bounds.contains(textPoint),
           let textHit = textStack.hitTest(textPoint, with: event) {
            return textHit
        }
        // Cell-center taps that miss textStack still start playback (Library AC4).
        if bounds.contains(point) {
            return textStack
        }
        return super.hitTest(point, with: event)
    }

    // MARK: - Layout testing (Task 006)

    func layoutTesting_applyContentWidth(_ width: CGFloat) {
        let height: CGFloat = 140
        bounds = CGRect(x: 0, y: 0, width: width, height: height)
        contentView.bounds = CGRect(x: 0, y: 0, width: width, height: height)

        layoutTestingWidthConstraint?.isActive = false
        let widthConstraint = contentView.widthAnchor.constraint(equalToConstant: width)
        widthConstraint.priority = .required
        widthConstraint.isActive = true
        layoutTestingWidthConstraint = widthConstraint

        setNeedsUpdateConstraints()
        updateConstraintsIfNeeded()
        setNeedsLayout()
        layoutIfNeeded()
    }

    var layoutTesting_textStack: UIStackView { textStack }
    var layoutTesting_accessoryStack: UIStackView { accessoryStack }
    var layoutTesting_queueAddButton: UIButton { queueAddButton }
    var layoutTesting_downloadButton: UIButton { downloadButton }
    var layoutTesting_timelineHost: UIView { progressAccessibilityHost }
    var layoutTesting_timelineBar: AnalysisTimelineBarView { timelineBar }

    /// Task 006 width-fill layout test only — production configure paths keep the host collapsed.
    func layoutTesting_exposeTimelineBar(colors: [TimelineSegmentColor]) {
        timelineBar.apply(colors: colors)
        if progressAccessibilityHost.superview == nil {
            // Insert after badge (title, date, badge, timeline, …).
            let insertIndex = min(3, textStack.arrangedSubviews.count)
            textStack.insertArrangedSubview(progressAccessibilityHost, at: insertIndex)
        }
        timelineHostHeightConstraint.constant = 16
        progressAccessibilityHost.isHidden = false
        progressAccessibilityHost.isAccessibilityElement = false
        progressAccessibilityHost.accessibilityIdentifier = nil
    }
}

enum EpisodeTableViewCellLayoutTesting {
    static func makeConfiguredCell(
        episode: Episode,
        index: Int,
        analysisViewModel: AnalysisUIViewModel,
        downloadManager: DownloadManager,
        isQueued: Bool
    ) -> EpisodeTableViewCell {
        let cell = EpisodeTableViewCell(style: .default, reuseIdentifier: EpisodeTableViewCell.reuseID)
        cell.configure(
            episode: episode,
            index: index,
            analysisViewModel: analysisViewModel,
            downloadManager: downloadManager,
            isQueued: isQueued,
            showsTranscript: false,
            cleaningSummary: nil,
            onDownload: {},
            onQueueAdd: {},
            onViewTranscript: nil
        )
        // Task 006 layout pin: expose bar geometry for fixture-ep-001 only.
        if episode.id == "fixture-ep-001",
           let colors = analysisViewModel.episodeRowTimelineColors(episodeID: episode.id) {
            cell.layoutTesting_exposeTimelineBar(colors: colors)
        }
        return cell
    }

    static func layoutAtContentWidth(_ width: CGFloat, cell: EpisodeTableViewCell) {
        cell.layoutTesting_applyContentWidth(width)
    }

    static func queueAddButton(in cell: EpisodeTableViewCell) -> UIButton {
        cell.layoutTesting_queueAddButton
    }

    static func downloadButton(in cell: EpisodeTableViewCell) -> UIButton {
        cell.layoutTesting_downloadButton
    }

    static func textStack(in cell: EpisodeTableViewCell) -> UIStackView {
        cell.layoutTesting_textStack
    }

    static func accessoryStack(in cell: EpisodeTableViewCell) -> UIStackView {
        cell.layoutTesting_accessoryStack
    }

    static func timelineHost(in cell: EpisodeTableViewCell) -> UIView {
        cell.layoutTesting_timelineHost
    }

    static func timelineBar(in cell: EpisodeTableViewCell) -> AnalysisTimelineBarView {
        cell.layoutTesting_timelineBar
    }
}

/// Title/date stack that VoiceOver / XCTest can activate to start playback.
private final class EpisodePlayStackView: UIStackView {
    var onActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        if let onActivate {
            onActivate()
            return true
        }
        return super.accessibilityActivate()
    }
}

private enum EpisodeListFormatting {
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func iso8601String(from date: Date) -> String {
        iso8601Formatter.string(from: date)
    }

    static func localizedDate(from date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }
}
