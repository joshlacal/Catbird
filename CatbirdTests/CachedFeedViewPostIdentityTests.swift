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

  @Test("Identical organic post has a distinct stable identity in each feed")
  func samePostIdentityIncludesFeedScope() throws {
    let post = try makeFeedViewPost(rkey: "abc123")
    let timeline = try #require(CachedFeedViewPost(from: post, feedType: "timeline"))
    let profile = try #require(
      CachedFeedViewPost(from: post, feedType: "profile-did:plc:author")
    )

    #expect(timeline.id != profile.id)
    #expect(timeline.id == CachedFeedViewPost.computeId(for: post, feedType: "timeline"))
    #expect(
      profile.id
        == CachedFeedViewPost.computeId(for: post, feedType: "profile-did:plc:author")
    )
  }

  @Test("App Entity annotation uses the underlying post URI, not the feed-scoped cache id")
  func appEntityAnnotationUsesUnderlyingURI() throws {
    let post = try makeFeedViewPost(rkey: "entity123")
    let cached = try #require(CachedFeedViewPost(from: post, feedType: "timeline"))

    #expect(!cached.id.hasPrefix("at://"))
    #expect(
      AppEntityAnnotationIdentifiers.postURI(for: cached)
        == "at://did:plc:author/app.bsky.feed.post/entity123"
    )
  }

  @Test("Updating a cached row cannot move it into another feed")
  func updateRefusesCrossFeedSource() throws {
    let organic = try makeFeedViewPost(rkey: "abc123")
    let repost = try makeFeedViewPost(
      rkey: "abc123",
      repostedBy: "did:plc:reposter",
      repostIndexedAt: Date(timeIntervalSince1970: 1_750_000_000)
    )
    let timeline = try #require(CachedFeedViewPost(from: organic, feedType: "timeline"))
    let originalData = timeline.serializedPost
    let profile = try #require(
      CachedFeedViewPost(from: repost, feedType: "profile-did:plc:reposter")
    )

    timeline.update(from: profile)

    #expect(timeline.feedType == "timeline")
    #expect(timeline.serializedPost == originalData)
    #expect(timeline.isRepost == false)
  }

  @Test("Primary feed persistence keeps the same post in two feeds")
  func primaryPersistenceKeepsFeedScopedRows() async throws {
    let schema = Schema([
      CachedFeedViewPost.self,
      PersistedScrollPosition.self,
      PersistedFeedState.self,
      FeedContinuityInfo.self,
    ])
    let configuration = ModelConfiguration(
      "CachedFeedPrimaryPath-InMemory",
      schema: schema,
      isStoredInMemoryOnly: true,
      cloudKitDatabase: .none
    )
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let manager = PersistentFeedStateManager(modelContainer: container)
    let post = try makeFeedViewPost(rkey: "abc123")
    let timeline = try #require(CachedFeedViewPost(from: post, feedType: "timeline"))
    let profile = try #require(
      CachedFeedViewPost(from: post, feedType: "profile-did:plc:author")
    )

    await manager.saveFeedData([timeline], for: "timeline")
    await manager.saveFeedData([profile], for: "profile-did:plc:author")

    let context = ModelContext(container)
    let rows = try context.fetch(FetchDescriptor<CachedFeedViewPost>())
    #expect(rows.count == 2)
    #expect(Set(rows.map(\.feedType)) == ["timeline", "profile-did:plc:author"])
  }

  @Test("Primary feed upsert matches both feed type and entry id")
  func primaryFeedUpsertScopesIdentity() throws {
    let source = try sourceFile(
      "Catbird/Features/Feed/Services/PersistentFeedStateManager.swift"
    )

    #expect(source.contains("post.feedType == currentFeedId && post.id == postId"))
    #expect(!source.contains("IMPORTANT: Fetch ALL existing posts by ID (across ALL feeds)"))
  }

  @Test("Thread cache lookup prefix recognizes scoped IDs without URI-prefix collisions")
  func threadCacheLookupUsesScopedEntryPrefix() throws {
    let post = try makeFeedViewPost(rkey: "abc123")
    let cached = try #require(
      CachedFeedViewPost(from: post, feedType: "thread-cache")
    )
    let uri = post.post.uri.uriString()
    let prefix = CachedFeedViewPost.entryIdPrefix(for: uri, feedType: "thread-cache")
    let longerURIPrefix = CachedFeedViewPost.entryIdPrefix(
      for: "\(uri)-different",
      feedType: "thread-cache"
    )

    #expect(cached.id.starts(with: prefix))
    #expect(!cached.id.starts(with: longerURIPrefix))

    let source = try sourceFile("Catbird/Features/Feed/Services/ThreadManager.swift")
    #expect(
      source.contains(
        "CachedFeedViewPost.entryIdPrefix(for: uriString, feedType: threadCacheFeedType)"
      )
    )
    #expect(source.contains("post.id.starts(with: entryPrefix)"))
    #expect(!source.contains("post.id.starts(with: uriString)"))
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
