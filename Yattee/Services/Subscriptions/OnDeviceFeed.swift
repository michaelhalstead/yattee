//
//  OnDeviceFeed.swift
//  Yattee
//
//  Subscription feed without a server: each channel's public YouTube RSS feed,
//  falling back to the on-device source's first channel videos page.
//

import Foundation

enum OnDeviceFeed {
    private static let maxConcurrentRequests = 8

    /// Latest videos of all channels, newest first. Throws only when every channel failed.
    static func videos(channelIDs: [String], instance: Instance) async throws -> [Video] {
        var videos: [Video] = []
        var failures: [Error] = []
        await withTaskGroup(of: Result<[Video], Error>.self) { group in
            var pending = channelIDs[...]
            func addNext() {
                guard let channelID = pending.popFirst() else { return }
                group.addTask {
                    do { return .success(try await channelVideos(channelID: channelID, instance: instance)) } catch { return .failure(error) }
                }
            }
            for _ in 0..<maxConcurrentRequests { addNext() }
            for await result in group {
                switch result {
                case .success(let channelVideos): videos += channelVideos
                case .failure(let error): failures.append(error)
                }
                addNext()
            }
        }
        if videos.isEmpty, let error = failures.first, failures.count == channelIDs.count { throw error }
        // Fallback videos only carry relative dates ("2 days ago") and sort last.
        return videos.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
    }

    private static func channelVideos(channelID: String, instance: Instance) async throws -> [Video] {
        var components = URLComponents(string: "https://www.youtube.com/feeds/videos.xml")!
        components.queryItems = [URLQueryItem(name: "channel_id", value: channelID)]
        if let (data, response) = try? await URLSession.shared.data(from: components.url!),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let videos = parse(data) {
            return videos
        }
        LoggingService.shared.debug("RSS feed failed for \(channelID), using channel videos", category: .general)
        return try await OnDeviceAPI.shared.channelVideos(id: channelID, instance: instance, continuation: nil).videos
    }

    /// Parses a YouTube channel RSS (Atom) feed; nil when the data is not a valid feed.
    static func parse(_ data: Data) -> [Video]? {
        let delegate = RSSParserDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        return parser.parse() ? delegate.videos : nil
    }
}

// MARK: - XMLParser delegate

private final class RSSParserDelegate: NSObject, XMLParserDelegate {
    private(set) var videos: [Video] = []

    private var entry: [String: String]?
    private var text = ""
    private var inAuthor = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String] = [:]
    ) {
        text = ""
        switch elementName {
        case "entry": entry = [:]
        case "author": inAuthor = true
        case "media:thumbnail":
            entry?["thumbnail"] = attributes["url"]
            entry?["thumbnailWidth"] = attributes["width"]
            entry?["thumbnailHeight"] = attributes["height"]
        case "media:statistics": entry?["views"] = attributes["views"]
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard entry != nil else { return }
        switch elementName {
        case "yt:videoId", "yt:channelId", "published":
            entry?[elementName] = text
        case "title" where entry?["title"] == nil:
            entry?["title"] = text
        case "name" where inAuthor:
            entry?["author"] = text
        case "author":
            inAuthor = false
        case "entry":
            if let entry, let video = Self.video(from: entry) { videos.append(video) }
            entry = nil
        default: break
        }
    }

    private static func video(from entry: [String: String]) -> Video? {
        guard let id = entry["yt:videoId"], !id.isEmpty else { return nil }
        let thumbnail = entry["thumbnail"].flatMap(URL.init(string:)).map {
            Thumbnail(
                url: $0,
                quality: .high,
                width: entry["thumbnailWidth"].flatMap(Int.init),
                height: entry["thumbnailHeight"].flatMap(Int.init)
            )
        }
        return Video(
            id: .global(id),
            title: entry["title"] ?? "",
            description: nil,
            author: Author(id: entry["yt:channelId"] ?? "", name: entry["author"] ?? ""),
            duration: 0,
            publishedAt: entry["published"].flatMap { ISO8601DateFormatter().date(from: $0) },
            publishedText: nil,
            viewCount: entry["views"].flatMap(Int.init),
            likeCount: nil,
            thumbnails: thumbnail.map { [$0] } ?? [],
            isLive: false,
            isUpcoming: false,
            scheduledStartTime: nil
        )
    }
}
