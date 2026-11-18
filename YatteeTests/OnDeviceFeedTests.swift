//
//  OnDeviceFeedTests.swift
//  YatteeTests
//
//  The on-device subscription feed reads YouTube's channel RSS feeds.
//

import Testing
import Foundation
@testable import Yattee

@Suite("OnDeviceFeed RSS parsing")
struct OnDeviceFeedTests {
    private let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns:media="http://search.yahoo.com/mrss/" xmlns="http://www.w3.org/2005/Atom">
     <title>Rick Astley</title>
     <author><name>Rick Astley</name></author>
     <entry>
      <id>yt:video:dQw4w9WgXcQ</id>
      <yt:videoId>dQw4w9WgXcQ</yt:videoId>
      <yt:channelId>UCuAXFkgsw1L7xaCfnd5JJOw</yt:channelId>
      <title>Never Gonna Give You Up</title>
      <author><name>Rick Astley</name></author>
      <published>2009-10-25T06:57:33+00:00</published>
      <media:group>
       <media:title>Never Gonna Give You Up</media:title>
       <media:thumbnail url="https://i1.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg" width="480" height="360"/>
       <media:community><media:statistics views="1600000000"/></media:community>
      </media:group>
     </entry>
     <entry>
      <yt:videoId>yPYZpwSpKmA</yt:videoId>
      <yt:channelId>UCuAXFkgsw1L7xaCfnd5JJOw</yt:channelId>
      <title>Together Forever &amp; Ever</title>
      <author><name>Rick Astley</name></author>
      <published>2024-01-02T03:04:05+00:00</published>
     </entry>
    </feed>
    """

    @Test("Parses ids, titles, dates, author, thumbnail and views")
    func parsesEntries() throws {
        let videos = try #require(OnDeviceFeed.parse(Data(xml.utf8)))
        #expect(videos.map(\.id.videoID) == ["dQw4w9WgXcQ", "yPYZpwSpKmA"])
        #expect(videos.map(\.title) == ["Never Gonna Give You Up", "Together Forever & Ever"])
        #expect(videos[0].publishedAt == Date(timeIntervalSince1970: 1_256_453_853))
        #expect(videos[1].publishedAt == Date(timeIntervalSince1970: 1_704_164_645))
        #expect(videos[0].author.id == "UCuAXFkgsw1L7xaCfnd5JJOw")
        #expect(videos[0].author.name == "Rick Astley")
        #expect(videos[0].viewCount == 1_600_000_000)
        #expect(videos[0].thumbnails.first?.url.absoluteString == "https://i1.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
        #expect(videos[1].viewCount == nil)
    }

    @Test("Rejects data that is not XML")
    func rejectsGarbage() {
        #expect(OnDeviceFeed.parse(Data("<html><body>oops".utf8)) == nil)
    }
}
