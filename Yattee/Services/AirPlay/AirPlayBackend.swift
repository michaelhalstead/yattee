//
//  AirPlayBackend.swift
//  Yattee
//
//  AVPlayer session used while an on-device YouTube video is AirPlayed. MPV cannot send video
//  over AirPlay, so PlayerService pauses MPV and routes controls here (see PlayerService+AirPlay).
//

import Foundation
import AVFoundation
import SwiftUI

@MainActor
final class AirPlayBackend: PlayerBackend {
    /// Never installed as `PlayerService.currentBackend`; `.mpv` only because the enum has no other case.
    let backendType: PlayerBackendType = .mpv
    weak var delegate: PlayerBackendDelegate?
    /// Called when the session cannot continue (load failure, or the route takes no video).
    var onFailure: ((String) -> Void)?

    var rate: Float = 1 {
        didSet {
            player.defaultRate = rate
            if player.rate != 0 { player.rate = rate }
        }
    }

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }

    var currentTime: TimeInterval { player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0 }
    var isPlaying: Bool { player.rate != 0 }
    /// What is being AirPlayed, for logs ("HLS 1080p", "progressive fallback", ...).
    let summary: String

    /// Routes that played audio but never started external (video) playback, e.g. AirPlay speakers.
    static var audioOnlyRouteUIDs: Set<String> = []

    private let player = AVPlayer()
    let url: URL
    private let server: LocalHLSServer?
    private var observations: [NSKeyValueObservation] = []
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var didStart = false

    private init(url: URL, server: LocalHLSServer?, summary: String) {
        self.url = url
        self.server = server
        self.summary = summary
        player.allowsExternalPlayback = true
    }

    // MARK: - Session

    /// Builds the AirPlay presentation for an on-device video: HLS from the sidx of the best avc1 + mp4a
    /// streams, else a proxied progressive mp4, else YouTube's own HLS URL.
    static func make(streams: [Stream], preferredAudio: Stream?) async throws -> AirPlayBackend {
        if let pair = pickStreams(from: streams, preferredAudio: preferredAudio) {
            do {
                let resources = try await hlsResources(video: pair.video, audio: pair.audio)
                let server = try await LocalHLSServer.start(resources: resources)
                return AirPlayBackend(
                    url: server.url(for: "master.m3u8"),
                    server: server,
                    summary: "HLS \(pair.video.qualityLabel) \(pair.video.videoCodec ?? "")"
                )
            } catch {
                LoggingService.shared.warning("AirPlay HLS generation failed, falling back: \(error.localizedDescription)", category: .player)
            }
        } else {
            LoggingService.shared.warning("AirPlay: no avc1/mp4a adaptive pair, falling back", category: .player)
        }

        if let muxed = streams.filter({ $0.isMuxed && $0.format.lowercased() == "mp4" })
            .max(by: { ($0.resolution?.height ?? 0) < ($1.resolution?.height ?? 0) }) {
            let server = try await LocalHLSServer.start(resources: ["video.mp4": .proxy(muxed.url, headers: muxed.httpHeaders ?? [:])])
            return AirPlayBackend(url: server.url(for: "video.mp4"), server: server, summary: "progressive \(muxed.qualityLabel)")
        }
        if let hls = streams.first(where: { $0.format == "hls" }) {
            return AirPlayBackend(url: hls.url, server: nil, summary: "YouTube HLS")
        }
        throw BackendError.loadFailed("no AirPlay-compatible stream")
    }

    /// Best avc1 video-only stream (≤1080p preferred) and the mp4a audio stream matching the current track.
    static func pickStreams(from streams: [Stream], preferredAudio: Stream?) -> (video: Stream, audio: Stream)? {
        let videos = streams.filter {
            $0.isVideoOnly && $0.resolution != nil && $0.format == "mp4" && ($0.videoCodec ?? "").hasPrefix("avc1")
        }
        let height = { (s: Stream) in s.resolution?.height ?? 0 }
        let video = videos.filter { height($0) <= 1080 }.max { (height($0), $0.bitrate ?? 0) < (height($1), $1.bitrate ?? 0) }
            ?? videos.min { height($0) < height($1) }

        let audios = streams.filter { $0.isAudioOnly && $0.format == "mp4" && ($0.audioCodec ?? "").hasPrefix("mp4a") }
        let sameTrack = audios.filter { $0.audioLanguage == preferredAudio?.audioLanguage && $0.audioTrackName == preferredAudio?.audioTrackName }
        let candidates = !sameTrack.isEmpty ? sameTrack : (audios.contains(where: \.isOriginalAudio) ? audios.filter(\.isOriginalAudio) : audios)
        let audio = candidates.max { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }

        guard let video, let audio else { return nil }
        return (video, audio)
    }

    private static func hlsResources(video: Stream, audio: Stream) async throws -> [String: LocalHLSServer.Resource] {
        async let videoTrack = track(for: video, uri: "video.mp4")
        async let audioTrack = track(for: audio, uri: "audio.mp4")
        let (v, a) = try await (videoTrack, audioTrack)
        let master = SidxHLS.masterPlaylist(
            video: v, videoPlaylistURI: "video.m3u8", videoCodec: video.videoCodec ?? "avc1",
            width: video.resolution?.width ?? 0, height: video.resolution?.height ?? 0, fps: video.fps,
            audio: a, audioPlaylistURI: "audio.m3u8", audioCodec: audio.audioCodec ?? "mp4a.40.2"
        )
        let m3u8 = "application/vnd.apple.mpegurl"
        return [
            "master.m3u8": .text(master, contentType: m3u8),
            "video.m3u8": .text(SidxHLS.mediaPlaylist(v), contentType: m3u8),
            "audio.m3u8": .text(SidxHLS.mediaPlaylist(a), contentType: m3u8),
            "video.mp4": .proxy(video.url, headers: video.httpHeaders ?? [:]),
            "audio.mp4": .proxy(audio.url, headers: audio.httpHeaders ?? [:]),
        ]
    }

    /// Reads the file head to locate init + sidx (YouTube puts them first), then parses the sidx.
    private static func track(for stream: Stream, uri: String) async throws -> SidxHLS.Track {
        let prefix = try await fetch(stream, range: 0..<65_536)
        let layout = try SidxHLS.layout(ofPrefix: prefix)
        let sidx = layout.sidxRange.upperBound <= UInt64(prefix.count)
            ? prefix.subdata(in: Int(layout.sidxRange.lowerBound)..<Int(layout.sidxRange.upperBound))
            : try await fetch(stream, range: layout.sidxRange)
        let segments = try SidxHLS.parseSidx(sidx, boxOffset: layout.sidxRange.lowerBound)
        return SidxHLS.Track(uri: uri, initRange: layout.initRange, segments: segments)
    }

    private static func fetch(_ stream: Stream, range: Range<UInt64>) async throws -> Data {
        var request = URLRequest(url: stream.url)
        (stream.httpHeaders ?? [:]).forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 206 || status == 200 else {
            throw BackendError.loadFailed("range request returned \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
    }

    // MARK: - Playback

    /// Loads the presentation and starts at `time`; playback begins once the item is ready.
    func start(at time: TimeInterval, playing: Bool) {
        let item = AVPlayerItem(url: url)
        observations = [
            item.observe(\.status) { [weak self] item, _ in
                let status = item.status
                let message = item.error?.localizedDescription ?? "unknown error"
                Task { @MainActor [weak self] in self?.itemStatusChanged(status, error: message, startAt: time, playing: playing) }
            },
            player.observe(\.timeControlStatus) { [weak self] player, _ in
                let status = player.timeControlStatus
                Task { @MainActor [weak self] in self?.timeControlStatusChanged(status) }
            },
        ]
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.didStart else { return }
                self.delegate?.backend(self, didUpdateTime: time.seconds)
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.delegate?.backendDidFinishPlaying(self)
            }
        }
        player.replaceCurrentItem(with: item)
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, error: String, startAt time: TimeInterval, playing: Bool) {
        switch status {
        case .readyToPlay where !didStart:
            didStart = true
            if let duration = player.currentItem?.duration.seconds, duration.isFinite {
                delegate?.backend(self, didUpdateDuration: duration)
            }
            Task {
                await seek(to: time, showLoading: false)
                if playing { play() } else { delegate?.backend(self, didChangeState: .paused) }
                LoggingService.shared.info("AirPlay started (\(summary)) at \(Int(time))s", category: .player)
                // An AirPlay speaker accepts the audio but never starts external playback.
                try? await Task.sleep(for: .seconds(8))
                if !player.isExternalPlaybackActive, player.currentItem != nil {
                    if let uid = AVAudioSession.sharedInstance().currentRoute.outputs.first(where: { $0.portType == .airPlay })?.uid {
                        Self.audioOnlyRouteUIDs.insert(uid)
                    }
                    onFailure?("route did not start external video playback")
                }
            }
        case .failed:
            onFailure?("AVPlayer item failed: \(error)")
        default:
            break
        }
    }

    private func timeControlStatusChanged(_ status: AVPlayer.TimeControlStatus) {
        guard didStart, player.currentItem != nil else { return }
        switch status {
        case .playing: delegate?.backend(self, didChangeState: .playing)
        case .paused: delegate?.backend(self, didChangeState: .paused)
        case .waitingToPlayAtSpecifiedRate: delegate?.backend(self, didChangeState: .buffering)
        @unknown default: break
        }
    }

    // MARK: - PlayerBackend

    func load(stream: Stream, audioStream: Stream?, autoplay: Bool, useEDL: Bool) async throws {
        throw BackendError.loadFailed("AirPlay sessions are created per video by PlayerService")
    }

    func play() {
        player.playImmediately(atRate: rate)
    }

    func pause() {
        player.pause()
    }

    func stop() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        observations = []
        onFailure = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        server?.stop()
    }

    func seek(to time: TimeInterval, showLoading: Bool) async {
        let tolerance = CMTime(value: 1, timescale: 2)
        await player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
        delegate?.backend(self, didUpdateTime: currentTime)
    }

    func prepareForInitialSeek() {}
}
