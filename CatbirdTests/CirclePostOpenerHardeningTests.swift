//
//  CirclePostOpenerHardeningTests.swift
//  CatbirdTests
//
//  Task 15 fix round 1: raw record bytes for the FFI, payload (not view)
//  memoization, negative caching, epoch-number bounds and cross-Circle memo
//  guards. Scripted crypto and fetches only.
//

import CatbirdMLSCore
import Foundation
import Petrel
import PetrelCatbird
import Testing
@testable import Catbird

private func likeCount(_ item: CircleOpenedItem) -> Int? {
  item.feedViewPost?.post.likeCount
}

private func epochJSON(number: String, head: Data) -> String {
  "{\"current\":{\"epochNumber\":\(number),\"epochHead\":{\"$bytes\":\"\(head.base64EncodedString())\"}}}"
}

/// A test clock the resolver reads.
private final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value = Date(timeIntervalSince1970: 1_800_000_000)
  var now: Date { lock.withLock { value } }
  func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

extension CirclePostOpenerTests {
  @Test("The live resolver path hands the FFI the exact getRecord value bytes")
  func liveResolverPassesRawRecordBytes() throws {
    let head = Data(repeating: 0x5A, count: 32).base64EncodedString()
    let raw = """
    {"$type":"blue.catbird.labyrinth.mailboxKeys", "current":{"epochNumber":3,\
    "epochHead":{"$bytes":"\(head)"},"futureField":1},"attestation":{"sig":{"$bytes":"AAEC"}},\
    "futureTop":"x"}
    """
    let body = Data("""
    {"uri":"at://did:plc:bob/blue.catbird.labyrinth.mailboxKeys/self",\
    "cid":"\(CID.fromDAGCBOR(Data("mk".utf8)).string)","value":\(raw)}
    """.utf8)

    let value = try RepoAuthorEpochResolver.recordValueJSON(statusCode: 200, body: body)

    #expect(value == raw)
    #expect(value?.components(separatedBy: "\"$type\"").count == 2) // the top-level one only
    #expect(value?.contains("futureTop") == true)
    #expect(value?.contains("futureField") == true)
    // Positive control: the typed Petrel round trip this replaces did not preserve the bytes.
    if let typed = try? JSONDecoder().decode(ComAtprotoRepoGetRecord.Output.self, from: body),
       let reencoded = try? JSONEncoder().encode(typed.value) {
      #expect(String(decoding: reencoded, as: UTF8.self) != raw)
    }
    // A missing record is nil; a server error is transient (thrown, not "missing").
    #expect(try RepoAuthorEpochResolver.recordValueJSON(statusCode: 400, body: Data("{}".utf8)) == nil)
    #expect(throws: URLError.self) {
      _ = try RepoAuthorEpochResolver.recordValueJSON(statusCode: 502, body: Data())
    }
  }

  @Test("A second page naming the same unknown author head performs no repo reads")
  func unknownEpochHeadIsNegativeCached() async throws {
    let fetched = FetchLog()
    let resolver = RepoAuthorEpochResolver { _, rkey in
      await fetched.append(rkey)
      return rkey == "self" ? epochJSON(number: "0", head: Data(repeating: 0x01, count: 32)) : nil
    }
    let harness = OpenerHarness(resolver: resolver)
    try await harness.holdKeys([1])

    let first = await harness.opener.open(CircleOpenFixtures.encryptedItem(0), circle: CircleOpenFixtures.circle)
    guard case .unverifiable = first else {
      Issue.record("expected .unverifiable, got \(first)")
      return
    }
    let readsAfterFirstPage = await fetched.rkeys.count
    #expect(readsAfterFirstPage == 1)

    // Another post by the same author, same unknown head: zero getRecord calls.
    _ = await harness.opener.open(CircleOpenFixtures.encryptedItem(1), circle: CircleOpenFixtures.circle)
    #expect(await fetched.rkeys.count == readsAfterFirstPage)
    #expect(await harness.crypto.openCalls.isEmpty)
  }

  @Test("The negative cache expires after its TTL, and network errors are never cached")
  func negativeCacheTTLAndTransientErrors() async throws {
    let clock = TestClock()
    let fetched = FetchLog()
    let resolver = RepoAuthorEpochResolver(fetch: { _, rkey in
      await fetched.append(rkey)
      return nil
    }, now: { clock.now })
    let head = Data(repeating: 0x77, count: 32)
    for _ in 0..<2 {
      await #expect(throws: AuthorEpochResolverError.recordUnavailable) {
        _ = try await resolver.epochJSON(did: CircleOpenFixtures.author, epochHead: head)
      }
    }
    #expect(await fetched.rkeys.count == 1)
    clock.advance(RepoAuthorEpochResolver.negativeTTL + 1)
    _ = try? await resolver.epochJSON(did: CircleOpenFixtures.author, epochHead: head)
    #expect(await fetched.rkeys.count == 2)

    let transientFetches = FetchLog()
    let flaky = RepoAuthorEpochResolver { _, rkey in
      await transientFetches.append(rkey)
      throw URLError(.timedOut)
    }
    for _ in 0..<2 { _ = try? await flaky.epochJSON(did: CircleOpenFixtures.author, epochHead: head) }
    #expect(await transientFetches.rkeys.count == 2)
  }

  @Test("A deterministic FFI failure is memoized for the same inputs")
  func ffiFailureIsMemoized() async throws {
    let harness = OpenerHarness()
    try await harness.holdKeys([1])
    await harness.crypto.setFailure(CircleCryptoError.notOpenable("scripted"))
    let item = CircleOpenFixtures.encryptedItem(0)

    _ = await harness.opener.open(item, circle: item.circle)
    let second = await harness.opener.open(item, circle: item.circle)

    guard case .unverifiable = second else {
      Issue.record("expected .unverifiable, got \(second)")
      return
    }
    #expect(await harness.crypto.openCalls.count == 1)
    #expect(await harness.epochs.calls == 1)
  }

  @Test("Hostile epoch numbers are unverifiable and never trap")
  func hostileEpochNumbersAreUnverifiable() async throws {
    let head = Data(repeating: 0x01, count: 32)
    for number in ["-9223372036854775808", "1e30", "-1", "2.5", "true", "\((1 << 40) + 1)", "99999999999999999999"] {
      #expect(RepoAuthorEpochResolver.parse(epochJSON(number: number, head: head)) == nil, "\(number)")
    }
    #expect(RepoAuthorEpochResolver.parse(epochJSON(number: "\(1 << 40)", head: head))?.number == 1 << 40)
    #expect(RepoAuthorEpochResolver.parse(epochJSON(number: "0", head: head))?.number == 0)

    for number in ["-9223372036854775808", "1e30"] {
      let resolver = RepoAuthorEpochResolver { _, rkey in
        rkey == "self" ? epochJSON(number: number, head: head) : nil
      }
      let harness = OpenerHarness(resolver: resolver)
      try await harness.holdKeys([1])
      let opened = await harness.opener.open(CircleOpenFixtures.encryptedItem(0), circle: CircleOpenFixtures.circle)
      guard case .unverifiable = opened else {
        Issue.record("expected .unverifiable for epochNumber \(number), got \(opened)")
        continue
      }
      #expect(await harness.crypto.openCalls.isEmpty)
    }
  }

  @Test("A memoized open re-synthesizes the view from the current envelope")
  func memoReflectsCurrentEnvelopeCounts() async throws {
    let harness = OpenerHarness()
    try await harness.holdKeys([1])

    let first = await harness.opener.open(CircleOpenFixtures.encryptedItem(0), circle: CircleOpenFixtures.circle)
    #expect(likeCount(first) == 3)

    let later = CircleOpenFixtures.encryptedItem(0, likeCount: 10)
    let second = await harness.opener.open(later, circle: CircleOpenFixtures.circle)

    #expect(likeCount(second) == 10)
    #expect(await harness.crypto.openCalls.count == 1)
  }

  @Test("An envelope opened in Circle A and presented under Circle B never yields the memoized post")
  func memoNeverCrossesCircles() async throws {
    let harness = OpenerHarness()
    try await harness.holdKeys([1])
    let item = CircleOpenFixtures.encryptedItem(0)
    guard case .post(_, let media) = await harness.opener.open(item, circle: CircleOpenFixtures.circle),
          let cid = media.first?.cid else {
      Issue.record("expected the post to open in Circle A")
      return
    }

    let otherSpace = try SpaceRef(uriString: "at://did:plc:mallory/space/blue.catbird.circle.encrypted/3evil")
    let circleB = BlueCatbirdCircleDefs.CircleSummary(
      uri: otherSpace, circleId: try TID(tidString: "3l7othercircl"), name: "B",
      owner: try DID(didString: "did:plc:mallory"), memberCount: 2, muted: nil, latestKeyVersion: 1
    )
    let underB = await harness.opener.open(item, circle: circleB)
    guard case .unverifiable = underB else {
      Issue.record("expected .unverifiable under Circle B, got \(underB)")
      return
    }

    // Even a Circle reusing A's circleId in another Space misses the memo.
    let impostor = BlueCatbirdCircleDefs.CircleSummary(
      uri: otherSpace, circleId: CircleOpenFixtures.circle.circleId, name: "Impostor",
      owner: try DID(didString: "did:plc:mallory"), memberCount: 2, muted: nil, latestKeyVersion: 1
    )
    let underImpostor = await harness.opener.open(item, circle: impostor)
    #expect(underImpostor.feedViewPost == nil)

    #expect(await harness.mediaLoader.registeredKey(
      accountDID: CircleOpenFixtures.accountDID, space: otherSpace, authorDID: CircleOpenFixtures.author, cid: cid
    ) == nil)
    #expect(await harness.crypto.openCalls.count == 1)
  }
}

extension CircleFeedModelTests {
  @Test("Without an opener yet, encrypted items stay unopened (Opening…), not unverifiable")
  func feedModelWithoutOpenerLeavesItemsOpening() async throws {
    let item = CircleOpenFixtures.encryptedItem(0)
    let model = CircleFeedModel(
      service: CircleService(transport: MockCircleTransport(feedItems: [item])),
      space: CircleOpenFixtures.spaceURI,
      accountDID: CircleOpenFixtures.accountDID,
      cache: CircleFeedCache(),
      openerProvider: { nil }
    )

    try await model.load()

    #expect(model.items.count == 1)
    #expect(model.opened[CircleOpenFixtures.postURI(0)] == nil)
  }

  @Test("Reloading a page shows the envelope's current counts for an already-opened post")
  func feedModelReloadPicksUpNewCounts() async throws {
    let harness = OpenerHarness()
    try await harness.holdKeys([1])
    let transport = MockCircleTransport(feedItems: [CircleOpenFixtures.encryptedItem(0)])
    let opener = harness.opener
    let model = CircleFeedModel(
      service: CircleService(transport: transport),
      space: CircleOpenFixtures.spaceURI,
      accountDID: CircleOpenFixtures.accountDID,
      cache: harness.cache,
      openerProvider: { opener }
    )
    try await model.load()
    #expect(model.opened[CircleOpenFixtures.postURI(0)].flatMap(likeCount) == 3)

    await transport.setFeedItems([CircleOpenFixtures.encryptedItem(0, likeCount: 11)], cursor: nil)
    try await model.load()

    #expect(model.opened[CircleOpenFixtures.postURI(0)].flatMap(likeCount) == 11)
    #expect(await harness.crypto.openCalls.count == 1)
  }
}
