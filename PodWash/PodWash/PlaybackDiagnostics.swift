//
//  PlaybackDiagnostics.swift
//  PodWash
//
//  On-device playback tracing — os.Logger + ring buffer for Settings.
//

import AVFoundation
import Foundation
import os

@MainActor
enum PlaybackDiagnostics {
    private static let logger = Logger(
        subsystem: "com.barrandfarm.PodWash",
        category: "Playback"
    )

    private static let maxEntries = 80
    private static var entries: [String] = []
    private static var revision = 0

    /// Bumped when a new line lands; Settings log view can observe this.
    private(set) static var contentRevision = 0

    static var recentLines: [String] {
        entries
    }

    static func info(_ message: String) {
        log(message, level: .info)
    }

    static func warning(_ message: String) {
        log(message, level: .default)
    }

    static func error(_ message: String) {
        log(message, level: .error)
    }

    static func logAudioURLResolution(
        episodeID: String,
        localURL: URL?,
        remoteURL: URL?,
        chosen: URL?
    ) {
        let localDesc = describeURL(localURL) ?? "nil"
        let remoteDesc = remoteURL?.absoluteString ?? "nil"
        let chosenDesc = describeURL(chosen) ?? "nil"
        let source: String
        if let chosen, let localURL, chosen.path == localURL.path {
            source = "local"
        } else if chosen != nil {
            source = "remote"
        } else {
            source = "unresolved"
        }
        info(
            "resolve episodeID=\(episodeID) source=\(source) "
                + "local=\(localDesc) remote=\(remoteDesc) chosen=\(chosenDesc)"
        )
    }

    static func logEngineCreated(url: URL, title: String) {
        info("engine create title=\(title) url=\(describeURL(url) ?? url.absoluteString)")
    }

    static func logPlayIntent(source: String, itemStatus: AVPlayerItem.Status, timeControl: String) {
        info("play source=\(source) itemStatus=\(Self.itemStatusLabel(itemStatus)) timeControl=\(timeControl)")
    }

    static func logItemStatus(_ status: AVPlayerItem.Status, url: URL?, error: Error?) {
        var message = "itemStatus=\(Self.itemStatusLabel(status))"
        if let url {
            message += " url=\(describeURL(url) ?? url.absoluteString)"
        }
        if let error {
            message += " error=\(error.localizedDescription)"
            self.error(message)
        } else {
            info(message)
        }
    }

    static func logTimeControlStatus(_ status: AVPlayer.TimeControlStatus, rate: Float) {
        info("timeControl=\(Self.timeControlLabel(status)) rate=\(rate)")
    }

    static func logDuration(seconds: TimeInterval, url: URL?) {
        var message = String(format: "duration=%.2fs", seconds)
        if let url {
            message += " url=\(describeURL(url) ?? url.lastPathComponent)"
        }
        if seconds <= 0 {
            warning(message)
        } else {
            info(message)
        }
    }

    static func logAudioSessionActivated(category: String, mode: String, error: Error?) {
        if let error {
            self.error("audioSession failed category=\(category) mode=\(mode) error=\(error.localizedDescription)")
        } else {
            info("audioSession active category=\(category) mode=\(mode)")
        }
    }

    static func logPreparePlaybackStart(episodeID: String, cleaning: Bool, localFile: Bool) {
        info("preparePlayback start episodeID=\(episodeID) cleaning=\(cleaning) localFile=\(localFile)")
    }

    static func logPreparePlaybackEnd(
        episodeID: String,
        intervals: [CensorInterval],
        union: [CensorInterval],
        error: Error?
    ) {
        if let error {
            self.error(
                "preparePlayback failed episodeID=\(episodeID) error=\(error.localizedDescription)"
            )
        } else {
            let profanity = intervals.filter { $0.source == .profanity }.count
            let unrelatedPlayback = intervals.filter { $0.source == .unrelatedContent }.count
            let unrelatedDetected = union.filter { $0.source == .unrelatedContent }.count
            info(
                "preparePlayback done episodeID=\(episodeID) intervals=\(intervals.count) "
                    + "profanity=\(profanity) unrelatedPlayback=\(unrelatedPlayback) "
                    + "unrelatedDetected=\(unrelatedDetected)"
            )
        }
    }

    static func logDownloadReady(episodeID: String, url: URL) {
        let size = fileByteCount(at: url)
        info("download ready episodeID=\(episodeID) path=\(url.lastPathComponent) bytes=\(size)")
    }

    static func logDownloadStateCleared(episodeID: String, reason: String) {
        warning("download state cleared episodeID=\(episodeID) reason=\(reason)")
    }

    static func logEpisodeTap(episodeID: String, title: String) {
        info("episode tap episodeID=\(episodeID) title=\(title)")
    }

    static func logMiniPlayerToggle(willPlay: Bool, enginePresent: Bool) {
        info("miniPlayer toggle willPlay=\(willPlay) enginePresent=\(enginePresent)")
    }

    static func timeControlLabel(_ status: AVPlayer.TimeControlStatus) -> String {
        switch status {
        case .paused: return "paused"
        case .playing: return "playing"
        case .waitingToPlayAtSpecifiedRate: return "waiting"
        @unknown default: return "other"
        }
    }

    static func itemStatusLabel(_ status: AVPlayerItem.Status) -> String {
        switch status {
        case .unknown: return "unknown"
        case .readyToPlay: return "readyToPlay"
        case .failed: return "failed"
        @unknown default: return "other"
        }
    }

    static func clear() {
        entries.removeAll()
        revision &+= 1
        contentRevision = revision
    }

    private static func log(_ message: String, level: OSLogType) {
        let stamped = "\(timestamp()) \(message)"
        entries.append(stamped)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        revision &+= 1
        contentRevision = revision
        logger.log(level: level, "\(stamped, privacy: .public)")
    }

    private static func timestamp() -> String {
        Self.timeFormatter.string(from: Date())
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static func describeURL(_ url: URL?) -> String? {
        guard let url else { return nil }
        if url.isFileURL {
            let bytes = fileByteCount(at: url)
            return "file://…/\(url.lastPathComponent) (\(bytes) bytes)"
        }
        return url.absoluteString
    }

    private static func fileByteCount(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}
