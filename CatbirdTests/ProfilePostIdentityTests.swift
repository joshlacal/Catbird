import Foundation
import Petrel
import Testing

@testable import Catbird

/// Profile post tabs render the view model's boxed rows directly (Oct 12 ProfileFeedEntryTests,
/// adapted to Oct 11's EquatableBox rows), so a row id must appear once per tab across pages,
/// stay in API order, and keep a repost apart from its original.
@Suite("Profile post identity")
struct ProfilePostIdentityTests {
  @Test("A repost keeps an identity apart from the original post and survives de-duplication")
  func repostIdentityIsDistinct() throws {
    let original = try Self.makeFeedViewPost(rkey: "shared")
    let repost = try Self.makeFeedViewPost(rkey: "shared", repostedBy: "did:plc:reposter")

    #expect(PostListEntry.feedPost(EquatableBox(original)).id != PostListEntry.feedPost(EquatableBox(repost)).id)

    let rows = ProfileViewModel.appendingUnique([original, repost].map { EquatableBox($0) }, to: [])
    #expect(rows.map(\.value) == [original, repost])
  }

  @Test("A page keeps API order and drops repeats within itself")
  func pageDropsRepeats() throws {
    let first = try Self.makeFeedViewPost(rkey: "first")
    let second = try Self.makeFeedViewPost(rkey: "second")

    let rows = ProfileViewModel.appendingUnique([first, second, first].map { EquatableBox($0) }, to: [])

    #expect(rows.map(\.value.id) == [first.id, second.id])
  }

  @Test("Appending a page drops rows an earlier page already returned and keeps the earlier rows")
  func appendingDropsOverlap() throws {
    let first = try Self.makeFeedViewPost(rkey: "first")
    let second = try Self.makeFeedViewPost(rkey: "second")
    let third = try Self.makeFeedViewPost(rkey: "third")
    let existing = ProfileViewModel.appendingUnique([first, second].map { EquatableBox($0) }, to: [])

    let combined = ProfileViewModel.appendingUnique([second, third].map { EquatableBox($0) }, to: existing)

    #expect(combined.map(\.value.id) == [first.id, second.id, third.id])
    #expect(Array(combined.prefix(2)) == existing)
  }

  // MARK: - Fixtures

  static func makeFeedViewPost(
    rkey: String,
    repostedBy reposterDID: String? = nil
  ) throws -> AppBskyFeedDefs.FeedViewPost {
    let record = AppBskyFeedPost(
      text: "Post \(rkey)",
      entities: nil,
      facets: nil,
      reply: nil,
      embed: nil,
      langs: nil,
      labels: nil,
      tags: nil,
      createdAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_749_000_000))
    )
    let post = AppBskyFeedDefs.PostView(
      uri: try ATProtocolURI(uriString: "at://did:plc:author/app.bsky.feed.post/\(rkey)"),
      cid: CID.fromDAGCBOR(Data("post-\(rkey)".utf8)),
      author: try makeProfile(did: "did:plc:author"),
      record: .knownType(record),
      embed: nil,
      bookmarkCount: nil,
      replyCount: 0,
      repostCount: 0,
      likeCount: 0,
      quoteCount: nil,
      indexedAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_749_000_100)),
      viewer: nil,
      labels: nil,
      threadgate: nil,
      debug: nil
    )
    let reason: AppBskyFeedDefs.FeedViewPostReasonUnion? = try reposterDID.map { did in
      .appBskyFeedDefsReasonRepost(
        AppBskyFeedDefs.ReasonRepost(
          by: try makeProfile(did: did),
          uri: nil,
          cid: nil,
          indexedAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_750_000_000))
        )
      )
    }
    return AppBskyFeedDefs.FeedViewPost(post: post, reply: nil, reason: reason, feedContext: nil, reqId: nil)
  }

  static func makeProfile(did: String) throws -> AppBskyActorDefs.ProfileViewBasic {
    AppBskyActorDefs.ProfileViewBasic(
      did: try DID(didString: did),
      handle: try Handle(handleString: "user.bsky.social"),
      displayName: "User",
      pronouns: nil,
      avatar: nil,
      associated: nil,
      viewer: nil,
      labels: nil,
      createdAt: nil,
      verification: nil,
      status: nil,
      debug: nil
    )
  }
}
