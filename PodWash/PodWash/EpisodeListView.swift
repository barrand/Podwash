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

    var body: some View {
        // Observe generation so representable refreshes when analysis UI changes.
        let _ = analysisViewModel.contentGeneration
        return EpisodeTableViewRepresentable(feed: feed, analysisViewModel: analysisViewModel)
    }
}

private struct EpisodeTableViewRepresentable: UIViewControllerRepresentable {
    let feed: PodcastFeed
    var analysisViewModel: AnalysisUIViewModel

    func makeUIViewController(context: Context) -> EpisodeTableViewController {
        EpisodeTableViewController(feed: feed, analysisViewModel: analysisViewModel)
    }

    func updateUIViewController(_ controller: EpisodeTableViewController, context: Context) {
        controller.update(feed: feed, analysisViewModel: analysisViewModel)
    }
}

private final class EpisodeTableViewController: UITableViewController {
    private var feed: PodcastFeed
    private var analysisViewModel: AnalysisUIViewModel

    init(feed: PodcastFeed, analysisViewModel: AnalysisUIViewModel) {
        self.feed = feed
        self.analysisViewModel = analysisViewModel
        super.init(style: .plain)
        analysisViewModel.onAnalyzingEpisodeIDChanged = { [weak self] in
            guard let self else { return }
            self.refreshAnalysisDisplayOnVisibleRows()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(EpisodeTableViewCell.self, forCellReuseIdentifier: EpisodeTableViewCell.reuseID)
        applyListAccessibility()
    }

    func update(feed: PodcastFeed, analysisViewModel: AnalysisUIViewModel) {
        let feedChanged = self.feed != feed
        self.feed = feed
        self.analysisViewModel = analysisViewModel
        analysisViewModel.onAnalyzingEpisodeIDChanged = { [weak self] in
            guard let self else { return }
            self.refreshAnalysisDisplayOnVisibleRows()
        }
        applyListAccessibility()
        if feedChanged {
            tableView.reloadData()
        } else {
            refreshAnalysisDisplayOnVisibleRows()
        }
        tableView.layoutIfNeeded()
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
            onToggle: episodeToggleHandler(for: indexPath)
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
    private let textStack = UIStackView()
    private let cleaningSwitch = UISwitch()
    private var onToggle: ((Bool) -> Void)?
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
        badgeLabel.accessibilityIdentifier = "cleaningBadge_episodeOn"
        badgeLabel.accessibilityLabel = "Episode cleaning on"
        badgeLabel.isAccessibilityElement = true

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
            progressStack.centerYAnchor.constraint(equalTo: progressAccessibilityHost.centerYAnchor),
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

        contentView.addSubview(textStack)
        textStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            textStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            textStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -72),
            badgeLabel.heightAnchor.constraint(equalToConstant: 22),
        ])

        cleaningSwitch.addTarget(self, action: #selector(switchChanged), for: .valueChanged)
        accessoryView = cleaningSwitch
    }

    func configure(
        episode: Episode,
        index: Int,
        analysisViewModel: AnalysisUIViewModel,
        onToggle: @escaping (Bool) -> Void
    ) {
        self.onToggle = onToggle

        titleLabel.text = episode.title
        dateLabel.text = EpisodeListFormatting.localizedDate(from: episode.pubDate)

        setCleaningSwitch(isOn: analysisViewModel.store.isEpisodeCleaningEnabled(episode.id))
        cleaningSwitch.accessibilityIdentifier = "episodeCleaningToggle_\(index)"
        cleaningSwitch.accessibilityLabel = "Episode cleaning"
        cleaningSwitch.accessibilityValue = cleaningSwitch.isOn ? "on" : "off"

        applyAnalysisDisplay(analysisViewModel: analysisViewModel, episodeID: episode.id)

        accessibilityIdentifier = "episodeCell_\(index)"
        accessibilityLabel = episode.title
        cellAccessibilityValue = EpisodeListFormatting.iso8601String(from: episode.pubDate)

        titleLabel.isAccessibilityElement = false
        dateLabel.isAccessibilityElement = false
    }

    func applyAnalysisDisplay(analysisViewModel: AnalysisUIViewModel, episodeID: String) {
        let showsProgress = analysisViewModel.episodeRowShowsProgress(episodeID: episodeID)
        let showsBadge = analysisViewModel.episodeRowShowsOnBadge(episodeID: episodeID)

        badgeLabel.isHidden = !showsBadge
        badgeLabel.isAccessibilityElement = showsBadge

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
        // accessory switch (grouped cell AX can otherwise omit nested hosts).
        var axChildren: [UIView] = []
        if showsProgress {
            axChildren.append(progressAccessibilityHost)
        }
        if showsBadge {
            axChildren.append(badgeLabel)
        }
        contentView.accessibilityElements = axChildren.isEmpty ? nil : axChildren

        setNeedsLayout()
        layoutIfNeeded()
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }

    private func setCleaningSwitch(isOn: Bool) {
        cleaningSwitch.removeTarget(self, action: #selector(switchChanged), for: .valueChanged)
        cleaningSwitch.setOn(isOn, animated: false)
        cleaningSwitch.addTarget(self, action: #selector(switchChanged), for: .valueChanged)
    }

    @objc private func switchChanged() {
        onToggle?(cleaningSwitch.isOn)
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
