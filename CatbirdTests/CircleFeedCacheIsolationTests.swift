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
}
