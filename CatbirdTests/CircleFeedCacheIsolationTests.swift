import Foundation
import Petrel
import PetrelCatbird
import Testing
@testable import Catbird

@Suite("Circle feed cache isolation")
struct CircleFeedCacheIsolationTests {
  @Test("Cache keys include account and Space so accounts and Spaces never leak")
  func cacheKeysIncludeAccountAndSpace() async {
    let cache = CircleFeedCache()
    let page = CircleFeedPage(items: [], cursor: nil)
    await cache.store(page, accountDID: "did:plc:alice", space: CircleTestFixtures.familyURI)
    #expect(await cache.page(accountDID: "did:plc:bob", space: CircleTestFixtures.familyURI) == nil)
    #expect(await cache.page(accountDID: "did:plc:alice", space: CircleTestFixtures.workURI) == nil)
    #expect(await cache.page(accountDID: "did:plc:alice", space: CircleTestFixtures.familyURI) != nil)
  }

  @Test("Purge by account clears every Space page for that account")
  func purgeByAccount() async {
    let cache = CircleFeedCache()
    let page = CircleFeedPage(items: [], cursor: nil)
    await cache.store(page, accountDID: "did:plc:alice", space: CircleTestFixtures.familyURI)
    await cache.store(page, accountDID: "did:plc:alice", space: CircleTestFixtures.workURI)
    await cache.store(page, accountDID: "did:plc:bob", space: CircleTestFixtures.familyURI)
    await cache.purge(accountDID: "did:plc:alice")
    #expect(await cache.page(accountDID: "did:plc:alice", space: CircleTestFixtures.familyURI) == nil)
    #expect(await cache.page(accountDID: "did:plc:alice", space: CircleTestFixtures.workURI) == nil)
    #expect(await cache.page(accountDID: "did:plc:bob", space: CircleTestFixtures.familyURI) != nil)
  }

  @Test("Purging one Space leaves other Spaces for the same account untouched")
  func purgeBySpace() async {
    let cache = CircleFeedCache()
    let page = CircleFeedPage(items: [], cursor: nil)
    await cache.store(page, accountDID: "did:plc:alice", space: CircleTestFixtures.familyURI)
    await cache.store(page, accountDID: "did:plc:alice", space: CircleTestFixtures.workURI)
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
    await cache.store(page, accountDID: "did:plc:alice", space: nil)

    await cache.purgeMutedSpaceFromUnified(accountDID: "did:plc:alice", space: CircleTestFixtures.familyURI)
    let unified = await cache.page(accountDID: "did:plc:alice", space: nil)
    #expect(unified?.items.count == 1)
    #expect(unified?.items.first?.circle.uri == CircleTestFixtures.workURI)
  }
}
