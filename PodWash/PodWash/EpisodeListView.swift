//
//  EpisodeListView.swift
//  PodWash
//
//  Slice 06 — Episode list UI (slice-06-ux.md).
//

import SwiftUI

struct EpisodeListView: View {
    let feed: PodcastFeed

    var body: some View {
        EpisodeTableViewRepresentable(feed: feed)
    }
}

private struct EpisodeTableViewRepresentable: UIViewControllerRepresentable {
    let feed: PodcastFeed

    func makeUIViewController(context: Context) -> EpisodeTableViewController {
        EpisodeTableViewController(feed: feed)
    }

    func updateUIViewController(_ controller: EpisodeTableViewController, context: Context) {
        controller.update(feed: feed)
    }
}

private final class EpisodeTableViewController: UITableViewController {
    private var feed: PodcastFeed

    init(feed: PodcastFeed) {
        self.feed = feed
        super.init(style: .plain)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "episode")
        applyListAccessibility()
    }

    func update(feed: PodcastFeed) {
        self.feed = feed
        applyListAccessibility()
        tableView.reloadData()
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
        let cell = tableView.dequeueReusableCell(withIdentifier: "episode", for: indexPath)
        let episode = feed.episodes[indexPath.row]

        var content = cell.defaultContentConfiguration()
        content.text = episode.title
        content.textProperties.numberOfLines = 2
        content.secondaryText = EpisodeListFormatting.localizedDate(from: episode.pubDate)
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        cell.selectionStyle = .none

        cell.accessibilityIdentifier = "episodeCell_\(indexPath.row)"
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = episode.title
        cell.accessibilityValue = EpisodeListFormatting.iso8601String(from: episode.pubDate)
        cell.contentView.accessibilityElementsHidden = true

        return cell
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
