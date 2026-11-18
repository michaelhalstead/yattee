//
//  AirPlayHLSTests.swift
//  YatteeTests
//
//  sidx parsing and HLS playlist generation for AirPlay of on-device YouTube streams.
//

import Testing
import Foundation
import AVFoundation
@testable import Yattee

@Suite("AirPlay sidx → HLS")
struct AirPlayHLSTests {
    // MARK: - Fixtures

    private func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    private func be64(_ v: UInt64) -> [UInt8] { be32(UInt32(v >> 32)) + be32(UInt32(v & 0xFFFF_FFFF)) }

    /// sidx with timescale 1000 and references of (size, duration ms).
    private func sidx(version: UInt8, firstOffset: UInt64 = 0, refs: [(UInt32, UInt32)]) -> [UInt8] {
        var body: [UInt8] = [version, 0, 0, 0] + be32(1) + be32(1000)
        body += version == 0 ? be32(0) + be32(UInt32(firstOffset)) : be64(0) + be64(firstOffset)
        body += [0, 0, UInt8(refs.count >> 8), UInt8(refs.count & 0xFF)]
        for (size, duration) in refs { body += be32(size) + be32(duration) + be32(0x9000_0000) }
        return be32(UInt32(body.count + 8)) + Array("sidx".utf8) + body
    }

    private func box(_ type: String, payload: Int) -> [UInt8] {
        be32(UInt32(payload + 8)) + Array(type.utf8) + [UInt8](repeating: 0, count: payload)
    }

    private let refs: [(UInt32, UInt32)] = [(1000, 5000), (2000, 5000), (1500, 2500)]

    // MARK: - sidx

    @Test("sidx v0 with 3 references gives offsets, sizes and durations")
    func parseSidxV0() throws {
        let data = Data(sidx(version: 0, refs: refs))
        #expect(data.count == 68)
        let segments = try SidxHLS.parseSidx(data, boxOffset: 742)
        #expect(segments == [
            SidxHLS.Segment(offset: 810, size: 1000, duration: 5),
            SidxHLS.Segment(offset: 1810, size: 2000, duration: 5),
            SidxHLS.Segment(offset: 3810, size: 1500, duration: 2.5),
        ])
    }

    @Test("sidx v1 honours 64-bit first_offset")
    func parseSidxV1() throws {
        let data = Data(sidx(version: 1, firstOffset: 10, refs: refs))
        let segments = try SidxHLS.parseSidx(data, boxOffset: 0)
        #expect(segments.first == SidxHLS.Segment(offset: UInt64(data.count) + 10, size: 1000, duration: 5))
        #expect(segments.count == 3)
    }

    @Test("truncated sidx throws")
    func truncatedSidx() {
        let data = Data(sidx(version: 0, refs: refs).dropLast(5))
        #expect(throws: SidxHLS.ParseError.self) { try SidxHLS.parseSidx(data, boxOffset: 0) }
    }

    @Test("layout finds init (ftyp+moov) and sidx from the file head")
    func layout() throws {
        let sidxBytes = sidx(version: 0, refs: refs)
        let head = box("ftyp", payload: 20) + box("moov", payload: 706) + sidxBytes + box("moof", payload: 8)
        let layout = try SidxHLS.layout(ofPrefix: Data(head))
        #expect(layout.initRange == 0..<742)
        #expect(layout.sidxRange == 742..<(742 + UInt64(sidxBytes.count)))
    }

    // MARK: - Playlists

    @Test("media playlist has VOD tags, EXT-X-MAP byte range and one byte range per segment")
    func mediaPlaylist() throws {
        let segments = try SidxHLS.parseSidx(Data(sidx(version: 0, refs: refs)), boxOffset: 742)
        let track = SidxHLS.Track(uri: "video.mp4", initRange: 0..<742, segments: segments)
        let lines = SidxHLS.mediaPlaylist(track).split(separator: "\n").map(String.init)
        #expect(lines.first == "#EXTM3U")
        #expect(lines.contains("#EXT-X-VERSION:7"))
        #expect(lines.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        #expect(lines.contains("#EXT-X-TARGETDURATION:5"))
        #expect(lines.contains("#EXT-X-MAP:URI=\"video.mp4\",BYTERANGE=\"742@0\""))
        #expect(lines.filter { $0.hasPrefix("#EXTINF:") } == ["#EXTINF:5.00000,", "#EXTINF:5.00000,", "#EXTINF:2.50000,"])
        #expect(lines.filter { $0.hasPrefix("#EXT-X-BYTERANGE:") } == [
            "#EXT-X-BYTERANGE:1000@810", "#EXT-X-BYTERANGE:2000@1810", "#EXT-X-BYTERANGE:1500@3810",
        ])
        #expect(lines.last == "#EXT-X-ENDLIST")
    }

    @Test("proxy caps open-ended and oversized ranges")
    func upstreamRange() {
        #expect(LocalHLSServer.upstreamRange("bytes=2250-153786") == "bytes=2250-153786")
        #expect(LocalHLSServer.upstreamRange("bytes=100-", limit: 1000) == "bytes=100-1099")
        #expect(LocalHLSServer.upstreamRange(nil, limit: 1000) == "bytes=0-999")
        #expect(LocalHLSServer.upstreamRange("bytes=0-5000", limit: 1000) == "bytes=0-999")
    }

    @Test("byte span parses every Range form MPV sends")
    func byteSpan() {
        #expect(LocalHLSServer.byteSpan(nil, length: 100) == 0...99)
        #expect(LocalHLSServer.byteSpan("bytes=0-", length: 100) == 0...99)
        #expect(LocalHLSServer.byteSpan("bytes=40-", length: 100) == 40...99)
        #expect(LocalHLSServer.byteSpan("bytes=10-19", length: 100) == 10...19)
        #expect(LocalHLSServer.byteSpan("bytes=90-500", length: 100) == 90...99)
        #expect(LocalHLSServer.byteSpan("bytes=-30", length: 100) == 70...99)
        #expect(LocalHLSServer.byteSpan("bytes=100-", length: 100) == nil)
        #expect(LocalHLSServer.byteSpan("bytes=20-10", length: 100) == nil)
        #expect(LocalHLSServer.byteSpan("garbage", length: 100) == nil)
    }

    @Test("master playlist declares stream info and audio group")
    func masterPlaylist() {
        let video = SidxHLS.Track(uri: "video.mp4", initRange: 0..<742, segments: [.init(offset: 810, size: 1_000_000, duration: 4)])
        let audio = SidxHLS.Track(uri: "audio.mp4", initRange: 0..<723, segments: [.init(offset: 800, size: 50_000, duration: 4)])
        let master = SidxHLS.masterPlaylist(
            video: video, videoPlaylistURI: "video.m3u8", videoCodec: "avc1.64002A", width: 1920, height: 1080, fps: 30,
            audio: audio, audioPlaylistURI: "audio.m3u8", audioCodec: "mp4a.40.2"
        )
        #expect(master.contains("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\""))
        #expect(master.contains("URI=\"audio.m3u8\""))
        #expect(master.contains("#EXT-X-STREAM-INF:BANDWIDTH=2100000,"))
        #expect(master.contains("RESOLUTION=1920x1080"))
        #expect(master.contains("CODECS=\"avc1.64002A,mp4a.40.2\""))
        #expect(master.contains("AUDIO=\"audio\""))
        #expect(master.hasSuffix("video.m3u8\n"))
    }
}

/// Live end-to-end check (network + YouTube): run with `TEST_RUNNER_AIRPLAY_E2E=1`.
/// `TEST_RUNNER_AIRPLAY_E2E_OUT=<file>` writes the master URL there and keeps the server up for
/// `TEST_RUNNER_AIRPLAY_E2E_HOLD` seconds so it can be probed from the Mac (curl, ffprobe).
@Suite("AirPlay HLS end-to-end", .enabled(if: ProcessInfo.processInfo.environment["AIRPLAY_E2E"] != nil))
@MainActor
struct AirPlayHLSEndToEndTests {
    @Test("aqz-KE-bpKQ: on-device streams → local HLS → AVPlayer ready at ≥1080p", .timeLimit(.minutes(3)))
    func endToEnd() async throws {
        let env = ProcessInfo.processInfo.environment
        let (_, streams) = try await OnDeviceAPI.shared.videoWithStreams(id: "aqz-KE-bpKQ")
        let pair = try #require(AirPlayBackend.pickStreams(from: streams, preferredAudio: nil))
        #expect(pair.video.resolution?.height == 1080)
        let backend = try await AirPlayBackend.make(streams: streams, preferredAudio: nil)
        defer { backend.stop() }
        #expect(backend.summary.hasPrefix("HLS"))
        let master = backend.url
        #expect(master.host() != "localhost" && master.host() != "127.0.0.1")

        let masterText = try await text(master)
        #expect(masterText.contains("#EXT-X-STREAM-INF:"))
        let videoPlaylist = try await text(master.deletingLastPathComponent().appendingPathComponent("video.m3u8"))
        let byteRange = try #require(videoPlaylist.split(separator: "\n").first { $0.hasPrefix("#EXT-X-BYTERANGE:") })
        let parts = byteRange.dropFirst("#EXT-X-BYTERANGE:".count).split(separator: "@").compactMap { Int($0) }
        var request = URLRequest(url: master.deletingLastPathComponent().appendingPathComponent("video.mp4"))
        request.setValue("bytes=\(parts[1])-\(parts[1] + parts[0] - 1)", forHTTPHeaderField: "Range")
        let (segment, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 206)
        #expect(segment.count == parts[0])
        #expect(["moof", "styp"].contains(String(decoding: segment[4..<8], as: UTF8.self)))

        let item = AVPlayerItem(url: master)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.play()
        var size = CGSize.zero
        for _ in 0..<120 where size.height < 1080 {
            try await Task.sleep(for: .milliseconds(250))
            if item.status == .failed { Issue.record("AVPlayerItem failed: \(String(describing: item.error))"); break }
            if item.status == .readyToPlay { size = item.presentationSize }
        }
        let mediaTypes = item.tracks.compactMap { $0.assetTrack?.mediaType }
        player.pause()
        #expect(item.status == .readyToPlay)
        #expect(mediaTypes.contains(.video) && mediaTypes.contains(.audio), "tracks \(mediaTypes)")
        #expect(size.height >= 1080, "presentation size \(size)")
        print("AIRPLAY_E2E master=\(master) presentationSize=\(size) tracks=\(mediaTypes) duration=\(item.duration.seconds)")

        if let out = env["AIRPLAY_E2E_OUT"] {
            try "\(master.absoluteString)\n".write(toFile: out, atomically: true, encoding: .utf8)
            try await Task.sleep(for: .seconds(Int(env["AIRPLAY_E2E_HOLD"] ?? "0") ?? 0))
        }
    }

    @Test("aqz-KE-bpKQ: loopback raw passthrough serves open-ended ranges as 206", .timeLimit(.minutes(3)))
    func rawPassthrough() async throws {
        let env = ProcessInfo.processInfo.environment
        let (_, streams) = try await OnDeviceAPI.shared.videoWithStreams(id: "aqz-KE-bpKQ")
        let best = try #require(streams.filter(\.isVideoOnly).max { ($0.resolution?.height ?? 0, $0.bitrate ?? 0) < ($1.resolution?.height ?? 0, $1.bitrate ?? 0) })
        let length = try #require(best.fileSize)
        let server = try await LocalHLSServer.loopback()
        let url = server.register(.raw(best.url, length: length, contentType: "video/mp4", headers: best.httpHeaders ?? [:]))
        #expect(url.host() == "127.0.0.1")
        let want: Int64 = 30 << 20
        for start: Int64 in [0, 50_000_000] {
            var request = URLRequest(url: url)
            request.setValue("bytes=\(start)-", forHTTPHeaderField: "Range")
            let began = Date()
            let (response, count) = try await ByteCounter.read(request, upTo: want)
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 206)
            #expect(http.value(forHTTPHeaderField: "Content-Range") == "bytes \(start)-\(length - 1)/\(length)")
            #expect(http.value(forHTTPHeaderField: "Content-Length") == "\(length - start)")
            #expect(count >= want)
            print("RAW_E2E \(best.qualityLabel) \(best.format) start=\(start) length=\(length) read=\(count) in \(Date().timeIntervalSince(began))s")
        }
        if let out = env["RAW_E2E_OUT"] {
            try "\(url.absoluteString) \(length)\n".write(toFile: out, atomically: true, encoding: .utf8)
            try await Task.sleep(for: .seconds(Int(env["AIRPLAY_E2E_HOLD"] ?? "0") ?? 0))
        }
    }

    private func text(_ url: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Reads a response until `limit` bytes arrived, then cancels (as MPV does when it seeks).
private final class ByteCounter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var count: Int64 = 0
    private let limit: Int64
    private var response: URLResponse?
    private var continuation: CheckedContinuation<(URLResponse?, Int64), Error>?

    private init(limit: Int64) { self.limit = limit }

    static func read(_ request: URLRequest, upTo limit: Int64) async throws -> (URLResponse?, Int64) {
        let counter = ByteCounter(limit: limit)
        let session = URLSession(configuration: .ephemeral, delegate: counter, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await withCheckedThrowingContinuation { continuation in
            counter.continuation = continuation
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        count += Int64(data.count)
        if count >= limit, let continuation {
            self.continuation = nil
            continuation.resume(returning: (response, count))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: (response, count)) }
    }
}
