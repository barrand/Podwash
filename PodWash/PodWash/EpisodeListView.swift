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

    var body: some View {
        // Observe generation so representable refreshes when analysis UI changes.
        let _ = analysisViewModel.contentGeneration
        return EpisodeTableViewRepresentable(
            feed: feed,
            analysisViewModel: analysisViewModel,
            downloadManager: downloadManager
        )
    }
}

private struct EpisodeTableViewRepresentable: UIViewControllerRepresentable {
    let feed: PodcastFeed
    var analysisViewModel: AnalysisUIViewModel
    var downloadManager: DownloadManager

    func makeUIViewController(context: Context) -> EpisodeTableViewController {
        EpisodeTableViewController(
            feed: feed,
            analysisViewModel: analysisViewModel,
            downloadManager: downloadManager
        )
    }

    func updateUIViewController(_ controller: EpisodeTableViewController, context: Context) {
        controller.update(
            feed: feed,
            analysisViewModel: analysisViewModel,
            downloadManager: downloadManager
        )
    }
}

private final class EpisodeTableViewController: UITableViewController {
    private var feed: PodcastFeed
    private var analysisViewModel: AnalysisUIViewModel
    private var downloadManager: DownloadManager

    init(
        feed: PodcastFeed,
        analysisViewModel: AnalysisUIViewModel,
        downloadManager: DownloadManager
    ) {
        self.feed = feed
        self.analysisViewModel = analysisViewModel
        self.downloadManager = downloadManager
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
        // Tall enough for title + date + analysis/download progress without
        // beginUpdates animations (those keep XCTest non-idle until after the
        // fixture analyzing window closes, dropping `analysisProgress`).
        tableView.rowHeight = 120
        tableView.estimatedRowHeight = 120
        applyListAccessibility()
    }

    func update(
        feed: PodcastFeed,
        analysisViewModel: AnalysisUIViewModel,
        downloadManager: DownloadManager
    ) {
        let feedChanged = self.feed != feed
        self.feed = feed
        self.analysisViewModel = analysisViewModel
        self.downloadManager = downloadManager
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
            // analysis generation clobbers the transient `analysisProgress` AX
            // surface before XCTest goes idle.
            refreshAnalysisDisplayOnVisibleRows()
        }
        tableView.layoutIfNeeded()
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

    private func downloadButtonHandler(for indexPath: IndexPath) -> () -> Void {
        { [weak self] in
            guard let self else { return }
            let episode = self.feed.episodes[indexPath.row]
            let state = self.downloadManager.state(for: episode.id)

            switch state {
            case .notDownloaded, .failed:
                guard let remoteURL = episode.audioURL else { return }
                // Fixture downloads complete synchronously on the main actor — run
                // inline so XCTest sees `downloaded` before post-tap idle settles.
                if FixtureDownload.isEnabled {
                    do {
                        _ = try self.downloadManager.completeFixtureDownloadForUITest(episodeID: episode.id)
                    } catch {
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
                    _ = try? await self.downloadManager.download(
                        episodeID: episode.id,
                        from: remoteURL
                    ) { _ in
                        Task { @MainActor [weak self] in
                            self?.refreshDownloadDisplayOnVisibleRows()
                        }
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
                // without blocking idleness, leaving `analysisProgress` visible.
                self.analysisViewModel.primeEpisodeCleaningToggle(episodeID: episodeID)
                self.refreshAnalysisDisplayOnVisibleRows()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.analysisViewModel.completePrimedEpisodeAnalysis(episodeID: episodeID)
                    self.refreshAnalysisDisplayOnVisibleRows()
                }
            } else {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.analysisViewModel.setEpisodeCleaning(episodeID: episodeID, enabled: enabled)
                }
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
        cell.configure(
            episode: episode,
            index: indexPath.row,
            analysisViewModel: analysisViewModel,
            downloadManager: downloadManager,
            onToggle: episodeToggleHandler(for: indexPath),
            onDownload: downloadButtonHandler(for: indexPath)
        )
        return cell
    }
}

private final class EpisodeTableViewCell: UITableViewCell {
    static let reuseID = "episode"

    private let titleLabel = UILabel()
    private let dateLabel = UILabel()
    private let badgeLabel = UILabel()
    private let progressView = UIActivityIndicatorView(style: .medium)
    private let progressLabel = UILabel()
    private let progressStack = UIStackView()
    private let progressAccessibilityHost = UIView()
    private let downloadProgressView = UIActivityIndicatorView(style: .medium)
    private let downloadProgressLabel = UILabel()
    private let downloadProgressStack = UIStackView()
    private let downloadProgressAccessibilityHost = UIView()
    private let textStack = UIStackView()
    private let downloadButton = UIButton(type: .system)
    private let cleaningSwitch = UISwitch()
    private let accessoryStack = UIStackView()
    private var onToggle: ((Bool) -> Void)?
    private var onDownload: (() -> Void)?
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

        progressLabel.font = .preferredFont(forTextStyle: .caption1)
        progressLabel.text = "Analyzing…"
        progressLabel.textColor = .secondaryLabel
        progressLabel.accessibilityLabel = "Analyzing episode"
        progressLabel.isAccessibilityElement = false

        progressView.hidesWhenStopped = false
        progressStack.axis = .horizontal
        progressStack.spacing = 8
        progressStack.alignment = .center
        progressStack.addArrangedSubview(progressView)
        progressStack.isAccessibilityElement = false
        progressView.isAccessibilityElement = false

        progressAccessibilityHost.isHidden = true
        progressAccessibilityHost.isAccessibilityElement = false
        progressAccessibilityHost.accessibilityLabel = "Analyzing episode"
        progressAccessibilityHost.isUserInteractionEnabled = false
        progressAccessibilityHost.addSubview(progressStack)
        progressAccessibilityHost.addSubview(progressLabel)
        progressStack.translatesAutoresizingMaskIntoConstraints = false
        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            progressStack.leadingAnchor.constraint(equalTo: progressAccessibilityHost.leadingAnchor),
            progressStack.topAnchor.constraint(equalTo: progressAccessibilityHost.topAnchor),
            progressStack.bottomAnchor.constraint(equalTo: progressAccessibilityHost.bottomAnchor),
            progressLabel.leadingAnchor.constraint(equalTo: progressStack.trailingAnchor, constant: 8),
            progressLabel.trailingAnchor.constraint(lessThanOrEqualTo: progressAccessibilityHost.trailingAnchor),
            progressLabel.centerYAnchor.constraint(equalTo: progressAccessibilityHost.centerYAnchor),
            progressAccessibilityHost.heightAnchor.constraint(greaterThanOrEqualToConstant: 22),
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

        contentView.addSubview(textStack)
        textStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            textStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            textStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -120),
            badgeLabel.heightAnchor.constraint(equalToConstant: 22),
        ])

        downloadButton.addTarget(self, action: #selector(downloadTapped), for: .touchUpInside)
        downloadButton.isAccessibilityElement = true
        downloadButton.accessibilityTraits = .button
        downloadButton.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(textStyle: .body),
            forImageIn: .normal
        )
        // Ensure a tappable target; zero-size accessory controls receive AX taps but no actions.
        downloadButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            downloadButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            downloadButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])

        accessoryStack.axis = .horizontal
        accessoryStack.spacing = 8
        accessoryStack.alignment = .center
        accessoryStack.addArrangedSubview(downloadButton)
        accessoryStack.addArrangedSubview(cleaningSwitch)
        accessoryStack.translatesAutoresizingMaskIntoConstraints = false
        // Size the accessory from Auto Layout so the switch keeps a real frame for
        // XCTest taps alongside the 44×44 download button.
        NSLayoutConstraint.activate([
            accessoryStack.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        let accessorySize = accessoryStack.systemLayoutSizeFitting(
            CGSize(width: UIView.layoutFittingExpandedSize.width, height: 44),
            withHorizontalFittingPriority: .fittingSizeLevel,
            verticalFittingPriority: .required
        )
        accessoryStack.frame = CGRect(origin: .zero, size: accessorySize)
        accessoryView = accessoryStack

        cleaningSwitch.addTarget(self, action: #selector(switchChanged), for: .valueChanged)
    }

    func configure(
        episode: Episode,
        index: Int,
        analysisViewModel: AnalysisUIViewModel,
        downloadManager: DownloadManager,
        onToggle: @escaping (Bool) -> Void,
        onDownload: @escaping () -> Void
    ) {
        self.onToggle = onToggle
        self.onDownload = onDownload
        self.rowIndex = index

        titleLabel.text = episode.title
        dateLabel.text = EpisodeListFormatting.localizedDate(from: episode.pubDate)

        setCleaningSwitch(isOn: analysisViewModel.store.isEpisodeCleaningEnabled(episode.id))
        cleaningSwitch.accessibilityIdentifier = "episodeCleaningToggle_\(index)"
        cleaningSwitch.accessibilityLabel = "Episode cleaning"
        cleaningSwitch.accessibilityValue = cleaningSwitch.isOn ? "on" : "off"

        downloadButton.accessibilityIdentifier = "downloadButton_\(index)"
        applyAnalysisDisplay(analysisViewModel: analysisViewModel, episodeID: episode.id)
        applyDownloadDisplay(
            downloadManager: downloadManager,
            episodeID: episode.id,
            index: index
        )

        accessibilityIdentifier = "episodeCell_\(index)"
        accessibilityLabel = episode.title
        cellAccessibilityValue = EpisodeListFormatting.iso8601String(from: episode.pubDate)

        titleLabel.isAccessibilityElement = false
        dateLabel.isAccessibilityElement = false
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
        case .notDownloaded, .failed:
            showsProgress = false
            value = "notDownloaded"
            label = "Download episode"
            hint = nil
            symbolName = "arrow.down.circle"
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
            showsAnalysisProgress: !progressAccessibilityHost.isHidden,
            showsDownloadProgress: showsProgress,
            showsBadge: !badgeLabel.isHidden
        )

        setNeedsLayout()
        layoutIfNeeded()
        // Avoid layoutChanged here — callers post once after all visible rows
        // update. Extra posts during the analyzing window race XCTest idle.
    }

    func applyAnalysisDisplay(analysisViewModel: AnalysisUIViewModel, episodeID: String) {
        let showsProgress = analysisViewModel.episodeRowShowsProgress(episodeID: episodeID)
        let showsBadge = analysisViewModel.episodeRowShowsOnBadge(episodeID: episodeID)

        badgeLabel.isHidden = !showsBadge
        badgeLabel.isAccessibilityElement = showsBadge
        badgeLabel.accessibilityIdentifier = showsBadge ? "cleaningBadge_episodeOn" : nil
        badgeLabel.accessibilityLabel = "Episode cleaning on"

        progressAccessibilityHost.isHidden = !showsProgress
        progressAccessibilityHost.isAccessibilityElement = showsProgress
        // Keep the identifier stable while visible so XCTest descendant queries
        // (cell-scoped and app-global) can resolve `analysisProgress` on the
        // main-actor-published analyzing state before completion.
        progressAccessibilityHost.accessibilityIdentifier = showsProgress ? "analysisProgress" : nil
        progressAccessibilityHost.accessibilityLabel = "Analyzing episode"
        progressLabel.isHidden = !showsProgress
        progressLabel.isAccessibilityElement = false
        progressLabel.accessibilityIdentifier = nil
        // Never animate the spinner during fixture UI tests: UIActivityIndicatorView
        // animation keeps the app non-idle, so XCTest's post-tap idle wait blocks
        // until analysis finishes and `analysisProgress` is already gone.
        if showsProgress && !FixtureAnalysis.isEnabled {
            progressView.startAnimating()
        } else {
            progressView.stopAnimating()
        }

        // Explicit AX children so UITableViewCell exposes progress alongside the
        // accessory controls (grouped cell AX can otherwise omit nested hosts).
        updateAccessibilityElements(
            showsAnalysisProgress: showsProgress,
            showsDownloadProgress: !downloadProgressAccessibilityHost.isHidden,
            showsBadge: showsBadge
        )

        setNeedsLayout()
        layoutIfNeeded()
    }

    private func updateAccessibilityElements(
        showsAnalysisProgress: Bool,
        showsDownloadProgress: Bool,
        showsBadge: Bool
    ) {
        // Keep progress/badge on contentView (same path as Slice 09 badges). Accessory
        // controls stay on accessoryView so UIKit exposes the switch/button normally.
        var axChildren: [UIView] = []
        if showsDownloadProgress {
            axChildren.append(downloadProgressAccessibilityHost)
        }
        if showsAnalysisProgress {
            axChildren.append(progressAccessibilityHost)
        }
        if showsBadge {
            axChildren.append(badgeLabel)
        }
        contentView.accessibilityElements = axChildren.isEmpty ? nil : axChildren
    }

    private func setCleaningSwitch(isOn: Bool) {
        cleaningSwitch.removeTarget(self, action: #selector(switchChanged), for: .valueChanged)
        cleaningSwitch.setOn(isOn, animated: false)
        cleaningSwitch.addTarget(self, action: #selector(switchChanged), for: .valueChanged)
    }

    @objc private func switchChanged() {
        onToggle?(cleaningSwitch.isOn)
    }

    @objc private func downloadTapped() {
        onDownload?()
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
