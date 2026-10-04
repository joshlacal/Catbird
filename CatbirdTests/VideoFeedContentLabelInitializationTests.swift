import Foundation
import Petrel
import SwiftUI
import Testing
@testable import Catbird

@MainActor
@Suite("Video content label initialization")
struct VideoFeedContentLabelInitializationTests {
  @Test("Record self-labels gate media before preferences load", arguments: [
    ("porn", ContentVisibility.hide),
    ("SEXUAL", ContentVisibility.hide),
    ("graphic-media", ContentVisibility.warn),
    ("NuDiTy", ContentVisibility.warn),
    ("bot-account", ContentVisibility.show)
  ])
  func selfLabelsApplyImmediately(value: String, expected: ContentVisibility) {
    #expect(ContentLabelManager<EmptyView>.getInitialContentVisibility(
      labels: nil, selfLabelValues: [value]
    ) == expected)
  }

  @Test("Server and self labels preserve the most restrictive initial policy")
  func mixedLabels() throws {
    let warning = ComAtprotoLabelDefs.Label(
      src: try DID(didString: "did:plc:labeltest"),
      uri: try URI(uriString: "at://example.test/app.bsky.feed.post/test"),
      val: "graphic",
      cts: ATProtocolDate(date: Date(timeIntervalSince1970: 0))
    )
    #expect(ContentLabelManager<EmptyView>.getInitialContentVisibility(
      labels: [warning], selfLabelValues: ["porn"]
    ) == .hide)
    #expect(ContentLabelManager<EmptyView>.getInitialContentVisibility(
      labels: [warning], selfLabelValues: ["bot-account"]
    ) == .warn)
    #expect(ContentLabelManager<EmptyView>.getInitialContentVisibility(labels: [warning]) == .warn)
    #expect(ContentLabelManager<EmptyView>.getInitialContentVisibility(labels: nil) == .show)
  }
  @Test("Same-URI refreshed moderation gates an earlier revealed selection", arguments: [
    ("porn", ContentVisibility.hide),
    ("graphic-media", ContentVisibility.warn)
  ])
  func refreshedSelectedVideo(value: String, expected: ContentVisibility) throws {
    let uri = try ATProtocolURI(uriString: "at://did:plc:labeltest/app.bsky.feed.post/selected")
    let base = PublicPostTestFixtures.makePostView(uri: uri, authorDID: try DID(didString: "did:plc:labeltest"))
    let video = AppBskyEmbedVideo.View(cid: base.cid, playlist: URI(uriString: "https://video.example.test/selected.m3u8"))
    let seed = AppBskyFeedDefs.PostView(
      uri: base.uri, cid: base.cid, author: base.author, record: base.record,
      embed: .appBskyEmbedVideoView(video), indexedAt: base.indexedAt
    )
    let refreshed = AppBskyFeedDefs.PostView(
      uri: base.uri, cid: base.cid, author: base.author, record: base.record,
      embed: .appBskyEmbedVideoView(video), indexedAt: base.indexedAt,
      labels: [.init(src: base.author.did, uri: URI(uriString: uri.uriString()), val: value, cts: base.indexedAt)]
    )
    let original = try #require(VideoFeedItem(post: seed))
    let selected = try #require(VideoFeedItem.initialItems(startingAt: seed, feedPosts: [.init(post: refreshed)]).first)
    #expect(selected.id == original.id)
    #expect(selected.revealIdentity != original.revealIdentity)
    #expect(ContentLabelManager<EmptyView>.getInitialContentVisibility(
      labels: original.post.labels, selfLabelValues: original.selfLabelValues
    ) == .show)
    #expect(ContentLabelManager<EmptyView>.getInitialContentVisibility(
      labels: selected.post.labels, selfLabelValues: selected.selfLabelValues
    ) == expected)
  }

}
