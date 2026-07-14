import Foundation
import Petrel
import SwiftData
import Testing

@testable import Catbird

/// Regression tests for repost-header corruption: cached feed-entry identity must
/// distinguish organic and repost variants, and must remain scoped to its feed.
@Suite("CachedFeedViewPost identity")
struct CachedFeedViewPostIdentityTests {
  @Test("Repost gets a distinct id from the organic post")
  func repostIdDiffersFromOrganic() throws {
    let organic = try makeFeedViewPost(rkey: "abc123")
    let reposted = try makeFeedViewPost(
      rkey: "abc123",
      repostedBy: "did:plc:reposter",
      repostIndexedAt: Date(timeIntervalSince1970: 1_750_000_000)
    )

    let organicCached = try #require(CachedFeedViewPost(from: organic, feedType: "timeline"))
    let repostCached = try #require(CachedFeedViewPost(from: reposted, feedType: "timeline"))

    #expect(organicCached.id != repostCached.id)
    #expect(repostCached.id.hasPrefix(organicCached.id))
  }

  @Test("Repost id is stable across repeated construction")
  func repostIdIsStable() throws {
    let repostDate = Date(timeIntervalSince1970: 1_750_000_000)
    let first = try makeFeedViewPost(
      rkey: "abc123",
      repostedBy: "did:plc:reposter",
      repostIndexedAt: repostDate
    )
    let second = try makeFeedViewPost(
      rkey: "abc123",
      repostedBy: "did:plc:reposter",
      repostIndexedAt: repostDate
    )

    let firstCached = try #require(CachedFeedViewPost(from: first, feedType: "timeline"))
    let secondCached = try #require(CachedFeedViewPost(from: second, feedType: "timeline"))

    #expect(firstCached.id == secondCached.id)
  }

  @Test("Organic timeline row survives caching the repost variant under a profile feed")
  func repostVariantDoesNotClobberOrganicRow() throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)

    let organic = try makeFeedViewPost(rkey: "abc123")
    let timelineRow = try #require(CachedFeedViewPost(from: organic, feedType: "timeline"))
    context.insert(timelineRow)
    try context.save()

    let reposted = try makeFeedViewPost(
      rkey: "abc123",
      repostedBy: "did:plc:reposter",
      repostIndexedAt: Date(timeIntervalSince1970: 1_750_000_000)
    )
    let profileRow = try #require(
      CachedFeedViewPost(from: reposted, feedType: "profile-did:plc:reposter")
    )
    context.insert(profileRow)
    try context.save()

    let timelinePosts = try context.fetch(
      FetchDescriptor<CachedFeedViewPost>(
        predicate: #Predicate { $0.feedType == "timeline" }
      )
    )
    #expect(timelinePosts.count == 1)
    let timelineDecoded = try #require(try? timelinePosts.first?.feedViewPost)
    #expect(timelineDecoded.reason == nil, "timeline's organic post must not grow a repost header")
    #expect(timelinePosts.first?.isRepost == false)

    let profilePosts = try context.fetch(
      FetchDescriptor<CachedFeedViewPost>(
        predicate: #Predicate { $0.feedType == "profile-did:plc:reposter" }
      )
    )
    #expect(profilePosts.count == 1)
    let profileDecoded = try #require(try? profilePosts.first?.feedViewPost)
    if case .appBskyFeedDefsReasonRepost = profileDecoded.reason {
      // Expected.
    } else {
      Issue.record("profile feed's row must keep its repost reason")
    }
  }

  @Test("Identical organic post cached under two feeds keeps both rows")
  func samePostCoexistsAcrossFeeds() throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)

    let post = try makeFeedViewPost(rkey: "abc123")
    let timelineRow = try #require(CachedFeedViewPost(from: post, feedType: "timeline"))
    context.insert(timelineRow)
    try context.save()

    let profileRow = try #require(
      CachedFeedViewPost(from: post, feedType: "profile-did:plc:author")
    )
    context.insert(profileRow)
    try context.save()

    let all = try context.fetch(FetchDescriptor<CachedFeedViewPost>())
    #expect(all.count == 2)
    #expect(Set(all.map(\.feedType)) == ["timeline", "profile-did:plc:author"])
  }

  @Test("Thread cache upsert is scoped to feed identity")
  func threadCacheUpsertScopesIdentity() throws {
    let source = try sourceFile("Catbird/Features/Feed/Services/ThreadManager.swift")

    #expect(source.contains("let postFeedType = cachedPost.feedType"))
    #expect(source.contains("post.id == postId && post.feedType == postFeedType"))
  }

  @Test("Notification cache upsert is scoped to feed identity")
  func notificationCacheUpsertScopesIdentity() throws {
    let source = try sourceFile(
      "Catbird/Features/Notifications/Services/NotificationManager.swift"
    )

    #expect(source.contains("let postFeedType = cachedPost.feedType"))
    #expect(source.contains("post.id == postId && post.feedType == postFeedType"))
  }

  private func sourceFile(_ relativePath: String) throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(
      contentsOf: repositoryRoot.appendingPathComponent(relativePath),
      encoding: .utf8
    )
  }

  private func makeInMemoryContainer() throws -> ModelContainer {
    let schema = Schema([CachedFeedViewPost.self])
    let configuration = ModelConfiguration(
      "CachedFeedViewPostIdentityTests-InMemory",
      schema: schema,
      isStoredInMemoryOnly: true,
      cloudKitDatabase: .none
    )
    return try ModelContainer(for: schema, configurations: [configuration])
  }

  private func makeFeedViewPost(
    rkey: String,
    repostedBy reposterDID: String? = nil,
    repostIndexedAt: Date? = nil
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

    let reason: AppBskyFeedDefs.FeedViewPostReasonUnion?
    if let reposterDID {
      reason = .appBskyFeedDefsReasonRepost(
        AppBskyFeedDefs.ReasonRepost(
          by: try makeProfile(did: reposterDID),
          uri: nil,
          cid: nil,
          indexedAt: ATProtocolDate(
            date: repostIndexedAt ?? Date(timeIntervalSince1970: 1_750_000_000)
          )
        )
      )
    } else {
      reason = nil
    }

    return AppBskyFeedDefs.FeedViewPost(
      post: post,
      reply: nil,
      reason: reason,
      feedContext: nil,
      reqId: nil
    )
  }

  private func makeProfile(did: String) throws -> AppBskyActorDefs.ProfileViewBasic {
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
