#if os(iOS)
import Foundation
import Petrel
import Testing
@testable import Catbird

// MARK: - Feed Row Test Posts

/// Fixture posts for native feed row tests, built like `FeedSnapshotUpdateTests.makePost`.
/// Extend `cachedPost` with more defaulted parameters rather than adding new builders.
@MainActor
enum FeedRowTestPosts {
  static func cachedPost(
    text: String = "Feed fixture", likeCount: Int = 0, displayName: String = "Fixture"
  ) throws -> CachedFeedViewPost {
    let record = AppBskyFeedPost(
      text: text, entities: nil, facets: nil, reply: nil, embed: nil,
      langs: nil, labels: nil, tags: nil, createdAt: ATProtocolDate(date: Date(timeIntervalSince1970: 0)))
    let author = AppBskyActorDefs.ProfileViewBasic(
      did: try DID(didString: "did:plc:fixture"),
      handle: try Handle(handleString: "author.test"), displayName: displayName,
      pronouns: nil, avatar: nil, associated: nil, viewer: nil, labels: nil,
      createdAt: nil, verification: nil, status: nil, debug: nil)
    let post = AppBskyFeedDefs.PostView(
      uri: try ATProtocolURI(uriString: "at://did:plc:fixture/app.bsky.feed.post/one"),
      cid: CID.fromDAGCBOR(Data("cid-test".utf8)), author: author,
      record: .knownType(record), embed: nil, bookmarkCount: nil,
      replyCount: 0, repostCount: 0, likeCount: likeCount, quoteCount: nil,
      indexedAt: ATProtocolDate(date: Date(timeIntervalSince1970: 0)),
      viewer: nil, labels: nil, threadgate: nil, debug: nil)
    let decoded = AppBskyFeedDefs.FeedViewPost(
      post: post, reply: nil, reason: nil, feedContext: nil, reqId: nil)
    return try #require(CachedFeedViewPost(from: decoded, feedType: "timeline"))
  }

  /// Content signature of the fixed fixture post.
  static func signature() throws -> FeedPostContentSignature {
    FeedPostContentSignature(try cachedPost())
  }
}
#endif
