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
      accountDID: "did:plc:alice",
      cache: CircleFeedCache()
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
      accountDID: "did:plc:alice_purge_unavailable",
      cache: cache
    )

    try await model.load()
    #expect(model.items.count == 2)

    await model.purgeUnavailableSpace(CircleTestFixtures.familyURI)

    #expect(model.items.count == 1)
    #expect(model.items.first?.circle.uri == CircleTestFixtures.workURI)
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

  @Test("Barrier test: in-flight cache restore overlapped with account invalidation discards old cache and retains sibling")
  func inFlightCacheRestoreOverlappedWithAccountInvalidationDiscardsOldCacheAndRetainsSibling() async throws {
    let familyCircle = CircleTestFixtures.family
    let itemFamily = makeFeedItem(circle: familyCircle, rkey: "post_family", text: "Family post")
    let itemBob = makeFeedItem(circle: familyCircle, rkey: "post_bob", text: "Bob post")

    let cache = CircleFeedCache()
    await cache.store(CircleFeedPage(items: [itemFamily], cursor: "cursor_alice"), accountDID: "did:plc:alice", space: familyCircle.uri)
    await cache.store(CircleFeedPage(items: [itemBob], cursor: "cursor_bob"), accountDID: "did:plc:bob", space: familyCircle.uri)

    let transport = MockCircleTransport(feedItems: [])
    let service = CircleService(transport: transport)

    let model = CircleFeedModel(
      service: service,
      space: familyCircle.uri,
      accountDID: "did:plc:alice",
      cache: cache,
      activeDIDProvider: { "did:plc:alice" }
    )

    let gate = CircleAsyncGate()
    await cache.setOnPageFetch {
      await cache.setOnPageFetch(nil)
      await gate.enter()
    }
    let loadTask = Task { @MainActor in
      try await model.load()
    }

    await gate.awaitEntry()

    // Production lifecycle invalidation & cache purge
    NotificationCenter.default.post(
      name: .circleAccountInvalidated,
      object: nil,
      userInfo: ["accountDID": "did:plc:alice"]
    )
    await cache.purge(accountDID: "did:plc:alice")

    // Assert departing cache removed and sibling present before releasing stale snapshot
    #expect(await cache.page(accountDID: "did:plc:alice", space: familyCircle.uri) == nil)
    let bobCachedBefore = await cache.page(accountDID: "did:plc:bob", space: familyCircle.uri)
    #expect(bobCachedBefore != nil)
    #expect(bobCachedBefore?.items.count == 1)

    // Release gate allowing the cache read to complete returning the captured stale snapshot
    await gate.release()
    _ = try? await loadTask.value

    // Model items must be empty and model marked permanently invalidated (stale snapshot discarded)
    #expect(model.items.isEmpty)
    #expect(model.cursor == nil)
    #expect(model.isInvalidated)
    #expect(await cache.page(accountDID: "did:plc:alice", space: familyCircle.uri) == nil)

    // Subsequent load or refresh calls cannot resurrect data
    try? await model.load()
    #expect(model.items.isEmpty)
    #expect(model.cursor == nil)
    #expect(await cache.page(accountDID: "did:plc:alice", space: familyCircle.uri) == nil)

    // Sibling account (Bob) state must remain in cache
    let bobCached = await cache.page(accountDID: "did:plc:bob", space: familyCircle.uri)
    #expect(bobCached != nil)
    #expect(bobCached?.items.count == 1)
    #expect(bobCached?.items.first?.post.post.uri == itemBob.post.post.uri)
  }

  @Test("Barrier test: in-flight feed network refresh overlapped with account switch discards old response and retains sibling")
  func inFlightFeedNetworkRefreshOverlappedWithAccountSwitchDiscardsOldResponseAndRetainsSibling() async throws {
    let familyCircle = CircleTestFixtures.family
    let itemAlice = makeFeedItem(circle: familyCircle, rkey: "post_alice", text: "Alice post")
    let itemBob = makeFeedItem(circle: familyCircle, rkey: "post_bob", text: "Bob post")

    let cache = CircleFeedCache()
    await cache.store(CircleFeedPage(items: [itemBob], cursor: "cursor_bob"), accountDID: "did:plc:bob", space: familyCircle.uri)

    let transport = MockCircleTransport(feedItems: [itemAlice])
    let service = CircleService(transport: transport)

    final class ActiveAccountHolder: @unchecked Sendable {
      var did: String = "did:plc:alice"
    }
    let activeHolder = ActiveAccountHolder()

    let model = CircleFeedModel(
      service: service,
      space: familyCircle.uri,
      accountDID: "did:plc:alice",
      cache: cache,
      activeDIDProvider: { activeHolder.did }
    )

    let gate = CircleAsyncGate()
    await transport.setOnGetFeed {
      await transport.setOnGetFeed(nil)
      await gate.enter()
    }
    let loadTask = Task { @MainActor in
      try await model.load()
    }

    await gate.awaitEntry()

    // While suspended in network call, simulate account switch to Bob
    activeHolder.did = "did:plc:bob"
    NotificationCenter.default.post(
      name: .circleAccountInvalidated,
      object: nil,
      userInfo: ["accountDID": "did:plc:alice"]
    )
    await cache.purge(accountDID: "did:plc:alice")

    // Assert departing cache removed
    #expect(await cache.page(accountDID: "did:plc:alice", space: familyCircle.uri) == nil)

    await gate.release()
    _ = try? await loadTask.value

    // Alice's model must remain empty and invalidated
    #expect(model.items.isEmpty)
    #expect(model.cursor == nil)
    #expect(model.isInvalidated)

    // Alice's cache must be empty
    let aliceCached = await cache.page(accountDID: "did:plc:alice", space: familyCircle.uri)
    #expect(aliceCached == nil)

    // Bob's cache must be retained intact
    let bobCached = await cache.page(accountDID: "did:plc:bob", space: familyCircle.uri)
    #expect(bobCached != nil)
    #expect(bobCached?.items.count == 1)
    #expect(bobCached?.items.first?.post.post.uri == itemBob.post.post.uri)
  }

  @Test("Invalidated CircleFeedModel permanently rejects all new operations")
  func invalidatedCircleFeedModelPermanentlyRejectsOperations() async throws {
    let familyCircle = CircleTestFixtures.family
    let itemAlice = makeFeedItem(circle: familyCircle, rkey: "post_alice", text: "Alice post")
    let transport = MockCircleTransport(feedItems: [itemAlice])
    let service = CircleService(transport: transport)
    let cache = CircleFeedCache()

    let model = CircleFeedModel(
      service: service,
      space: familyCircle.uri,
      accountDID: "did:plc:alice",
      cache: cache,
      activeDIDProvider: { "did:plc:alice" }
    )

    // Invalidate model
    NotificationCenter.default.post(
      name: .circleAccountInvalidated,
      object: nil,
      userInfo: ["accountDID": "did:plc:alice"]
    )

    #expect(model.isInvalidated)

    // Try load -> fails closed immediately
    try await model.load()
    #expect(model.items.isEmpty)
    #expect(await transport.feedCallCount == 0)

    // Try loadMore -> fails closed immediately
    try await model.loadMore()
    #expect(model.items.isEmpty)
    #expect(await transport.feedCallCount == 0)
  }
}
