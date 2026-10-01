import SwiftUI
import UIKit

/// Library's reusable scrolling container hosts the exact Queue row component.
struct EpisodeListView: UIViewControllerRepresentable {
    let feed: PodcastFeed
    let snapshots: [EpisodeRowSnapshot]
    let bindings: (String) -> EpisodeRowBindings
    let revision: Int

    func makeUIViewController(context: Context) -> EpisodeTableViewController {
        EpisodeTableViewController(feed: feed, snapshots: snapshots, bindings: bindings)
    }
    func updateUIViewController(_ controller: EpisodeTableViewController, context: Context) {
        controller.update(feed: feed, snapshots: snapshots, bindings: bindings)
    }
}

final class EpisodeTableViewController: UITableViewController {
    private var episodes: [Episode]
    private var snapshots: [String: EpisodeRowSnapshot]
    private var bindings: (String) -> EpisodeRowBindings
    private var renderedSnapshots: [String: EpisodeRowSnapshot] = [:]

    init(feed: PodcastFeed, snapshots: [EpisodeRowSnapshot],
         bindings: @escaping (String) -> EpisodeRowBindings) {
        self.episodes = Episode.newestFirst(feed.episodes)
        self.snapshots = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.episodeID, $0) })
        self.bindings = bindings
        super.init(style: .plain)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "sharedEpisode")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 120
        tableView.delaysContentTouches = false
        tableView.allowsSelection = false
        tableView.backgroundColor = .clear
        tableView.accessibilityIdentifier = "episodeList"
    }

    func update(feed: PodcastFeed, snapshots: [EpisodeRowSnapshot],
                bindings: @escaping (String) -> EpisodeRowBindings) {
        let nextEpisodes = Episode.newestFirst(feed.episodes)
        let identitiesChanged = episodes.map(\.id) != nextEpisodes.map(\.id)
        episodes = nextEpisodes
        self.snapshots = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.episodeID, $0) })
        self.bindings = bindings
        guard isViewLoaded else { return }
        if identitiesChanged {
            renderedSnapshots.removeAll()
            tableView.reloadData()
        } else {
            // Playback ticks also redraw the surrounding shell. Rehosting unchanged
            // rows on every tick can continuously invalidate UIKit/SwiftUI layout
            // and starve accessibility snapshots. Refresh only changed values.
            let changed = (tableView.indexPathsForVisibleRows ?? []).filter { indexPath in
                let episode = episodes[indexPath.row]
                return renderedSnapshots[episode.id] != self.snapshots[episode.id]
            }
            for indexPath in changed {
                if let cell = tableView.cellForRow(at: indexPath) {
                    configure(cell, episode: episodes[indexPath.row])
                }
            }
            if !changed.isEmpty {
                tableView.beginUpdates()
                tableView.endUpdates()
            }
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        episodes.count
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "sharedEpisode", for: indexPath)
        let episode = episodes[indexPath.row]
        configure(cell, episode: episode)
        return cell
    }

    private func configure(_ cell: UITableViewCell, episode: Episode) {
        guard let value = snapshots[episode.id] else { return }
        renderedSnapshots[episode.id] = value
        // Reused cells capture identity, never an index path or table callback.
        let actions = bindings(episode.id)
        cell.contentConfiguration = UIHostingConfiguration {
            SharedEpisodeRow(snapshot: value, bindings: actions)
        }.margins(.all, 12)
        cell.backgroundColor = .clear
        cell.selectionStyle = .none
    }
}
