import Foundation
import Petrel
import Testing
@testable import Catbird

@MainActor
@Suite("Trending video destination")
struct VideoFeedRoutingTests {
  @Test("Selected post has a distinct video destination and stable identity")
  func routeIdentity() throws {
    let selected = try post("selected")
    let refreshed = try post("selected", playlist: "replacement")
    let other = try post("other")
    let route = NavigationDestination.videoFeedStartingAt(selected)
    #expect(route != .post(selected.uri))
    #expect(route != .videoFeed)
    #expect(route != .videoFeedStartingAt(other))
    #expect(route == .videoFeedStartingAt(refreshed))
    #expect(Set([route, .videoFeedStartingAt(refreshed)]).count == 1)
    guard case .videoFeedStartingAt(let carriedPost) = route else {
      Issue.record("Selected post must travel with the video destination")
      return
    }
    #expect(carriedPost == selected)
  }

  @Test("Tapped video is available before any feed response")
  func seedWithoutNetwork() throws {
    let selected = try post("selected")
    let items = VideoFeedItem.initialItems(startingAt: selected, feedPosts: [])
    #expect(items.map(\.id) == [selected.uri.uriString()])
    #expect(items.first?.post == selected)
  }

  @Test("A reordered feed cannot replace the selected video or duplicate its URI")
  func reorderedFeed() throws {
    let selected = try post("selected")
    let other = try post("other")
    let refreshed = try post("selected", playlist: "replacement")
    let items = VideoFeedItem.initialItems(startingAt: selected, feedPosts: [
      .init(post: other), .init(post: refreshed), .init(post: other)
    ])
    #expect(items.map(\.id) == [selected.uri.uriString(), other.uri.uriString()])
    #expect(items.first?.post == refreshed)
  }

  @Test("Refreshed labels keep the selected URI but revoke the earlier reveal", arguments: ["porn", "graphic-media"])
  func refreshedModeration(value: String) throws {
    let selected = try post("selected")
    let seed = try #require(VideoFeedItem(post: selected))
    let refreshed = try post("selected", labels: [value])
    let items = VideoFeedItem.initialItems(startingAt: selected, feedPosts: [
      .init(post: try post("other")), .init(post: refreshed)
    ])
    let updated = try #require(items.first)
    #expect(updated.id == seed.id)
    #expect(updated != seed)
    #expect(updated.post == refreshed)
    #expect(updated.post.labels?.map(\.val) == [value])
    #expect(updated.revealIdentity != seed.revealIdentity)
    let reveals: Set<VideoFeedItem.RevealIdentity> = [seed.revealIdentity]
    #expect(!reveals.contains(updated.revealIdentity))
  }

  @Test("Overlapping later pages refresh self-labels without moving the selection")
  func refreshedSelfLabels() throws {
    let seed = try #require(VideoFeedItem(post: post("selected")))
    let refreshed = try post("selected", selfWarning: true)
    let items = VideoFeedItem.merging([seed], with: [.init(post: refreshed)])
    let updated = try #require(items.first)
    #expect(items.count == 1)
    #expect(updated.id == seed.id)
    #expect(updated.post == refreshed)
    #expect(updated.selfLabelValues == ["porn"])
    #expect(updated.revealIdentity != seed.revealIdentity)
  }

  @Test("Selected video survives removal from the generator's current page")
  func missingFromFeed() throws {
    let selected = try post("selected")
    let other = try post("other")
    let items = VideoFeedItem.initialItems(startingAt: selected, feedPosts: [.init(post: other)])
    #expect(items.map(\.id) == [selected.uri.uriString(), other.uri.uriString()])
  }

  @Test("Feed entry without a selection preserves server order and filters non-video posts")
  func headerEntry() throws {
    let first = try post("first")
    let second = try post("second")
    let text = PublicPostTestFixtures.makePostView(uri: first.uri, authorDID: first.author.did)
    let items = VideoFeedItem.initialItems(startingAt: nil, feedPosts: [
      .init(post: text), .init(post: first), .init(post: second), .init(post: first)
    ])
    #expect(items.map(\.id) == [first.uri.uriString(), second.uri.uriString()])
    #expect(VideoFeedItem(post: text) == nil)
  }

  @Test("Posts with their own video and a quote retain outer identity and moderation labels")
  func outerVideoAlongsideQuote() throws {
    let selected = try post("quoted", wrapsRecord: true, selfWarning: true)
    let item = try #require(VideoFeedItem(post: selected))
    #expect(item.id == selected.uri.uriString())
    #expect(item.post == selected)
    #expect(item.playlistURL.absoluteString == "https://video.example.test/shared.m3u8")
    guard case .knownType(let value) = item.post.record,
          let record = value as? AppBskyFeedPost,
          case .comAtprotoLabelDefsSelfLabels(let labels) = record.labels else {
      Issue.record("Seed must preserve the original moderation record")
      return
    }
    #expect(labels.values.map(\.val) == ["porn"])
  }

  @Test("Different posts sharing the same playlist remain separate pages")
  func streamURLIsNotIdentity() throws {
    let first = try post("first")
    let second = try post("second")
    let items = VideoFeedItem.initialItems(startingAt: first, feedPosts: [.init(post: second)])
    #expect(items.count == 2)
    #expect(items[0].playlistURL == items[1].playlistURL)
    #expect(items[0].id != items[1].id)
  }

  private func post(
    _ key: String,
    playlist: String = "shared",
    wrapsRecord: Bool = false,
    selfWarning: Bool = false,
    labels: [String] = []
  ) throws -> AppBskyFeedDefs.PostView {
    let uri = try ATProtocolURI(uriString: "at://did:plc:videofixture/app.bsky.feed.post/\(key)")
    let base = PublicPostTestFixtures.makePostView(uri: uri, authorDID: try DID(didString: "did:plc:videofixture"))
    let video = AppBskyEmbedVideo.View(
      cid: base.cid,
      playlist: URI(uriString: "https://video.example.test/\(playlist).m3u8")
    )
    let embed: AppBskyFeedDefs.PostViewEmbedUnion
    if wrapsRecord {
      embed = .appBskyEmbedRecordWithMediaView(.init(
        record: .init(record: .appBskyEmbedRecordViewNotFound(.init(uri: uri, notFound: true))),
        media: .appBskyEmbedVideoView(video)
      ))
    } else {
      embed = .appBskyEmbedVideoView(video)
    }
    let record = AppBskyFeedPost(
      text: "Selected video",
      labels: selfWarning ? .comAtprotoLabelDefsSelfLabels(.init(values: [.init(val: "porn")])) : nil,
      createdAt: base.indexedAt
    )
    return AppBskyFeedDefs.PostView(
      uri: base.uri, cid: base.cid, author: base.author, record: .knownType(record),
      embed: embed, indexedAt: base.indexedAt,
      labels: labels.map { .init(
        src: base.author.did, uri: URI(uriString: uri.uriString()),
        val: $0, cts: base.indexedAt
      ) }
    )
  }
}
