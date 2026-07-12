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

    var body: some View {
        // Observe generation so representable refreshes when analysis UI changes.
        let _ = analysisViewModel.contentGeneration
        return EpisodeTableViewRepresentable(
            feed: feed,
            analysisViewModel: analysisViewModel,
            downloadManager: downloadManager,
            queueStore: queueStore,
            onQueueChanged: onQueueChanged,
            onPlayEpisode: onPlayEpisode
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

    func makeUIViewController(context: Context) -> EpisodeTableViewController {
        EpisodeTableViewController(
            feed: feed,
            analysisViewModel: analysisViewModel,
            downloadManager: downloadManager,
            queueStore: queueStore,
            onQueueChanged: onQueueChanged,
            onPlayEpisode: onPlayEpisode
        )
    }

    func updateUIViewController(_ controller: EpisodeTableViewController, context: Context) {
        controller.update(
            feed: feed,
            analysisViewModel: analysisViewModel,
            downloadManager: downloadManager,
            queueStore: queueStore,
            onQueueChanged: onQueueChanged,
            onPlayEpisode: onPlayEpisode
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

    init(
        feed: PodcastFeed,
        analysisViewModel: AnalysisUIViewModel,
        downloadManager: DownloadManager,
        queueStore: QueueStore,
        onQueueChanged: @escaping () -> Void,
        onPlayEpisode: ((Episode) -> Void)?
    ) {
        self.feed = feed
        self.analysisViewModel = analysisViewModel
        self.downloadManager = downloadManager
        self.queueStore = queueStore
        self.onQueueChanged = onQueueChanged
        self.onPlayEpisode = onPlayEpisode
        super.init(style: .plain)
        analysisViewModel.onAnalyzingEpisodeIDChanged = { [weak self] in
            guard let self else { return }
            self.refreshAnalysisDisplayOnVisibleRows()
        }
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
    }

    func update(
        feed: PodcastFeed,
        analysisViewModel: AnalysisUIViewModel,
        downloadManager: DownloadManager,
        queueStore: QueueStore,
        onQueueChanged: @escaping () -> Void,
        onPlayEpisode: ((Episode) -> Void)?
    ) {
        let feedChanged = self.feed != feed
        self.feed = feed
        self.analysisViewModel = analysisViewModel
        self.downloadManager = downloadManager
        self.queueStore = queueStore
        self.onQueueChanged = onQueueChanged
        self.onPlayEpisode = onPlayEpisode
        analysisViewModel.onAnalyzingEpisodeIDChanged = { [weak self] in
            guard let self else { return }
            self.refreshAnalysisDisplayOnVisibleRows()
        }
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
        }
        tableView.layoutIfNeeded()
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
        tableView.layoutIfNeeded()
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

    private func refreshAnalysisDisplayOnVisibleRows() {
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            guard let cell = tableView.cellForRow(at: indexPath) as? EpisodeTableViewCell else { continue }
            let episode = feed.episodes[indexPath.row]
            cell.applyAnalysisDisplay(
                analysisViewModel: analysisViewModel,
                episodeID: episode.id
            )
        }
        tableView.layoutIfNeeded()
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
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
    private func episodeToggleHandler(for indexPath: IndexPath) -> (Bool) -> Void {
        { [weak self] enabled in
            guard let self else { return }
            let episodeID = self.feed.episodes[indexPath.row].id
            if enabled && self.analysisViewModel.autoAnalyzeOnEpisodeEnable {
                // Publish progress synchronously so the AX tree updates before the
                // toggle handler returns. Completion runs in a Task (not
                // `asyncAfter`): pending GCD timers keep XCTest non-idle until
                // they fire, so the app only becomes idle *after* progress is
                // already cleared. `Task.sleep` inside the view model suspends
                // without blocking idleness, leaving `analysisTimeline` visible.
                self.analysisViewModel.primeEpisodeCleaningToggle(episodeID: episodeID)
                // Keep the UISwitch visually on even if a later representable
                // refresh races setCleaningSwitch from a momentarily stale read.
                if let cell = self.tableView.cellForRow(at: indexPath) as? EpisodeTableViewCell {
                    cell.forceCleaningSwitchOnForAnalysis()
                }
                self.refreshAnalysisDisplayOnVisibleRows()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.analysisViewModel.completePrimedEpisodeAnalysis(episodeID: episodeID)
                    self.refreshAnalysisDisplayOnVisibleRows()
                }
            } else {
                // Publish badge synchronously so XCTest's post-tap idle sees
                // `cleaningBadge_episodeOn` (a detached Task can miss the window).
                self.analysisViewModel.applyEpisodeCleaningWithoutAnalysis(
                    episodeID: episodeID,
                    enabled: enabled
                )
                self.refreshAnalysisDisplayOnVisibleRows()
            }
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
        cell.configure(
            episode: episode,
            index: indexPath.row,
            analysisViewModel: analysisViewModel,
            downloadManager: downloadManager,
            isQueued: isQueued,
            onToggle: episodeToggleHandler(for: indexPath),
            onDownload: downloadButtonHandler(for: indexPath),
            onQueueAdd: queueAddHandler(for: indexPath),
            onPlay: onPlayEpisode == nil ? nil : playHandler(for: indexPath)
        )
        return cell
    }
}

private final class EpisodeTableViewCell: UITableViewCell {
    static let reuseID = "episode"

    private let titleLabel = UILabel()
    private let dateLabel = UILabel()
    private let badgeLabel = UILabel()
    private let timelineBar = AnalysisTimelineBarView()
    private let progressAccessibilityHost = UIView()
    private let downloadProgressView = UIActivityIndicatorView(style: .medium)
    private let downloadProgressLabel = UILabel()
    private let downloadProgressStack = UIStackView()
    private let downloadProgressAccessibilityHost = UIView()
    private let textStack = EpisodePlayStackView()
    private let downloadButton = UIButton(type: .system)
    private let queueAddButton = UIButton(type: .system)
    private let cleaningSwitch = UISwitch()
    private let accessoryStack = UIStackView()
    private var onToggle: ((Bool) -> Void)?
    private var onDownload: (() -> Void)?
    private var onQueueAdd: (() -> Void)?
    private var onPlay: (() -> Void)?
    private var rowIndex: Int = 0
    private var cellAccessibilityValue: String?

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
        NSLayoutConstraint.activate([
            timelineBar.leadingAnchor.constraint(equalTo: progressAccessibilityHost.leadingAnchor),
            timelineBar.trailingAnchor.constraint(equalTo: progressAccessibilityHost.trailingAnchor),
            timelineBar.topAnchor.constraint(equalTo: progressAccessibilityHost.topAnchor, constant: 4),
            timelineBar.bottomAnchor.constraint(equalTo: progressAccessibilityHost.bottomAnchor, constant: -4),
            progressAccessibilityHost.heightAnchor.constraint(greaterThanOrEqualToConstant: 16),
        ])

        textStack.axis = .vertical
        textStack.isAccessibilityElement = false
        textStack.spacing = 4
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(dateLabel)
        textStack.addArrangedSubview(badgeLabel)
        textStack.addArrangedSubview(progressAccessibilityHost)
        textStack.addArrangedSubview(downloadProgressAccessibilityHost)

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
        downloadButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            downloadButton.widthAnchor.constraint(equalToConstant: 44),
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
        queueAddButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            queueAddButton.widthAnchor.constraint(equalToConstant: 44),
            queueAddButton.heightAnchor.constraint(equalToConstant: 44),
        ])

        cleaningSwitch.isAccessibilityElement = true

        accessoryStack.axis = .horizontal
        accessoryStack.spacing = 8
        accessoryStack.alignment = .center
        accessoryStack.distribution = .fill
        accessoryStack.addArrangedSubview(queueAddButton)
        accessoryStack.addArrangedSubview(downloadButton)
        accessoryStack.addArrangedSubview(cleaningSwitch)
        accessoryStack.translatesAutoresizingMaskIntoConstraints = false
        accessoryStack.setContentHuggingPriority(.required, for: .horizontal)
        accessoryStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Pin accessories in contentView (not UITableView's accessoryView) so SwiftUI
        // representable layout passes position controls on the trailing edge, not over titles.
        contentView.addSubview(textStack)
        contentView.addSubview(accessoryStack)
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            textStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            textStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            textStack.trailingAnchor.constraint(equalTo: accessoryStack.leadingAnchor, constant: -8),

            accessoryStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            accessoryStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            accessoryStack.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

            badgeLabel.heightAnchor.constraint(equalToConstant: 22),
        ])
        contentView.bringSubviewToFront(accessoryStack)

        cleaningSwitch.addTarget(self, action: #selector(switchChanged), for: .valueChanged)
        let playTap = UITapGestureRecognizer(target: self, action: #selector(playTapped))
        playTap.cancelsTouchesInView = false
        textStack.isUserInteractionEnabled = true
        textStack.addGestureRecognizer(playTap)
        // Baseline AX children so switches/buttons stay queryable before any
        // timeline/badge host is published.
        updateAccessibilityElements(
            showsAnalysisTimeline: false,
            showsDownloadProgress: false,
            showsBadge: false
        )
    }

    func configure(
        episode: Episode,
        index: Int,
        analysisViewModel: AnalysisUIViewModel,
        downloadManager: DownloadManager,
        isQueued: Bool,
        onToggle: @escaping (Bool) -> Void,
        onDownload: @escaping () -> Void,
        onQueueAdd: @escaping () -> Void,
        onPlay: (() -> Void)? = nil
    ) {
        self.onToggle = onToggle
        self.onDownload = onDownload
        self.onQueueAdd = onQueueAdd
        self.onPlay = onPlay
        self.rowIndex = index

        titleLabel.text = episode.title
        dateLabel.text = EpisodeListFormatting.localizedDate(from: episode.pubDate)

        setCleaningSwitch(isOn: analysisViewModel.store.isEpisodeCleaningEnabled(episode.id))
        cleaningSwitch.accessibilityIdentifier = "episodeCleaningToggle_\(index)"
        cleaningSwitch.accessibilityLabel = "Episode cleaning"
        cleaningSwitch.accessibilityValue = cleaningSwitch.isOn ? "on" : "off"

        downloadButton.accessibilityIdentifier = "downloadButton_\(index)"
        applyQueueDisplay(isQueued: isQueued, index: index)
        applyAnalysisDisplay(analysisViewModel: analysisViewModel, episodeID: episode.id)
        applyDownloadDisplay(
            downloadManager: downloadManager,
            episodeID: episode.id,
            index: index
        )

        cellAccessibilityValue = EpisodeListFormatting.iso8601String(from: episode.pubDate)

        // Play region owns activation when Library wires `onPlay`. Keep the cell
        // identifier for `app.cells["episodeCell_*"]` queries on the Feed path;
        // on the Library path, move `episodeCell_*` onto `textStack` so XCTest
        // taps a hittable play target without collapsing accessories into the cell.
        isAccessibilityElement = false
        accessibilityTraits = .none
        accessoryStack.accessibilityElementsHidden = false
        accessoryStack.isUserInteractionEnabled = true
        queueAddButton.isAccessibilityElement = true
        downloadButton.isAccessibilityElement = true
        cleaningSwitch.isAccessibilityElement = true

        if onPlay != nil {
            accessibilityIdentifier = nil
            accessibilityLabel = nil
            textStack.accessibilityIdentifier = "episodeCell_\(index)"
            textStack.isAccessibilityElement = true
            textStack.accessibilityTraits = .button
            textStack.accessibilityLabel = episode.title
            textStack.accessibilityHint = "Plays this episode."
            textStack.accessibilityValue = cellAccessibilityValue
            textStack.onActivate = { [weak self] in self?.onPlay?() }
        } else {
            accessibilityIdentifier = "episodeCell_\(index)"
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
            symbolName = "trash.circle"
            isEnabled = true
        }

        downloadButton.setImage(UIImage(systemName: symbolName), for: .normal)
        downloadButton.tintColor = state == .failed ? .systemRed : .tintColor
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
            showsAnalysisTimeline: !progressAccessibilityHost.isHidden,
            showsDownloadProgress: showsProgress,
            showsBadge: !badgeLabel.isHidden
        )

        setNeedsLayout()
        layoutIfNeeded()
        // Avoid layoutChanged here — callers post once after all visible rows
        // update. Extra posts during the analyzing window race XCTest idle.
    }

    func applyAnalysisDisplay(analysisViewModel: AnalysisUIViewModel, episodeID: String) {
        let showsTimeline = analysisViewModel.episodeRowShowsTimeline(episodeID: episodeID)
        let showsBadge = analysisViewModel.episodeRowShowsOnBadge(episodeID: episodeID)

        badgeLabel.isHidden = !showsBadge
        badgeLabel.isAccessibilityElement = showsBadge
        badgeLabel.accessibilityIdentifier = showsBadge ? "cleaningBadge_episodeOn" : nil
        badgeLabel.accessibilityLabel = "Episode cleaning on"

        progressAccessibilityHost.isHidden = !showsTimeline
        progressAccessibilityHost.isAccessibilityElement = showsTimeline
        // Keep the identifier stable while visible so XCTest descendant queries
        // (cell-scoped and app-global) can resolve `analysisTimeline` on the
        // main-actor-published analyzing state before completion.
        progressAccessibilityHost.accessibilityIdentifier = showsTimeline ? "analysisTimeline" : nil
        if showsTimeline {
            progressAccessibilityHost.accessibilityLabel = "Analysis timeline"
            progressAccessibilityHost.accessibilityHint =
                "Shows which parts of the episode are scanned, in progress, or waiting."
            if let colors = analysisViewModel.episodeRowTimelineColors(episodeID: episodeID) {
                timelineBar.apply(colors: colors)
                progressAccessibilityHost.accessibilityValue =
                    analysisViewModel.episodeRowTimelineAccessibilityValue(episodeID: episodeID)
            } else {
                progressAccessibilityHost.accessibilityValue = nil
            }
        } else {
            progressAccessibilityHost.accessibilityLabel = nil
            progressAccessibilityHost.accessibilityHint = nil
            progressAccessibilityHost.accessibilityValue = nil
        }

        // Explicit AX children so UITableViewCell exposes timeline alongside the
        // accessory controls (grouped cell AX can otherwise omit nested hosts).
        updateAccessibilityElements(
            showsAnalysisTimeline: showsTimeline,
            showsDownloadProgress: !downloadProgressAccessibilityHost.isHidden,
            showsBadge: showsBadge
        )

        setNeedsLayout()
        layoutIfNeeded()
    }

    private func updateAccessibilityElements(
        showsAnalysisTimeline: Bool,
        showsDownloadProgress: Bool,
        showsBadge: Bool
    ) {
        // Always keep accessories queryable/tappable. Library play uses `textStack`
        // as the dedicated activatable region (not a collapsed whole-cell AX element).
        isAccessibilityElement = false
        accessoryStack.accessibilityElementsHidden = false
        queueAddButton.isAccessibilityElement = true
        downloadButton.isAccessibilityElement = true
        cleaningSwitch.isAccessibilityElement = true

        var axChildren: [UIView] = []
        if onPlay != nil {
            textStack.isAccessibilityElement = true
            textStack.accessibilityTraits = .button
            axChildren.append(textStack)
        } else {
            textStack.isAccessibilityElement = false
        }
        axChildren.append(contentsOf: [queueAddButton, downloadButton, cleaningSwitch])
        if showsDownloadProgress {
            axChildren.append(downloadProgressAccessibilityHost)
        }
        if showsAnalysisTimeline {
            axChildren.append(progressAccessibilityHost)
        }
        if showsBadge {
            axChildren.append(badgeLabel)
        }
        // Publish AX children on the *cell* (not contentView). After Slice 22 moved
        // accessories into contentView, assigning only timeline/badge to
        // `contentView.accessibilityElements` left `analysisTimeline` /
        // `cleaningBadge_episodeOn` invisible to XCTest descendant queries even
        // when the hosts were on-screen (see AnalysisProgressUITests recording).
        accessibilityElements = axChildren
        contentView.accessibilityElements = nil
    }

    private func setCleaningSwitch(isOn: Bool) {
        cleaningSwitch.removeTarget(self, action: #selector(switchChanged), for: .valueChanged)
        cleaningSwitch.setOn(isOn, animated: false)
        cleaningSwitch.addTarget(self, action: #selector(switchChanged), for: .valueChanged)
        cleaningSwitch.accessibilityValue = isOn ? "on" : "off"
    }

    /// Keeps the episode switch on while fixture analysis progress is published,
    /// without re-entering `switchChanged` (avoids double-prime / toggle races).
    func forceCleaningSwitchOnForAnalysis() {
        setCleaningSwitch(isOn: true)
    }

    @objc private func switchChanged() {
        cleaningSwitch.accessibilityValue = cleaningSwitch.isOn ? "on" : "off"
        onToggle?(cleaningSwitch.isOn)
    }

    @objc private func downloadTapped() {
        onDownload?()
    }

    @objc private func queueAddTapped() {
        onQueueAdd?()
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
        // Prefer accessories so download / queue / cleaning never lose to play.
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
