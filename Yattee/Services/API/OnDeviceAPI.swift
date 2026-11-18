//
//  OnDeviceAPI.swift
//  Yattee
//
//  YouTube backend that runs YouTube.js on the device (see OnDeviceJSRuntime). No server needed.
//  Search, playback, channels and playlists; everything else throws APIError.notSupported.
//

import Foundation

actor OnDeviceAPI: InstanceAPI {
    static let shared = OnDeviceAPI()

    /// Placeholder URL for the on-device instance, which has no server.
    static let instanceURL = URL(string: "ondevice://local")!

    // MARK: - Supported

    func search(query: String, instance: Instance, page: Int, filters: SearchFilters) async throws -> SearchResult {
        let response = try JSONDecoder().decode(SearchResponse.self, from: try await searchJSON(query: query, page: page))
        let videos = response.videos.map { $0.toVideo() }
        return SearchResult(
            videos: videos,
            channels: [],
            playlists: [],
            orderedItems: videos.map { .video($0) },
            nextPage: response.hasMore ? page + 1 : nil
        )
    }

    func video(id: String, instance: Instance) async throws -> Video {
        try await videoWithStreams(id: id).video
    }

    func videoWithStreams(id: String) async throws -> (video: Video, streams: [Stream]) {
        let details = try JSONDecoder().decode(VideoDetails.self, from: try await videoJSON(id: id))
        var streams: [Stream] = []
        if let hls = details.hls.flatMap(URL.init(string:)) {
            streams.append(Stream(url: hls, format: "hls", isLive: details.isLive, mimeType: "application/x-mpegURL"))
        }
        for stream in details.streams {
            guard let url = URL(string: stream.url) else { continue }
            let isAudio = stream.kind == "audio"
            let codecs = stream.mimeType?.components(separatedBy: "codecs=\"").last?.dropLast().components(separatedBy: ", ")
            let container = stream.mimeType?.components(separatedBy: ";").first?.components(separatedBy: "/").last ?? "mp4"
            let track = stream.audioTrack
            streams.append(Stream(
                url: url,
                resolution: isAudio ? nil : stream.width.flatMap { w in stream.height.map { StreamResolution(width: w, height: $0) } },
                format: container,
                videoCodec: isAudio ? nil : codecs?.first,
                audioCodec: isAudio ? codecs?.first : (stream.kind == "muxed" ? codecs?.dropFirst().first : nil),
                bitrate: stream.bitrate,
                fileSize: stream.contentLength,
                isAudioOnly: isAudio,
                mimeType: stream.mimeType,
                audioLanguage: track?.id,
                audioTrackName: track?.displayName,
                isOriginalAudio: track?.displayName?.localizedCaseInsensitiveContains("original") ?? false,
                fps: isAudio ? nil : stream.fps
            ))
        }
        guard !streams.isEmpty else { throw APIError.noStreams }
        return (details.toVideo(), streams)
    }

    func channel(id: String, instance: Instance) async throws -> Channel {
        try JSONDecoder().decode(ChannelDetails.self, from: try await runtime("channel", ["id": id])).toChannel()
    }

    func channelVideos(id: String, instance: Instance, continuation: String?) async throws -> ChannelVideosPage {
        try await videosPage("channelVideos", id: id, continuation: continuation)
    }

    func channelShorts(id: String, instance: Instance, continuation: String?) async throws -> ChannelVideosPage {
        try await videosPage("channelShorts", id: id, continuation: continuation)
    }

    func channelStreams(id: String, instance: Instance, continuation: String?) async throws -> ChannelVideosPage {
        try await videosPage("channelStreams", id: id, continuation: continuation)
    }

    func channelPlaylists(id: String, instance: Instance, continuation: String?) async throws -> ChannelPlaylistsPage {
        let page = try JSONDecoder().decode(
            PlaylistsResponse.self,
            from: try await runtime("channelPlaylists", ["id": id, "token": continuation ?? ""])
        )
        let playlists = page.playlists.map {
            Playlist(id: .global($0.id), title: $0.title, videoCount: $0.videoCount, thumbnailURL: $0.thumbnail.flatMap(URL.init(string:)))
        }
        return ChannelPlaylistsPage(playlists: playlists, continuation: page.continuation)
    }

    func playlist(id: String, instance: Instance) async throws -> Playlist {
        let details = try JSONDecoder().decode(PlaylistDetails.self, from: try await runtime("playlist", ["id": id]))
        return Playlist(
            id: .global(details.id),
            title: details.title,
            description: details.description,
            author: Author(id: details.authorId, name: details.author),
            videoCount: details.videoCount,
            thumbnailURL: details.thumbnail.flatMap(URL.init(string:)),
            videos: details.videos.map { $0.toVideo() }
        )
    }

    private func videosPage(_ function: String, id: String, continuation: String?) async throws -> ChannelVideosPage {
        let page = try JSONDecoder().decode(
            VideosPageResponse.self,
            from: try await runtime(function, ["id": id, "token": continuation ?? ""])
        )
        return ChannelVideosPage(videos: page.videos.map { $0.toVideo() }, continuation: page.continuation)
    }

    // MARK: - Not supported yet

    func trending(instance: Instance) async throws -> [Video] { throw APIError.notSupported }
    func comments(videoID: String, instance: Instance, continuation: String?) async throws -> CommentsPage { throw APIError.notSupported }

    // MARK: - Runtime

    private func searchJSON(query: String, page: Int) async throws -> Data {
        #if canImport(WebKit)
        try await OnDeviceJSRuntime.shared.search(query: query, page: page)
        #else
        throw APIError.notSupported
        #endif
    }

    private func videoJSON(id: String) async throws -> Data {
        #if canImport(WebKit)
        try await OnDeviceJSRuntime.shared.video(id: id)
        #else
        throw APIError.notSupported
        #endif
    }

    /// Calls `YT.<function>` with the given arguments as named JS parameters.
    private func runtime(_ function: String, _ arguments: [String: any Sendable]) async throws -> Data {
        #if canImport(WebKit)
        try await OnDeviceJSRuntime.shared.invoke(function, arguments)
        #else
        throw APIError.notSupported
        #endif
    }
}

// MARK: - JSON from ondevice-js/index.js

private struct JSThumbnail: Decodable {
    let url: String
    let width: Int?
    let height: Int?

    func toThumbnail() -> Thumbnail? {
        guard let url = URL(string: url) else { return nil }
        let quality: Thumbnail.Quality = switch width ?? 0 {
        case 1280...: .maxres
        case 640...: .standard
        case 480...: .high
        case 320...: .medium
        default: .default
        }
        return Thumbnail(url: url, quality: quality, width: width, height: height)
    }
}

private struct SearchResponse: Decodable {
    let videos: [SearchVideo]
    let hasMore: Bool
}

private struct VideosPageResponse: Decodable {
    let videos: [SearchVideo]
    let continuation: String?
}

private struct PlaylistsResponse: Decodable {
    struct Item: Decodable {
        let id: String
        let title: String
        let videoCount: Int
        let thumbnail: String?
    }

    let playlists: [Item]
    let continuation: String?
}

private struct PlaylistDetails: Decodable {
    let id: String
    let title: String
    let description: String?
    let authorId: String
    let author: String
    let videoCount: Int
    let thumbnail: String?
    let videos: [SearchVideo]
}

private struct ChannelDetails: Decodable {
    let id: String
    let name: String
    let description: String?
    let subscriberCount: Int?
    let videoCount: Int?
    let avatar: String?
    let banner: String?

    func toChannel() -> Channel {
        Channel(
            id: .global(id),
            name: name,
            description: description,
            subscriberCount: subscriberCount,
            videoCount: videoCount,
            thumbnailURL: avatar.flatMap(URL.init(string:)),
            bannerURL: banner.flatMap(URL.init(string:))
        )
    }
}

private struct SearchVideo: Decodable {
    let id: String
    let title: String
    let authorId: String
    let author: String
    let duration: Double
    let viewCount: Int?
    let publishedText: String?
    let thumbnails: [JSThumbnail]
    let isLive: Bool

    func toVideo() -> Video {
        Video(
            id: .global(id),
            title: title,
            description: nil,
            author: Author(id: authorId, name: author),
            duration: duration,
            publishedAt: nil,
            publishedText: publishedText,
            viewCount: viewCount,
            likeCount: nil,
            thumbnails: thumbnails.compactMap { $0.toThumbnail() },
            isLive: isLive,
            isUpcoming: false,
            scheduledStartTime: nil
        )
    }
}

private struct VideoDetails: Decodable {
    struct JSStream: Decodable {
        struct AudioTrack: Decodable {
            let id: String?
            let displayName: String?
        }

        let url: String
        let kind: String
        let contentLength: Int64?
        let audioTrack: AudioTrack?
        let width: Int?
        let height: Int?
        let mimeType: String?
        let bitrate: Int?
        let fps: Int?
    }

    let id: String
    let title: String
    let description: String?
    let authorId: String
    let author: String
    let duration: Double
    let viewCount: Int?
    let thumbnails: [JSThumbnail]
    let isLive: Bool
    let hls: String?
    let streams: [JSStream]

    func toVideo() -> Video {
        Video(
            id: .global(id),
            title: title,
            description: description,
            author: Author(id: authorId, name: author),
            duration: duration,
            publishedAt: nil,
            publishedText: nil,
            viewCount: viewCount,
            likeCount: nil,
            thumbnails: thumbnails.compactMap { $0.toThumbnail() },
            isLive: isLive,
            isUpcoming: false,
            scheduledStartTime: nil
        )
    }
}
