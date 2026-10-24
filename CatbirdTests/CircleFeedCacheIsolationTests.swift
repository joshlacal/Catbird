import Foundation
import Petrel
import PetrelCatbird
import Testing
@testable import Catbird

@Suite("Circle feed cache isolation", .serialized)
struct CircleFeedCacheIsolationTests {
  static func makeProfile(did: DID = CircleTestFixtures.alice, handle: String = "alice.test", displayName: String = "Alice") -> AppBskyActorDefs.ProfileViewBasic {
    AppBskyActorDefs.ProfileViewBasic(
      did: did,
      handle: try! Handle(handleString: handle),
      displayName: displayName,
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

  @Test("Cache keys include account and Space so accounts and Spaces never leak")
  func cacheKeysIncludeAccountAndSpace() async {
    let cache = CircleFeedCache()
    let page = CircleFeedPage(items: [], cursor: nil)
    await cache.store(page, accountDID: "did:plc:alice", space: CircleTestFixtures.familyURI, generation: cache.generation(accountDID: "did:plc:alice"))
    #expect(await cache.page(accountDID: "did:plc:bob", space: CircleTestFixtures.familyURI) == nil)
    #expect(await cache.page(accountDID: "did:plc:alice", space: CircleTestFixtures.workURI) == nil)
    #expect(await cache.page(accountDID: "did:plc:alice", space: CircleTestFixtures.familyURI) != nil)
  }

  @Test("Purge by account clears every Space page for that account")
  func purgeByAccount() async {
    let cache = CircleFeedCache()
    let page = CircleFeedPage(items: [], cursor: nil)
    await cache.store(page, accountDID: "did:plc:alice", space: CircleTestFixtures.familyURI, generation: cache.generation(accountDID: "did:plc:alice"))
    await cache.store(page, accountDID: "did:plc:alice", space: CircleTestFixtures.workURI, generation: cache.generation(accountDID: "did:plc:alice"))
    await cache.store(page, accountDID: "did:plc:bob", space: CircleTestFixtures.familyURI, generation: cache.generation(accountDID: "did:plc:bob"))
    await cache.purge(accountDID: "did:plc:alice")
    #expect(await cache.page(accountDID: "did:plc:alice", space: CircleTestFixtures.familyURI) == nil)
    #expect(await cache.page(accountDID: "did:plc:alice", space: CircleTestFixtures.workURI) == nil)
    #expect(await cache.page(accountDID: "did:plc:bob", space: CircleTestFixtures.familyURI) != nil)
  }

  @Test("Purging one Space leaves other Spaces for the same account untouched")
  func purgeBySpace() async {
    let cache = CircleFeedCache()
    let page = CircleFeedPage(items: [], cursor: nil)
    await cache.store(page, accountDID: "did:plc:alice", space: CircleTestFixtures.familyURI, generation: cache.generation(accountDID: "did:plc:alice"))
    await cache.store(page, accountDID: "did:plc:alice", space: CircleTestFixtures.workURI, generation: cache.generation(accountDID: "did:plc:alice"))
    await cache.purge(accountDID: "did:plc:alice", space: CircleTestFixtures.familyURI)
    #expect(await cache.page(accountDID: "did:plc:alice", space: CircleTestFixtures.familyURI) == nil)
    #expect(await cache.page(accountDID: "did:plc:alice", space: CircleTestFixtures.workURI) != nil)
  }

  @Test("Purging muted Space from unified removes only items for that Space")
  func purgeMutedSpaceFromUnified() async {
    let cache = CircleFeedCache()
    let item1 = CircleTestFixtures.makeFeedItem(circle: CircleTestFixtures.family, rkey: "1", text: "Hello")
    let item2 = CircleTestFixtures.makeFeedItem(circle: CircleTestFixtures.work, rkey: "2", text: "World")
    let page = CircleFeedPage(items: [item1, item2], cursor: nil)
    await cache.store(page, accountDID: "did:plc:alice", space: nil, generation: cache.generation(accountDID: "did:plc:alice"))

    await cache.purgeMutedSpaceFromUnified(accountDID: "did:plc:alice", space: CircleTestFixtures.familyURI)
    let unified = await cache.page(accountDID: "did:plc:alice", space: nil)
    #expect(unified?.items.count == 1)
    #expect(unified?.items.first?.circle.uri == CircleTestFixtures.workURI)
  }

  @Test("Deleted Space is removed from aggregate cache without removing other accounts")
  func deletedSpaceCannotReappearFromAggregateCache() async {
    let cache = CircleFeedCache()
    let family = CircleTestFixtures.makeFeedItem(circle: CircleTestFixtures.family, rkey: "deleted", text: "Private")
    let work = CircleTestFixtures.makeFeedItem(circle: CircleTestFixtures.work, rkey: "retained", text: "Work")
    let page = CircleFeedPage(items: [family, work], cursor: "obsolete-page")
    await cache.store(page, accountDID: "alice", space: nil, generation: cache.generation(accountDID: "alice"))
    await cache.store(page, accountDID: "bob", space: nil, generation: cache.generation(accountDID: "bob"))
    await cache.purge(accountDID: "alice", space: CircleTestFixtures.familyURI)
    let retained = await cache.page(accountDID: "alice", space: nil)
    #expect(retained?.items.map(\.circle.uri) == [CircleTestFixtures.workURI])
    #expect(retained?.cursor == nil)
    #expect(await cache.page(accountDID: "bob", space: nil)?.items.count == 2)
  }

  @Test("Notification cache isolates by account DID")
  func notificationCacheIsolatesByAccount() async {
    let notifCache = CircleNotificationCache()
    let notif = BlueCatbirdCircleDefs.Notification(
      id: "n1",
      reason: .value_reply,
      actor: Self.makeProfile(),
      subject: try! ATProtocolURI(uriString: "\(CircleTestFixtures.familyURI.uriString())/app.bsky.feed.post/123"),
      indexedAt: ATProtocolDate(date: Date()),
      circle: CircleTestFixtures.family
    )
    let page = CircleNotificationPage(notifications: [notif], cursor: "cur1")
    await notifCache.store(page, accountDID: "did:plc:alice", generation: notifCache.generation(accountDID: "did:plc:alice"))

    #expect(await notifCache.page(accountDID: "did:plc:alice")?.notifications.count == 1)
    #expect(await notifCache.page(accountDID: "did:plc:bob") == nil)

    await notifCache.purge(accountDID: "did:plc:alice")
    #expect(await notifCache.page(accountDID: "did:plc:alice") == nil)
  }

  @Test("Notification cache purging one Space retains sibling Spaces and other accounts")
  func notificationCachePurgeSpaceRetainsSiblings() async {
    let notifCache = CircleNotificationCache()
    let notif1 = BlueCatbirdCircleDefs.Notification(
      id: "n1",
      reason: .value_reply,
      actor: Self.makeProfile(),
      subject: try! ATProtocolURI(uriString: "\(CircleTestFixtures.familyURI.uriString())/app.bsky.feed.post/123"),
      indexedAt: ATProtocolDate(date: Date()),
      circle: CircleTestFixtures.family
    )
    let notif2 = BlueCatbirdCircleDefs.Notification(
      id: "n2",
      reason: .value_like,
      actor: Self.makeProfile(),
      subject: try! ATProtocolURI(uriString: "\(CircleTestFixtures.workURI.uriString())/app.bsky.feed.post/456"),
      indexedAt: ATProtocolDate(date: Date()),
      circle: CircleTestFixtures.work
    )
    let alicePage = CircleNotificationPage(notifications: [notif1, notif2], cursor: "curA")
    let bobPage = CircleNotificationPage(notifications: [notif1], cursor: "curB")

    await notifCache.store(alicePage, accountDID: "did:plc:alice", generation: notifCache.generation(accountDID: "did:plc:alice"))
    await notifCache.store(bobPage, accountDID: "did:plc:bob", generation: notifCache.generation(accountDID: "did:plc:bob"))

    await notifCache.purge(accountDID: "did:plc:alice", space: CircleTestFixtures.familyURI)

    let aliceRemaining = await notifCache.page(accountDID: "did:plc:alice")
    #expect(aliceRemaining?.notifications.count == 1)
    #expect(aliceRemaining?.notifications.first?.circle.uri == CircleTestFixtures.workURI)

    let bobRemaining = await notifCache.page(accountDID: "did:plc:bob")
    #expect(bobRemaining?.notifications.count == 1)
    #expect(bobRemaining?.notifications.first?.circle.uri == CircleTestFixtures.familyURI)
  }
  @Test("An in-flight feed write cannot repopulate a purged account or Space")
  func staleWritesAfterPurgeAreRejected() async {
    let cache = CircleFeedCache()
    let page = CircleFeedPage(items: [], cursor: "stale")
    let beforeSpaceDeletion = cache.generation(accountDID: "alice")
    await cache.purge(accountDID: "alice", space: CircleTestFixtures.familyURI)
    await cache.store(page, accountDID: "alice", space: nil, generation: beforeSpaceDeletion)
    #expect(await cache.page(accountDID: "alice", space: nil) == nil)
    let beforeAccountSwitch = cache.generation(accountDID: "alice")
    await cache.purge(accountDID: "alice")
    await cache.store(page, accountDID: "alice", space: CircleTestFixtures.familyURI, generation: beforeAccountSwitch)
    #expect(await cache.page(accountDID: "alice", space: CircleTestFixtures.familyURI) == nil)
    await cache.store(page, accountDID: "alice", space: nil, generation: cache.generation(accountDID: "alice"))
    #expect(await cache.page(accountDID: "alice", space: nil)?.cursor == "stale")
  }

  @Test("An in-flight notification write cannot repopulate a purged cache")
  func staleNotificationWritesAfterPurgeAreRejected() async {
    let cache = CircleNotificationCache()
    let page = CircleNotificationPage(notifications: [], cursor: "stale")
    let generation = cache.generation(accountDID: "alice")
    await cache.purge(accountDID: "alice", space: CircleTestFixtures.familyURI)
    await cache.store(page, accountDID: "alice", generation: generation)
    #expect(await cache.page(accountDID: "alice") == nil)
    let newGeneration = cache.generation(accountDID: "alice")
    await cache.purgeAll()
    await cache.store(page, accountDID: "alice", generation: newGeneration)
    #expect(await cache.page(accountDID: "alice") == nil)
  }

}
