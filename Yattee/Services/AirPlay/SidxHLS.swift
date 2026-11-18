//
//  SidxHLS.swift
//  Yattee
//
//  Pure helpers that turn a fragmented MP4's `sidx` index into HLS playlists
//  (EXT-X-MAP + EXT-X-BYTERANGE), so AVPlayer/AirPlay can play YouTube's adaptive mp4 streams.
//

import Foundation

enum SidxHLS {
    // MARK: - Types

    enum ParseError: Error, LocalizedError, Equatable, Sendable {
        case truncated
        case boxNotFound(String)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .truncated: "MP4 data is truncated"
            case .boxNotFound(let type): "MP4 has no \(type) box"
            case .unsupported(let reason): "Unsupported sidx: \(reason)"
            }
        }
    }

    struct Segment: Equatable, Sendable {
        let offset: UInt64
        let size: UInt64
        let duration: Double
    }

    /// Byte layout of a fragmented MP4: init segment (ftyp+moov) and the sidx box.
    struct Layout: Equatable, Sendable {
        let initRange: Range<UInt64>
        let sidxRange: Range<UInt64>
    }

    /// One track (video or audio) ready to be written as a media playlist.
    struct Track: Sendable {
        let uri: String
        let initRange: Range<UInt64>
        let segments: [Segment]

        var duration: Double { segments.reduce(0) { $0 + $1.duration } }
        var peakBitrate: Int { segments.map { Int(Double($0.size * 8) / max($0.duration, 0.001)) }.max() ?? 0 }
        var averageBitrate: Int { Int(Double(segments.reduce(0) { $0 + $1.size } * 8) / max(duration, 0.001)) }
    }

    // MARK: - MP4 boxes

    /// Walks top-level boxes from offset 0 and returns where the init segment ends and the sidx box is.
    /// `prefix` must start at byte 0 of the file; the sidx box itself may extend past it.
    static func layout(ofPrefix prefix: Data) throws -> Layout {
        let bytes = [UInt8](prefix)
        var offset: UInt64 = 0
        var moovEnd: UInt64?
        while offset + 8 <= UInt64(bytes.count) {
            let at = Int(offset)
            var size = UInt64(readUInt32(bytes, at))
            let type = String(decoding: bytes[(at + 4)..<(at + 8)], as: UTF8.self)
            if size == 1 {
                guard at + 16 <= bytes.count else { throw ParseError.truncated }
                size = readUInt64(bytes, at + 8)
            }
            guard size >= 8 else { throw ParseError.unsupported("box \(type) has size \(size)") }
            if type == "moov" { moovEnd = offset + size }
            if type == "sidx" {
                guard let moovEnd else { throw ParseError.boxNotFound("moov") }
                return Layout(initRange: 0..<moovEnd, sidxRange: offset..<(offset + size))
            }
            if type == "moof" || type == "mdat" { break }
            offset += size
        }
        throw ParseError.boxNotFound("sidx")
    }

    /// Parses a complete sidx box (v0 or v1). `boxOffset` is the box's position in the file.
    static func parseSidx(_ data: Data, boxOffset: UInt64) throws -> [Segment] {
        let b = [UInt8](data)
        guard b.count >= 12, String(decoding: b[4..<8], as: UTF8.self) == "sidx" else {
            throw ParseError.boxNotFound("sidx")
        }
        let boxSize = UInt64(readUInt32(b, 0))
        guard boxSize >= 12, UInt64(b.count) >= boxSize else { throw ParseError.truncated }
        let version = b[8]
        var p = 12 + 4 // full box header + reference_ID
        guard b.count >= p + 4 else { throw ParseError.truncated }
        let timescale = Double(readUInt32(b, p)); p += 4
        guard timescale > 0 else { throw ParseError.unsupported("timescale 0") }
        let firstOffset: UInt64
        if version == 0 {
            guard b.count >= p + 8 else { throw ParseError.truncated }
            firstOffset = UInt64(readUInt32(b, p + 4)); p += 8
        } else {
            guard b.count >= p + 16 else { throw ParseError.truncated }
            firstOffset = readUInt64(b, p + 8); p += 16
        }
        guard b.count >= p + 4 else { throw ParseError.truncated }
        let count = Int(UInt16(b[p + 2]) << 8 | UInt16(b[p + 3])); p += 4
        guard b.count >= p + count * 12 else { throw ParseError.truncated }

        var segments: [Segment] = []
        segments.reserveCapacity(count)
        var segmentOffset = boxOffset + boxSize + firstOffset
        for _ in 0..<count {
            let ref = readUInt32(b, p)
            guard ref & 0x8000_0000 == 0 else { throw ParseError.unsupported("hierarchical sidx") }
            let size = UInt64(ref & 0x7FFF_FFFF)
            segments.append(Segment(offset: segmentOffset, size: size, duration: Double(readUInt32(b, p + 4)) / timescale))
            segmentOffset += size
            p += 12
        }
        guard !segments.isEmpty else { throw ParseError.unsupported("no references") }
        return segments
    }

    // MARK: - Playlists

    static func mediaPlaylist(_ track: Track) -> String {
        let target = Int((track.segments.map(\.duration).max() ?? 1).rounded(.up))
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(target)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MAP:URI=\"\(track.uri)\",BYTERANGE=\"\(track.initRange.count)@\(track.initRange.lowerBound)\"",
        ]
        for segment in track.segments {
            lines.append("#EXTINF:\(String(format: "%.5f", segment.duration)),")
            lines.append("#EXT-X-BYTERANGE:\(segment.size)@\(segment.offset)")
            lines.append(track.uri)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    // swiftlint:disable:next function_parameter_count
    static func masterPlaylist(
        video: Track, videoPlaylistURI: String, videoCodec: String, width: Int, height: Int, fps: Int?,
        audio: Track, audioPlaylistURI: String, audioCodec: String
    ) -> String {
        var inf = "#EXT-X-STREAM-INF:BANDWIDTH=\(video.peakBitrate + audio.peakBitrate)"
        inf += ",AVERAGE-BANDWIDTH=\(video.averageBitrate + audio.averageBitrate)"
        inf += ",RESOLUTION=\(width)x\(height)"
        if let fps, fps > 0 { inf += ",FRAME-RATE=\(String(format: "%.3f", Double(fps)))" }
        inf += ",CODECS=\"\(videoCodec),\(audioCodec)\",AUDIO=\"audio\""
        return [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"Audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"\(audioPlaylistURI)\"",
            inf,
            videoPlaylistURI,
        ].joined(separator: "\n") + "\n"
    }

    // MARK: - Bytes

    private static func readUInt32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    private static func readUInt64(_ b: [UInt8], _ i: Int) -> UInt64 {
        UInt64(readUInt32(b, i)) << 32 | UInt64(readUInt32(b, i + 4))
    }
}
