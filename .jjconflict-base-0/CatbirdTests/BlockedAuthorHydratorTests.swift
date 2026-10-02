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

  @Test func exactly25DidsIsOneBatch() async {
    let recorder = FetchRecorder()
    let hydrator = BlockedAuthorHydrator(coalesceNanos: 1) { dids in
      await recorder.record(dids)
      return dids.map { self.makeProfile(did: $0, handle: "b.bsky.social") }
    }
    let dids = (0..<25).map { "did:plc:b\($0)" }
    await hydrator.prefetch(dids: dids)
    let batches = await recorder.batches
    #expect(batches.count == 1)
    #expect(batches[0].count == 25)
  }

  /// Reproduces the reentrancy window in `flush()`: it `await`s `fetchProfiles`
  /// once per 25-DID chunk, so `invalidateAll()` can run on the actor between
  /// chunk 1 completing (already cached) and chunk 2 starting. Without the fix,
  /// callers awaiting `profile(for:)` for a chunk-1 DID observe the wiped cache
  /// and return nil for a DID that was, in fact, resolvable. With the fix, a
  /// generation mismatch after the flush triggers exactly one retry.
  @Test func invalidateAllDuringMultiChunkFlushRetriesInsteadOfReturningNil() async {
    actor Gate {
      private var continuation: CheckedContinuation<Void, Never>?
      private var isOpen = false
      func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
      }
      func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
      }
    }

    let recorder = FetchRecorder()
    let chunk2Started = Gate()
    let proceedWithChunk2 = Gate()

    let hydrator = BlockedAuthorHydrator(coalesceNanos: 50_000_000) { dids in
      await recorder.record(dids)
      if await recorder.batches.count == 2 {
        // Chunk 1 has already returned and `flush()` has cached its results.
        // Signal the test, then hold here until the test has invalidated —
        // this is the exact window the fix must survive.
        await chunk2Started.open()
        await proceedWithChunk2.wait()
      }
      return dids.map { self.makeProfile(did: $0, handle: "race.bsky.social") }
    }

    let dids = (0 ..< 30).map { "did:plc:race\($0)" }

    // Ride 30 concurrent `profile(for:)` calls on the same coalesced flush so the
    // calls under test are genuinely awaiting the flush that gets raced, not a
    // later, already-settled one.
    let resultsTask = Task {
      await withTaskGroup(of: (String, Bool).self) { group in
        for did in dids {
          group.addTask { (did, await hydrator.profile(for: did) != nil) }
        }
        var resolved: [String: Bool] = [:]
        for await (did, ok) in group { resolved[did] = ok }
        return resolved
      }
    }

    await chunk2Started.wait()
    await hydrator.invalidateAll()   // races the in-flight multi-chunk flush
    await proceedWithChunk2.open()

    let resolved = await resultsTask.value
    #expect(resolved.count == 30)
    #expect(resolved.values.allSatisfy { $0 })   // no spurious nils from the race
    // chunk 1 (25) + chunk 2 (5) + one retry batch for the wiped chunk-1 DIDs.
    #expect(await recorder.batches.count == 3)
  }
}
