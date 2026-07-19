import Foundation
import Testing
import Petrel
@testable import Catbird

@Suite("BlockedAuthorHydrator")
struct BlockedAuthorHydratorTests {

  /// Test fetcher that records call batches and serves canned profiles.
  actor FetchRecorder {
    var batches: [[String]] = []
    func record(_ batch: [String]) { batches.append(batch) }
  }

  private func makeProfile(did: String, handle: String) -> AppBskyActorDefs.ProfileViewDetailed {
    // Minimal ProfileViewDetailed matching the real generated initializer in
    // Petrel/Sources/Petrel/Generated/Lexicons/App/Bsky/AppBskyActorDefs.swift —
    // nil for every optional field.
    try! AppBskyActorDefs.ProfileViewDetailed(
      did: DID(didString: did),
      handle: Handle(handleString: handle),
      displayName: nil,
      description: nil,
      pronouns: nil,
      website: nil,
      avatar: nil,
      banner: nil,
      followersCount: nil,
      followsCount: nil,
      postsCount: nil,
      associated: nil,
      joinedViaStarterPack: nil,
      indexedAt: nil,
      createdAt: nil,
      viewer: nil,
      labels: nil,
      pinnedPost: nil,
      verification: nil,
      status: nil,
      debug: nil
    )
  }

  @Test func coalescesConcurrentRequestsIntoOneBatch() async {
    let recorder = FetchRecorder()
    let hydrator = BlockedAuthorHydrator(coalesceNanos: 50_000_000) { dids in
      await recorder.record(dids)
      return dids.map { self.makeProfile(did: $0, handle: "h-\($0.suffix(4)).bsky.social") }
    }
    async let a = hydrator.profile(for: "did:plc:aaaa1111")
    async let b = hydrator.profile(for: "did:plc:bbbb2222")
    let (ra, rb) = await (a, b)
    #expect(ra?.handle.description.contains("1111") == true)
    #expect(rb?.handle.description.contains("2222") == true)
    #expect(await recorder.batches.count == 1)
    #expect(Set(await recorder.batches[0]) == ["did:plc:aaaa1111", "did:plc:bbbb2222"])
  }

  @Test func cachesAcrossCalls() async {
    let recorder = FetchRecorder()
    let hydrator = BlockedAuthorHydrator(coalesceNanos: 1) { dids in
      await recorder.record(dids)
      return dids.map { self.makeProfile(did: $0, handle: "x.bsky.social") }
    }
    _ = await hydrator.profile(for: "did:plc:cccc")
    _ = await hydrator.profile(for: "did:plc:cccc")
    #expect(await recorder.batches.count == 1)
  }

  @Test func unresolvableDidReturnsNilAndIsNotRefetched() async {
    let recorder = FetchRecorder()
    let hydrator = BlockedAuthorHydrator(coalesceNanos: 1) { dids in
      await recorder.record(dids)
      return []  // deactivated account: server returns nothing for the DID
    }
    let first = await hydrator.profile(for: "did:plc:gone")
    let second = await hydrator.profile(for: "did:plc:gone")
    #expect(first == nil && second == nil)
    #expect(await recorder.batches.count == 1)
  }

  @Test func invalidateAllFlushesCacheAndUnresolvable() async {
    let recorder = FetchRecorder()
    let hydrator = BlockedAuthorHydrator(coalesceNanos: 1) { dids in
      await recorder.record(dids)
      return dids.map { self.makeProfile(did: $0, handle: "y.bsky.social") }
    }
    _ = await hydrator.profile(for: "did:plc:dddd")
    await hydrator.invalidateAll()
    _ = await hydrator.profile(for: "did:plc:dddd")   // account switch: stale identity must not leak
    #expect(await recorder.batches.count == 2)
  }

  @Test func transientErrorDoesNotPoisonCache() async {
    actor FailOnce { var failed = false; func shouldFail() -> Bool { if failed { return false }; failed = true; return true } }
    let gate = FailOnce()
    let hydrator = BlockedAuthorHydrator(coalesceNanos: 1) { dids in
      if await gate.shouldFail() { throw URLError(.notConnectedToInternet) }
      return dids.map { self.makeProfile(did: $0, handle: "z.bsky.social") }
    }
    let first = await hydrator.profile(for: "did:plc:eeee")
    #expect(first == nil)
    let second = await hydrator.profile(for: "did:plc:eeee")   // retried on next request
    #expect(second != nil)
  }

  @Test func chunksBatchesOfMoreThan25() async {
    let recorder = FetchRecorder()
    let hydrator = BlockedAuthorHydrator(coalesceNanos: 1) { dids in
      await recorder.record(dids)
      return dids.map { self.makeProfile(did: $0, handle: "c.bsky.social") }
    }
    let dids = (0..<30).map { "did:plc:n\($0)" }
    await hydrator.prefetch(dids: dids)
    let batches = await recorder.batches
    #expect(batches.count == 2)
    #expect(batches.allSatisfy { $0.count <= 25 })
  }
}
