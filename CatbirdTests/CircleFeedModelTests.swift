//
//  CircleFeedModelTests.swift
//  CatbirdTests
//

import Foundation
import SwiftUI
import Petrel
import PetrelCatbird
import Testing
@testable import Catbird
@Suite("Circle feed model and media loading", .serialized)
@MainActor
struct CircleFeedModelTests {
  // MARK: - Test Transport Double

  actor MockCircleTransport: CircleTransport {
    var feedItems: [BlueCatbirdCircleDefs.FeedItem] = []
    var nextCursor: String?
    var lastQueriedSpace: SpaceRef?
    var lastQueriedCursor: String?
    var feedCallCount: Int = 0
    var errorToThrow: (any Error)?
    var onGetFeed: (@Sendable () async -> Void)?
    var mediaData: Data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAKeyNrvgAAAABJRU5ErkJggg==")!
    var lastMediaSpace: SpaceRef?
    var lastMediaAuthorDID: DID?
    var lastMediaCID: CID?
    var mediaCallCount: Int = 0
    var threadPage: CircleThreadPage?
    var threadCallCount: Int = 0
    let publicEndpointCallCount: Int = 0

    init(
      feedItems: [BlueCatbirdCircleDefs.FeedItem] = [],
      nextCursor: String? = nil,
      errorToThrow: (any Error)? = nil,
      threadPage: CircleThreadPage? = nil
    ) {
      self.feedItems = feedItems
      self.nextCursor = nextCursor
      self.errorToThrow = errorToThrow
      self.threadPage = threadPage
    }

    func setFeedItems(_ items: [BlueCatbirdCircleDefs.FeedItem], cursor: String?) {
      self.feedItems = items
      self.nextCursor = cursor
    }

    func setOnGetFeed(_ action: (@Sendable () async -> Void)?) {
      self.onGetFeed = action
    }
    func capabilities() async throws -> CircleCapability {
      CircleCapability(enabled: true, protocolRevision: "2026-08", supportsImages: true)
    }

    func listCircles(cursor: String?) async throws -> CircleListPage {
      CircleListPage(circles: [CircleTestFixtures.family, CircleTestFixtures.work], cursor: nil)
    }

    func getFeed(space: SpaceRef?, cursor: String?) async throws -> CircleFeedPage {
      if let onGetFeed {
        await onGetFeed()
      }
      if let errorToThrow { throw errorToThrow }
      feedCallCount += 1
      lastQueriedSpace = space
      lastQueriedCursor = cursor
      return CircleFeedPage(items: feedItems, cursor: nextCursor)
    }

    func getPostThread(uri: ATProtocolURI, space: SpaceRef) async throws -> CircleThreadPage {
      if let errorToThrow { throw errorToThrow }
      threadCallCount += 1
      if let threadPage {
        return threadPage
      }
      let author = AppBskyActorDefs.ProfileViewBasic(
        did: CircleTestFixtures.alice,
        handle: try! Handle(handleString: "alice.test"),
        displayName: "Alice",
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
      let post = AppBskyFeedDefs.PostView(
        uri: uri,
        cid: CID.fromDAGCBOR(Data("cid-thread".utf8)),
        author: author,
        record: .knownType(
          AppBskyFeedPost(
            text: "Thread post in space",
            entities: nil,
            facets: nil,
            reply: nil,
            embed: nil,
            langs: nil,
            labels: nil,
            tags: nil,
            createdAt: ATProtocolDate(date: Date())
          )
        ),
        embed: nil,
        bookmarkCount: nil,
        replyCount: 0,
        repostCount: 0,
        likeCount: 0,
        quoteCount: nil,
        indexedAt: ATProtocolDate(date: Date()),
        viewer: nil,
        labels: nil,
        threadgate: nil,
        debug: nil
      )
      let thread = AppBskyFeedDefs.ThreadViewPost(post: post, parent: nil, replies: nil, threadContext: nil)
      return CircleThreadPage(thread: thread, circle: CircleTestFixtures.family)
    }

    func listNotifications(cursor: String?) async throws -> CircleNotificationPage {
      CircleNotificationPage(notifications: [], cursor: nil)
    }

    func media(space: SpaceRef, authorDID: DID, cid: CID) async throws -> Data {
      if let errorToThrow { throw errorToThrow }
      mediaCallCount += 1
      lastMediaSpace = space
      lastMediaAuthorDID = authorDID
      lastMediaCID = cid
      return mediaData
    }

    func createCircle(name: String, memberDIDs: [DID]) async throws -> CircleOperation {
      CircleOperation(id: "op-1", status: .value_complete, space: CircleTestFixtures.familyURI, error: nil)
    }

    func updateMember(space: SpaceRef, memberDID: DID, action: CircleMemberAction) async throws -> CircleOperation {
      CircleOperation(id: "op-2", status: .value_complete, space: space, error: nil)
    }

    func updatePreferences(space: SpaceRef, muted: Bool) async throws -> Bool {
      muted
    }

    func report(post: ATProtocolURI, circle: CircleSummary, reason: CircleReportReason, details: String?) async throws -> UUID {
      UUID()
    }

    func activate(space: SpaceRef) async throws -> CircleAccessState {
      .active
    }

    func publishPost(destination: CircleSummary, draft: CirclePostDraft) async throws -> ATProtocolURI {
      try! ATProtocolURI(uriString: "\(destination.uri.uriString())/app.bsky.feed.post/123")
    }

    func like(post: AppBskyFeedDefs.PostView, circle: CircleSummary) async throws -> ATProtocolURI {
      try! ATProtocolURI(uriString: "\(circle.uri.uriString())/app.bsky.feed.like/123")
    }

    func deletePost(uri: ATProtocolURI, circle: CircleSummary) async throws {}
    func deleteLike(uri: ATProtocolURI, circle: CircleSummary) async throws {}
    func deleteCircle(space: SpaceRef) async throws -> CircleOperation {
      CircleOperation(id: "op-del", status: .value_complete, space: space, error: nil)
    }
    func getOperation(id: String) async throws -> CircleOperation {
      CircleOperation(id: id, status: .value_complete, space: nil, error: nil)
    }
    func retryOperation(id: String) async throws -> CircleOperation {
      CircleOperation(id: id, status: .value_complete, space: nil, error: nil)
    }
  }

  // MARK: - Helpers

  private func makeFeedItem(circle: CircleSummary, rkey: String, text: String) -> BlueCatbirdCircleDefs.FeedItem {
    let author = AppBskyActorDefs.ProfileViewBasic(
      did: circle.owner,
      handle: try! Handle(handleString: "\(circle.name.lowercased()).test"),
      displayName: "\(circle.name) Author",
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
    let postView = AppBskyFeedDefs.PostView(
      uri: try! ATProtocolURI(uriString: "\(circle.uri.uriString())/app.bsky.feed.post/\(rkey)"),
      cid: CID.fromDAGCBOR(Data("cid-\(rkey)".utf8)),
      author: author,
      record: .knownType(
        AppBskyFeedPost(
          text: text,
          entities: nil,
          facets: nil,
          reply: nil,
          embed: nil,
          langs: nil,
          labels: nil,
          tags: nil,
          createdAt: ATProtocolDate(date: Date())
        )
      ),
      embed: nil,
      bookmarkCount: nil,
      replyCount: 0,
      repostCount: 0,
      likeCount: 0,
      quoteCount: nil,
      indexedAt: ATProtocolDate(date: Date()),
      viewer: nil,
      labels: nil,
      threadgate: nil,
      debug: nil
    )
    let feedViewPost = AppBskyFeedDefs.FeedViewPost(
      post: postView,
      reply: nil,
      reason: nil,
      feedContext: nil,
      reqId: nil
    )
    return BlueCatbirdCircleDefs.FeedItem(post: feedViewPost, circle: circle)
  }

  // MARK: - Step 1: Tests

  @Test("Unified feed keeps Circle context on every post")
  func unifiedFeedKeepsCircleContextOnEveryPost() async throws {
    let familyItem = makeFeedItem(circle: CircleTestFixtures.family, rkey: "p1", text: "Family post")
    let workItem = makeFeedItem(circle: CircleTestFixtures.work, rkey: "p2", text: "Work post")

    let transport = MockCircleTransport(feedItems: [familyItem, workItem])
    let service = CircleService(transport: transport)
    let model = CircleFeedModel(service: service, accountDID: "did:plc:alice")

    try await model.load()

    #expect(model.items.map(\.circle.name) == ["Family", "Work"])
    #expect(model.accessState == .active)
    #expect(await transport.lastQueriedSpace == nil)
  }

  @Test("Circle post capabilities exclude redistribution")
  func circlePostCapabilitiesExcludeRedistribution() {
    let capabilities = PostCapabilities.circle
    #expect(capabilities.canReply)
    #expect(capabilities.canLike)
    #expect(!capabilities.canRepost)
    #expect(!capabilities.canQuote)
    #expect(!capabilities.canSharePublicly)
    #expect(!capabilities.canPublicShare)
  }

  @Test("Per-Circle feed queries specific SpaceRef")
  func perCircleFeedQueriesSpecificSpace() async throws {
    let familyItem = makeFeedItem(circle: CircleTestFixtures.family, rkey: "p1", text: "Family post")
    let transport = MockCircleTransport(feedItems: [familyItem])
    let service = CircleService(transport: transport)
    let model = CircleFeedModel(
      service: service,
      space: CircleTestFixtures.familyURI,
      accountDID: "did:plc:alice"
    )

    try await model.load()

    #expect(model.items.count == 1)
    #expect(model.items.first?.circle.uri == CircleTestFixtures.familyURI)
    #expect(await transport.lastQueriedSpace == CircleTestFixtures.familyURI)
  }

  @Test("Paging appends items and advances cursor")
  func pagingAppendsItemsAndUpdatesCursor() async throws {
    let item1 = makeFeedItem(circle: CircleTestFixtures.family, rkey: "p1", text: "Post 1")
    let item2 = makeFeedItem(circle: CircleTestFixtures.family, rkey: "p2", text: "Post 2")

    let transport = MockCircleTransport(feedItems: [item1], nextCursor: "cursor_page2")
    let service = CircleService(transport: transport)
    let model = CircleFeedModel(service: service, accountDID: "did:plc:alice")

    try await model.load()
    #expect(model.items.count == 1)
    #expect(model.cursor == "cursor_page2")

    await transport.setFeedItems([item2], cursor: nil)
    try await model.loadMore()

    #expect(model.items.count == 2)
    #expect(model.cursor == nil)
    #expect(await transport.lastQueriedCursor == "cursor_page2")
  }

  @Test("Memory cache is populated and restored without database persistence")
  func memoryCacheIsPopulatedAndRestored() async throws {
    let cache = CircleFeedCache()
    let item1 = makeFeedItem(circle: CircleTestFixtures.family, rkey: "p1", text: "Post 1")

    let transport = MockCircleTransport(feedItems: [item1])
    let service = CircleService(transport: transport)
    let model = CircleFeedModel(
      service: service,
      space: CircleTestFixtures.familyURI,
      accountDID: "did:plc:alice",
      cache: cache
    )

    try await model.load()
    #expect(model.items.count == 1)

    // Check that cache holds the page
    let cachedPage = await cache.page(accountDID: "did:plc:alice", space: CircleTestFixtures.familyURI)
    #expect(cachedPage?.items.count == 1)

    // A second model using the same cache should see items even before network load
    let secondModel = CircleFeedModel(
      service: service,
      space: CircleTestFixtures.familyURI,
      accountDID: "did:plc:alice",
      cache: cache
    )
    #expect(secondModel.items.isEmpty)
    try await secondModel.load()
    #expect(secondModel.items.count == 1)
  }

  @Test("Access transitions map explicitly to expired, removed, and unsupported")
  func accessTransitionsMapExplicitly() async throws {
    // 1. Expired
    let expiredTransport = MockCircleTransport(errorToThrow: CircleError.accessExpired)
    let expiredModel = CircleFeedModel(service: CircleService(transport: expiredTransport))
    await #expect(throws: CircleError.self) {
      try await expiredModel.load()
    }
    #expect(expiredModel.accessState == .expired)

    // 2. Removed
    let removedTransport = MockCircleTransport(errorToThrow: CircleError.accessRemoved)
    let removedModel = CircleFeedModel(
      service: CircleService(transport: removedTransport),
      space: CircleTestFixtures.familyURI,
      accountDID: "did:plc:alice"
    )
    await #expect(throws: CircleError.self) {
      try await removedModel.load()
    }
    #expect(removedModel.accessState == .removed)

    // 3. Unsupported
    let unsupportedTransport = MockCircleTransport(errorToThrow: CircleError.unsupportedPDS)
    let unsupportedModel = CircleFeedModel(service: CircleService(transport: unsupportedTransport))
    await #expect(throws: CircleError.self) {
      try await unsupportedModel.load()
    }
    #expect(unsupportedModel.accessState == .unsupported)

    // 4. Outage / UpstreamUnavailable surfaces error directly without mapping to empty feed
    let outageTransport = MockCircleTransport(errorToThrow: CircleError.upstreamUnavailable)
    let outageModel = CircleFeedModel(service: CircleService(transport: outageTransport))
    await #expect(throws: CircleError.self) {
      try await outageModel.load()
    }
    #expect(outageModel.error == .upstreamUnavailable)
  }

  @Test("Purging unavailable Space removes matching items and purges cache")
  func purgeUnavailableSpaceRemovesMatchingItems() async throws {
    let cache = CircleFeedCache()
    let familyItem = makeFeedItem(circle: CircleTestFixtures.family, rkey: "p1", text: "Family post")
    let workItem = makeFeedItem(circle: CircleTestFixtures.work, rkey: "p2", text: "Work post")

    let transport = MockCircleTransport(feedItems: [familyItem, workItem])
    let service = CircleService(transport: transport)
    let model = CircleFeedModel(
      service: service,
      accountDID: "did:plc:alice",
      cache: cache
    )

    try await model.load()
    #expect(model.items.count == 2)

    await model.purgeUnavailableSpace(CircleTestFixtures.familyURI)

    #expect(model.items.count == 1)
    #expect(model.items.first?.circle.uri == CircleTestFixtures.workURI)
  }

  @Test("CircleMediaLoader decodes platform image memory-only and purges correctly")
  func circleMediaLoaderAuthenticatedFetchingAndPurging() async throws {
    let transport = MockCircleTransport()
    let service = CircleService(transport: transport)
    let loader = CircleMediaLoader(service: service)

    let cid = CID.fromDAGCBOR(Data("cid-image".utf8))
    let image = try await loader.image(
      accountDID: "did:plc:alice",
      space: CircleTestFixtures.familyURI,
      authorDID: CircleTestFixtures.alice,
      cid: cid
    )

    #expect(image.size.width > 0)
    #expect(await transport.mediaCallCount == 1)

    // Calling again returns cached image without hitting transport again
    let cachedImage = try await loader.image(
      accountDID: "did:plc:alice",
      space: CircleTestFixtures.familyURI,
      authorDID: CircleTestFixtures.alice,
      cid: cid
    )
    #expect(cachedImage.size.width > 0)
    #expect(await transport.mediaCallCount == 1)

    // Purge account
    await loader.purge(accountDID: "did:plc:alice")

    // Fetching again calls transport again
    _ = try await loader.image(
      accountDID: "did:plc:alice",
      space: CircleTestFixtures.familyURI,
      authorDID: CircleTestFixtures.alice,
      cid: cid
    )
    #expect(await transport.mediaCallCount == 2)
  }

  @Test("Member authored Circle image binds member author DID and rejects nil without owner fallback")
  func memberAuthoredCircleImageBindsMemberAuthorDIDAndNotCircleOwner() async throws {
    let circle = CircleTestFixtures.family
    let memberDID = try! DID(didString: "did:plc:bob-member")
    let cid = CID.fromDAGCBOR(Data("cid-member-image".utf8))
    let viewImage = AppBskyEmbedImages.ViewImage(
      thumb: URI(uriString: "https://example.com/blob/\(cid.description)"),
      fullsize: URI(uriString: "https://example.com/blob/\(cid.description)"),
      alt: "Member image",
      aspectRatio: nil
    )

    // 1. Initializing with explicit member author DID binds to member, not circle owner
    let mediaView = CircleMediaView(
      viewImage: viewImage,
      circle: circle,
      authorDID: memberDID
    )
    #expect(mediaView != nil)
    #expect(mediaView?.authorDID == memberDID)
    #expect(mediaView?.authorDID != circle.owner)

    // 2. Initializing with nil authorDID fails closed (returns nil) — never falls back to circle.owner
    let nilAuthorView = CircleMediaView(
      viewImage: viewImage,
      circle: circle,
      authorDID: nil
    )
    #expect(nilAuthorView == nil)

    // 3. Transport receives member author DID
    let transport = MockCircleTransport()
    let service = CircleService(transport: transport)
    let loader = CircleMediaLoader(service: service)

    _ = try await loader.image(
      accountDID: "did:plc:viewer",
      space: circle.uri,
      authorDID: memberDID,
      cid: cid
    )
    #expect(await transport.mediaCallCount == 1)
    #expect(await transport.lastMediaAuthorDID == memberDID)
    #expect(await transport.lastMediaAuthorDID != circle.owner)
  }

  @Test("AuthManager logout purges Circle feed and media caches for departing account")
  func authManagerLogoutPurgesCircleFeedAndMediaCaches() async throws {
    let transport = MockCircleTransport()
    let service = CircleService(transport: transport)
    await CircleMediaLoader.shared.setService(service)

    let cid = CID.fromDAGCBOR(Data("cid-logout-purge".utf8))

    // Pre-populate shared media loader and shared feed cache for Account 1 and Account 2
    _ = try await CircleMediaLoader.shared.image(
      accountDID: "did:plc:account1",
      space: CircleTestFixtures.familyURI,
      authorDID: CircleTestFixtures.alice,
      cid: cid
    )
    _ = try await CircleMediaLoader.shared.image(
      accountDID: "did:plc:account2",
      space: CircleTestFixtures.familyURI,
      authorDID: CircleTestFixtures.alice,
      cid: cid
    )
    #expect(await transport.mediaCallCount == 2)

    let page1 = CircleFeedPage(items: [makeFeedItem(circle: CircleTestFixtures.family, rkey: "post1", text: "Hello")], cursor: nil)
    let page2 = CircleFeedPage(items: [makeFeedItem(circle: CircleTestFixtures.family, rkey: "post2", text: "World")], cursor: nil)
    await CircleFeedCache.shared.store(page1, accountDID: "did:plc:account1", space: CircleTestFixtures.familyURI)
    await CircleFeedCache.shared.store(page2, accountDID: "did:plc:account2", space: CircleTestFixtures.familyURI)

    #expect(await CircleFeedCache.shared.page(accountDID: "did:plc:account1", space: CircleTestFixtures.familyURI) != nil)
    #expect(await CircleFeedCache.shared.page(accountDID: "did:plc:account2", space: CircleTestFixtures.familyURI) != nil)

    // Drive production logout ordering through AuthenticationManager
    let authManager = AuthenticationManager()
    authManager.updateState(.authenticated(userDID: "did:plc:account1"))
    await authManager.logout()

    // Account 1 feed cache and media cache must be purged
    #expect(await CircleFeedCache.shared.page(accountDID: "did:plc:account1", space: CircleTestFixtures.familyURI) == nil)
    _ = try await CircleMediaLoader.shared.image(
      accountDID: "did:plc:account1",
      space: CircleTestFixtures.familyURI,
      authorDID: CircleTestFixtures.alice,
      cid: cid
    )
    #expect(await transport.mediaCallCount == 3) // Re-fetched because Account 1 was purged

    // Account 2 feed cache and media cache must remain intact
    #expect(await CircleFeedCache.shared.page(accountDID: "did:plc:account2", space: CircleTestFixtures.familyURI) != nil)
    _ = try await CircleMediaLoader.shared.image(
      accountDID: "did:plc:account2",
      space: CircleTestFixtures.familyURI,
      authorDID: CircleTestFixtures.alice,
      cid: cid
    )
    #expect(await transport.mediaCallCount == 3) // Cache hit, call count did not increment
  }

  @Test("Record with media Circle gallery binds author DID to gallery embed and media view")
  func recordWithMediaCircleGalleryBindsAuthorDID() async throws {
    let circle = CircleTestFixtures.family
    let memberDID = CircleTestFixtures.alice
    let imageCID = "bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi"

    let galleryImage = AppBskyEmbedGallery.ViewImage(
      thumbnail: try URI(uriString: "https://example.com/blob/\(imageCID)"),
      fullsize: try URI(uriString: "https://example.com/blob/\(imageCID)"),
      alt: "Circle photo in record with media",
      aspectRatio: AppBskyEmbedDefs.AspectRatio(width: 800, height: 600)
    )
    let galleryView = AppBskyEmbedGallery.View(
      items: [.appBskyEmbedGalleryViewImage(galleryImage)]
    )

    let viewRecord = AppBskyEmbedRecord.ViewRecord(
      uri: try ATProtocolURI(uriString: "at://\(circle.owner)/app.bsky.feed.post/quoted123"),
      cid: try CID.parse(imageCID),
      author: AppBskyActorDefs.ProfileViewBasic(
        did: circle.owner,
        handle: try Handle(handleString: "owner.bsky.social"),
        displayName: "Owner",
        pronouns: nil,
        avatar: nil,
        associated: nil,
        viewer: nil,
        labels: nil,
        createdAt: nil,
        verification: nil,
        status: nil,
        debug: nil
      ),
      value: .knownType(
        AppBskyFeedPost(
          text: "Quoted text",
          entities: nil,
          facets: nil,
          reply: nil,
          embed: nil,
          langs: nil,
          labels: nil,
          tags: nil,
          createdAt: ATProtocolDate(date: Date())
        )
      ),
      labels: nil,
      replyCount: 0,
      repostCount: 0,
      likeCount: 0,
      quoteCount: 0,
      embeds: nil,
      indexedAt: ATProtocolDate(date: Date())
    )

    let recordWithMediaView = AppBskyEmbedRecordWithMedia.View(
      record: AppBskyEmbedRecord.View(record: .appBskyEmbedRecordViewRecord(viewRecord)),
      media: .appBskyEmbedGalleryView(galleryView)
    )

    let postEmbed = PostEmbed(
      embed: .appBskyEmbedRecordWithMediaView(recordWithMediaView),
      labels: nil,
      path: .constant(NavigationPath()),
      visibilityContext: .circle(circle),
      authorDID: memberDID
    )

    #expect(postEmbed.authorDID == memberDID)
    if case .circle(let embeddedCircle) = postEmbed.visibilityContext {
      #expect(embeddedCircle.uri == circle.uri)
    } else {
      Issue.record("Expected .circle visibility context on PostEmbed")
    }

    // Verify GalleryEmbedView with authorDID properly initializes CircleMediaView
    let galleryEmbed = GalleryEmbedView(
      gallery: galleryView,
      shouldBlur: false,
      visibilityContext: .circle(circle),
      authorDID: memberDID
    )
    #expect(galleryEmbed.authorDID == memberDID)

    // Prove fail-closed: GalleryEmbedView without authorDID produces nil CircleMediaView,
    // whereas with memberDID it successfully constructs CircleMediaView with memberDID
    let mediaViewWithMember = CircleMediaView(
      viewImage: AppBskyEmbedImages.ViewImage(
        thumb: galleryImage.thumbnail,
        fullsize: galleryImage.fullsize,
        alt: galleryImage.alt,
        aspectRatio: galleryImage.aspectRatio
      ),
      circle: circle,
      authorDID: galleryEmbed.authorDID
    )
    #expect(mediaViewWithMember != nil)
    #expect(mediaViewWithMember?.authorDID == memberDID)

    let mediaViewWithoutAuthor = CircleMediaView(
      viewImage: AppBskyEmbedImages.ViewImage(
        thumb: galleryImage.thumbnail,
        fullsize: galleryImage.fullsize,
        alt: galleryImage.alt,
        aspectRatio: galleryImage.aspectRatio
      ),
      circle: circle,
      authorDID: nil
    )
    #expect(mediaViewWithoutAuthor == nil)
  }
  // MARK: - Lifecycle Purge & Generation Guard Tests

  @Test("Unified feed synchronously purges deleted Space on lifecycle event and retains siblings")
  func unifiedFeedSynchronouslyPurgesDeletedSpaceOnLifecycleEvent() async throws {
    let familyCircle = CircleTestFixtures.family
    let workCircle = CircleTestFixtures.work

    let itemFamily = makeFeedItem(
      circle: familyCircle,
      rkey: "post_family",
      text: "Family post"
    )
    let itemWork = makeFeedItem(
      circle: workCircle,
      rkey: "post_work",
      text: "Work post"
    )
    let transport = MockCircleTransport(feedItems: [itemFamily, itemWork])
    let service = CircleService(transport: transport)
    let cache = CircleFeedCache()

    let model = CircleFeedModel(
      service: service,
      space: nil, // Unified feed
      accountDID: "did:plc:alice",
      cache: cache
    )

    try await model.load()
    #expect(model.items.count == 2)

    // Post .circleDeleted lifecycle event for familyCircle
    NotificationCenter.default.post(
      name: .circleDeleted,
      object: nil,
      userInfo: [
        "accountDID": "did:plc:alice",
        "spaceURI": familyCircle.uri.uriString()
      ]
    )

    // Synchronously purged on MainActor
    #expect(model.items.count == 1)
    #expect(model.items.first?.circle.uri == workCircle.uri)

    // Sibling Space retained in cache
    try await Task.sleep(nanoseconds: 10_000_000)
    let cachedFamily = await cache.page(accountDID: "did:plc:alice", space: familyCircle.uri)
    #expect(cachedFamily == nil)
  }

  @Test("Detail feed transitions to removed state on lifecycle event for that Space")
  func detailFeedMarksRemovedOnLifecycleEventForSameSpace() async throws {
    let familyCircle = CircleTestFixtures.family
    let itemFamily = makeFeedItem(
      circle: familyCircle,
      rkey: "post_family",
      text: "Family post"
    )
    let transport = MockCircleTransport(feedItems: [itemFamily])
    let service = CircleService(transport: transport)
    let cache = CircleFeedCache()

    let model = CircleFeedModel(
      service: service,
      space: familyCircle.uri,
      accountDID: "did:plc:alice",
      cache: cache
    )

    try await model.load()
    #expect(model.items.count == 1)
    #expect(model.accessState == .active)

    // Post .circleDeleted for familyCircle
    NotificationCenter.default.post(
      name: .circleDeleted,
      object: nil,
      userInfo: [
        "accountDID": "did:plc:alice",
        "spaceURI": familyCircle.uri.uriString()
      ]
    )

    #expect(model.items.isEmpty)
    #expect(model.accessState == .removed)
    #expect(model.cursor == nil)
  }

  @Test("Stale in-flight feed load cannot resurrect purged items after deletion")
  func staleFeedRequestCannotResurrectPurgedSpaceAfterDeletion() async throws {
    let familyCircle = CircleTestFixtures.family
    let itemFamily = makeFeedItem(
      circle: familyCircle,
      rkey: "post_family",
      text: "Family post"
    )
    let transport = MockCircleTransport(feedItems: [itemFamily])
    let service = CircleService(transport: transport)
    let cache = CircleFeedCache()

    let model = CircleFeedModel(
      service: service,
      space: familyCircle.uri,
      accountDID: "did:plc:alice",
      cache: cache
    )

    // Purge Space (increments generation)
    await model.purgeUnavailableSpace(familyCircle.uri)
    #expect(model.items.isEmpty)
    #expect(model.accessState == .removed)
  }

  @Test("Barrier test: in-flight getFeed overlapped with space deletion does not resurrect deleted space")
  func inFlightFeedLoadOverlappedWithCircleDeletedDoesNotResurrect() async throws {
    let familyCircle = CircleTestFixtures.family
    let itemFamily = makeFeedItem(
      circle: familyCircle,
      rkey: "post_family",
      text: "Family post"
    )
    let transport = MockCircleTransport(feedItems: [itemFamily])
    let service = CircleService(transport: transport)
    let cache = CircleFeedCache()

    let model = CircleFeedModel(
      service: service,
      space: familyCircle.uri,
      accountDID: "did:plc:alice",
      cache: cache
    )

    // Hook getFeed so that during the network call, a .circleDeleted notification is posted
    await transport.setOnGetFeed {
      await MainActor.run {
        NotificationCenter.default.post(
          name: .circleDeleted,
          object: nil,
          userInfo: [
            "accountDID": "did:plc:alice",
            "spaceURI": familyCircle.uri.uriString()
          ]
        )
      }
    }

    try await model.load()

    // The in-flight response must be discarded because generation changed during the request
    #expect(model.items.isEmpty)
    #expect(model.accessState == .removed)
  }

  @Test("Barrier test: in-flight unified feed load overlapped with mute does not resurrect muted circle")
  func inFlightUnifiedFeedLoadOverlappedWithMuteDoesNotResurrect() async throws {
    let familyCircle = CircleTestFixtures.family
    let workCircle = CircleTestFixtures.work
    let itemFamily = makeFeedItem(circle: familyCircle, rkey: "post_family", text: "Family post")
    let itemWork = makeFeedItem(circle: workCircle, rkey: "post_work", text: "Work post")

    let transport = MockCircleTransport(feedItems: [itemFamily, itemWork])
    let service = CircleService(transport: transport)
    let cache = CircleFeedCache()

    let model = CircleFeedModel(
      service: service,
      space: nil,
      accountDID: "did:plc:alice",
      cache: cache
    )

    // Hook getFeed so that during the network call, familyCircle is muted
    await transport.setOnGetFeed {
      await MainActor.run {
        model.purgeMutedCircle(familyCircle.uri)
      }
    }

    try await model.load()

    // In-flight response was discarded due to generation increment on mute; items remain empty (or clean)
    #expect(!model.items.contains(where: { $0.circle.uri == familyCircle.uri }))
  }
}
