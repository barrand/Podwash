//
//  RSSParser.swift
//  PodWash
//
//  Slice 06 — RSS fetch + XML parse (ADR-004).
//

import Foundation

struct RSSParser: Sendable {
    let fetcher: any FeedFetching

    init(fetcher: any FeedFetching = URLSessionFeedFetcher()) {
        self.fetcher = fetcher
    }

    init(session: URLSession) {
        self.fetcher = URLSessionFeedFetcher(session: session)
    }

    func parse(data: Data) throws -> PodcastFeed {
        let delegate = RSSXMLParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false

        guard parser.parse() else {
            throw delegate.resolvedError ?? .malformedFeed
        }

        return try delegate.buildFeed()
    }

    func parse(url: URL) async throws -> PodcastFeed {
        let data: Data
        do {
            data = try await fetcher.data(from: url)
        } catch let error as RSSParserError {
            throw error
        } catch {
            throw RSSParserError.networkFailure
        }
        return try parse(data: data)
    }
}

// MARK: - XML delegate

private final class RSSXMLParserDelegate: NSObject, XMLParserDelegate {
    private struct EpisodeBuilder {
        var title: String?
        var pubDate: Date?
        var guid: String?
        var link: String?
        var artworkURL: URL?
        var description: String?
        var contentEncoded: String?
        var audioURL: URL?
    }

    private var channelTitle: String?
    private var channelDescription: String?
    private var channelArtworkURL: URL?

    private var episodeBuilders: [EpisodeBuilder] = []
    private var currentItem: EpisodeBuilder?
    private var inItem = false
    private var inChannelImage = false
    private var currentText = ""
    private(set) var resolvedError: RSSParserError?

    private static let rfc822Formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        resolvedError = .malformedFeed
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentText = ""

        if elementName == "item" {
            currentItem = EpisodeBuilder()
            inItem = true
            return
        }

        if elementName == "image", !inItem {
            inChannelImage = true
            return
        }

        if isImageElement(elementName), let href = attributeDict["href"], let url = URL(string: href) {
            if inItem {
                currentItem?.artworkURL = url
            } else {
                channelArtworkURL = url
            }
            return
        }

        if elementName == "enclosure", inItem, let urlString = attributeDict["url"] {
            currentItem?.audioURL = URL(string: urlString)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if elementName == "item" {
            if let builder = currentItem {
                episodeBuilders.append(builder)
            }
            currentItem = nil
            inItem = false
            currentText = ""
            return
        }

        if elementName == "image", !inItem {
            inChannelImage = false
            currentText = ""
            return
        }

        if inItem {
            applyItemField(elementName: elementName, text: text)
        } else {
            applyChannelField(elementName: elementName, text: text)
        }

        currentText = ""
    }

    func buildFeed() throws -> PodcastFeed {
        if let resolvedError {
            throw resolvedError
        }

        guard let channelTitle, !channelTitle.isEmpty else {
            throw RSSParserError.malformedFeed
        }

        let episodes = try episodeBuilders.map { try makeEpisode(from: $0) }

        return PodcastFeed(
            title: channelTitle,
            artworkURL: channelArtworkURL,
            description: channelDescription,
            episodes: episodes
        )
    }

    private func applyChannelField(elementName: String, text: String) {
        switch elementName {
        case "title":
            channelTitle = text
        case "description":
            channelDescription = text.isEmpty ? nil : text
        case "url" where inChannelImage:
            if let url = URL(string: text) {
                channelArtworkURL = url
            }
        default:
            break
        }
    }

    private func applyItemField(elementName: String, text: String) {
        switch elementName {
        case "title":
            currentItem?.title = text
        case "pubDate", "dc:date":
            currentItem?.pubDate = Self.parseRFC822Date(text)
        case "guid":
            currentItem?.guid = text
        case "link":
            currentItem?.link = text
        case "description":
            currentItem?.description = text.isEmpty ? nil : text
        case "content:encoded":
            currentItem?.contentEncoded = text.isEmpty ? nil : text
        default:
            break
        }
    }

    private func makeEpisode(from builder: EpisodeBuilder) throws -> Episode {
        guard let title = builder.title, !title.isEmpty else {
            throw RSSParserError.malformedFeed
        }
        guard let pubDate = builder.pubDate else {
            throw RSSParserError.malformedFeed
        }

        let showNotes = builder.contentEncoded ?? builder.description
        let id = episodeID(from: builder, title: title, pubDate: pubDate)

        return Episode(
            id: id,
            title: title,
            pubDate: pubDate,
            artworkURL: builder.artworkURL,
            showNotes: showNotes,
            audioURL: builder.audioURL
        )
    }

    private func episodeID(from builder: EpisodeBuilder, title: String, pubDate: Date) -> String {
        if let guid = builder.guid, !guid.isEmpty {
            return guid
        }
        if let link = builder.link, !link.isEmpty {
            return link
        }
        return "\(title)|\(Int(pubDate.timeIntervalSince1970))"
    }

    private func isImageElement(_ elementName: String) -> Bool {
        elementName == "itunes:image" || elementName.hasSuffix(":image")
    }

    private static func parseRFC822Date(_ text: String) -> Date? {
        rfc822Formatter.date(from: text)
    }
}
