//
//  CircleFixWave2Tests.swift
//  CatbirdTests
//
//  E2EE Circles Catbird fix wave 2: typed open-failure classes in the opener
//  (I3), the raw-bytes contract on the read path, and one key store per
//  account DID (I5). Scripted crypto, fetches and keychains only.
//

import CatbirdMLSCore
import Foundation
import Petrel
import PetrelCatbird
import Security
import Testing
@testable import Catbird

// MARK: - Doubles

/// A keychain whose reads fail (the Keychain before first unlock).
private final class LockedCircleKeychain: CircleKeychain, @unchecked Sendable {
  func read(service: String, account: String) throws -> Data? {
    throw CircleKeychainError.status(errSecInteractionNotAllowed)
  }
  func write(service: String, account: String, data: Data, accessibility: String) throws {
    throw CircleKeychainError.status(errSecInteractionNotAllowed)
  }
  func delete(service: String, account: String) throws {}
  func accounts(service: String) throws -> [String] { [] }
}

/// A resolver that is offline.
private actor OfflineAuthorEpochResolver: AuthorEpochResolver {
  func epochJSON(did: DID, epochHead: Data) async throws -> String { throw URLError(.notConnectedToInternet) }
}

/// An in-memory keychain whose FIRST read, once armed, returns its snapshot
/// only after another write lands (or a timeout): it forces two
/// load-modify-write cycles on two store actors to interleave.
private final class InterleavingCircleKeychain: CircleKeychain, @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String: Data] = [:]
  private var armed = false
  private let otherWrote = DispatchSemaphore(value: 0)

  func arm() { lock.withLock { armed = true } }

  func read(service: String, account: String) throws -> Data? {
    let (snapshot, gate) = lock.withLock { () -> (Data?, Bool) in
      let gate = armed
      armed = false
      return (items[account], gate)
    }
    if gate { _ = otherWrote.wait(timeout: .now() + 1.0) }
    return snapshot
  }

  func write(service: String, account: String, data: Data, accessibility: String) throws {
    lock.withLock { items[account] = data }
    otherWrote.signal()
  }

  func delete(service: String, account: String) throws { lock.withLock { items[account] = nil } }
  func accounts(service: String) throws -> [String] { lock.withLock { Array(items.keys) } }
}

private enum Wave2 {
  typealias F = CircleOpenFixtures

  static let keyOwner = try! DID(didString: "did:plc:alice")
  static let keySpaceRef = try! SpaceRef(uriString: "at://did:plc:alice/space/blue.catbird.circle.encrypted/3enc")
  static let keySpace = keySpaceRef.uriString()
  static let keyCircle = BlueCatbirdCircleDefs.CircleSummary(
    uri: keySpaceRef, circleId: try! TID(tidString: "3l7familycirc"), name: "Close", owner: keyOwner,
    memberCount: 2, muted: nil
  )

  static let impostorSpace = try! SpaceRef(uriString: "at://did:plc:owner/space/blue.catbird.circle.encrypted/3impostor")

  /// Same circleId as the real Circle, another Space (a migrated Circle's
  /// other Space looks like this).
  static let impostor = BlueCatbirdCircleDefs.CircleSummary(
    uri: impostorSpace, circleId: F.circle.circleId, name: "Impostor", owner: F.owner,
    memberCount: 2, muted: nil, latestKeyVersion: 1
  )

  /// A `getFeed` body whose encrypted record carries Petrel-style nested
  /// `$type`s in `reply` and unpadded base64, exactly as a server might serve it.
  static func feedBody(index: Int) -> (body: Data, record: Data) {
    let parent = "at://did:plc:owner/blue.catbird.circle.post/3l7parentaaaa"
    let cid = CID.fromDAGCBOR(Data("raw-\(index)".utf8)).string
    let head = F.authorHead.base64EncodedString().replacingOccurrences(of: "=", with: "")
    let record = """
    {"$type":"blue.catbird.circle.post","circleId":"\(F.circleID)","keyVersion":1,\
    "createdAt":"2026-11-07T12:05:00.000Z","ciphertext":{"$bytes":"AgICAgICAgICAgICAgICAgICAgI"},\
    "sig":{"$bytes":"EREREREREREREREREREREREREREREREREREREREREQ"},"authorEpochHead":{"$bytes":"\(head)"},\
    "reply":{"$type":"app.bsky.feed.post#replyRef","root":{"$type":"com.atproto.repo.strongRef","uri":"\(parent)","cid":"\(cid)"},\
    "parent":{"$type":"com.atproto.repo.strongRef","uri":"\(parent)","cid":"\(cid)"}}}
    """
    let body = """
    {"feed":[{"post":{"$type":"blue.catbird.circle.defs#encryptedPostView","uri":"\(F.postURI(index).uriString())",\
    "cid":"\(cid)","author":{"did":"\(F.author.didString())","handle":"bob.test"},\
    "record": \(record) ,"indexedAt":"2026-11-07T12:05:01.000Z","likeCount":0,"replyCount":0},\
    "circle":{"uri":"\(F.spaceURI.uriString())","circleId":"\(F.circleID)","name":"Close",\
    "owner":"\(F.owner.didString())","memberCount":3,"latestKeyVersion":1}}]}
    """
    return (Data(body.utf8), Data(record.utf8))
  }
}

private func expectState(
  _ item: CircleOpenedItem, _ matches: (CircleOpenedItem) -> Bool, _ name: String,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  if !matches(item) { Issue.record("expected \(name), got \(item)", sourceLocation: sourceLocation) }
}

// MARK: - I3: typed failure classes in the opener

@Suite("Circle fix wave 2", .serialized)
struct CircleFixWave2Tests {
  typealias F = CircleOpenFixtures

  @Test("I3: a Keychain read failure is Unavailable, not unverifiable, and is not memoized")
  func keychainFailureIsUnavailable() async throws {
    let crypto = OpenScriptedCrypto()
    let store = CircleKeyStore(accountDID: F.accountDID, keychain: LockedCircleKeychain())
    let keys = CircleKeyManager(
      crypto: crypto, store: store, transport: OpenerKeyTransport(), ownerDID: try DID(didString: F.accountDID)
    )
    let opener = CirclePostOpener(
      crypto: crypto, keys: keys, epochs: FakeAuthorEpochResolver(), accountDID: F.accountDID,
      cache: CircleFeedCache(), mediaLoader: nil
    )
    let item = F.encryptedItem(0)

    let opened = await opener.open(item, circle: item.circle)

    expectState(opened, { if case .unavailable = $0 { true } else { false } }, ".unavailable")
    #expect(CircleFeedItemRow.statusState(item: item, opened: opened) == .unavailable)
    #expect(CircleEncryptedStatusRow.copy(for: .unavailable, ownerHandle: nil).detail == "Unavailable on this device right now")
    #expect(await crypto.openCalls.isEmpty)
  }

  @Test("I3: an offline author-epoch fetch is Waiting… (retry), not 'Couldn't verify'")
  func offlineResolverIsRetryLater() async throws {
    let harness = OpenerHarness(resolver: OfflineAuthorEpochResolver())
    try await harness.holdKeys([1])
    let item = F.encryptedItem(0)

    let opened = await harness.opener.open(item, circle: item.circle)

    expectState(opened, { if case .retryLater = $0 { true } else { false } }, ".retryLater")
    #expect(CircleFeedItemRow.statusState(item: item, opened: opened) == .waiting)
    #expect(await harness.crypto.openCalls.isEmpty)
  }

  @Test("I3: a transient FFI failure (.unavailable) is retried, never memoized")
  func transientFFIFailureIsNotMemoized() async throws {
    let harness = OpenerHarness()
    try await harness.holdKeys([1])
    await harness.crypto.setFailure(CircleCryptoError.unavailable("session locked"))
    let item = F.encryptedItem(0)

    let first = await harness.opener.open(item, circle: item.circle)
    expectState(first, { if case .retryLater = $0 { true } else { false } }, ".retryLater")

    await harness.crypto.setFailure(nil)
    let second = await harness.opener.open(item, circle: item.circle)

    #expect(second.feedViewPost != nil, "the retry must reach the FFI and open")
    #expect(await harness.crypto.openCalls.count == 2)
  }

  @Test("I3: an untrusted author is unverifiable but retried (warning), never memoized")
  func untrustedFFIFailureIsNotMemoized() async throws {
    let harness = OpenerHarness()
    try await harness.holdKeys([1])
    await harness.crypto.setFailure(CircleCryptoError.untrusted("directory fork"))
    let item = F.encryptedItem(0)

    let first = await harness.opener.open(item, circle: item.circle)
    expectState(first, { if case .unverifiable = $0 { true } else { false } }, ".unverifiable")
    _ = await harness.opener.open(item, circle: item.circle)

    #expect(await harness.crypto.openCalls.count == 2)
  }

  @Test("I3: notOpenable and malformed are memoized for the same inputs")
  func rejectedFailuresAreMemoized() async throws {
    for error in [CircleCryptoError.notOpenable("tag"), .malformed("record")] {
      let harness = OpenerHarness()
      try await harness.holdKeys([1])
      await harness.crypto.setFailure(error)
      let item = F.encryptedItem(0)

      _ = await harness.opener.open(item, circle: item.circle)
      let second = await harness.opener.open(item, circle: item.circle)

      expectState(second, { if case .unverifiable = $0 { true } else { false } }, ".unverifiable")
      #expect(await harness.crypto.openCalls.count == 1, "\(error)")
    }
  }

  @Test("I3: a failure under an impostor Space sharing the circleId does not poison the real Space")
  func failureMemoIsPerSpace() async throws {
    let harness = OpenerHarness()
    try await harness.holdKeys([1])
    try await harness.store.store(
      spaceURI: Wave2.impostorSpace.uriString(), keyVersion: 1, circleKey: F.key(1), createdAt: Date(), reason: "created"
    )
    let item = F.encryptedItem(0)

    await harness.crypto.setFailure(CircleCryptoError.notOpenable("tag"))
    _ = await harness.opener.open(item, circle: Wave2.impostor)
    await harness.crypto.setFailure(nil)
    let real = await harness.opener.open(item, circle: F.circle)

    #expect(real.feedViewPost != nil)
    #expect(await harness.crypto.openCalls.count == 2)
  }

  @Test("I3: a key re-adopted after a failure is a new input (the memo key carries the key fingerprint)")
  func failureMemoIsPerKey() async throws {
    let harness = OpenerHarness()
    try await harness.holdKeys([1])
    let item = F.encryptedItem(0)

    await harness.crypto.setFailure(CircleCryptoError.notOpenable("tag"))
    _ = await harness.opener.open(item, circle: item.circle)
    try await harness.store.store(
      spaceURI: F.spaceURI.uriString(), keyVersion: 1, circleKey: Data(repeating: 0x7E, count: 32),
      createdAt: Date(), reason: "created"
    )
    await harness.crypto.setFailure(nil)
    let reopened = await harness.opener.open(item, circle: item.circle)

    #expect(reopened.feedViewPost != nil)
    #expect(await harness.crypto.openCalls.last?.circleKey == Data(repeating: 0x7E, count: 32))
  }

  // MARK: Raw-bytes contract on the read path

  @Test("Read path: a record with Petrel-style nested $type in reply reaches the FFI byte for byte")
  func feedRecordReachesFFIByteForByte() async throws {
    let (body, record) = Wave2.feedBody(index: 40)
    let raw = CircleRawRecordCache()
    raw.register(feedResponse: body)
    let output = try JSONDecoder().decode(BlueCatbirdCircleGetFeed.Output.self, from: body)
    let item = try #require(output.feed.first)
    // Positive control: Petrel's re-encode of the same record is different bytes.
    guard case .blueCatbirdCircleDefsEncryptedPostView(let view) = item.post else {
      Issue.record("expected an encrypted post view")
      return
    }
    #expect(try JSONEncoder().encode(view.record) != record)

    let harness = OpenerHarness()
    try await harness.holdKeys([1])
    let opener = CirclePostOpener(
      crypto: harness.crypto, keys: harness.keys, epochs: harness.epochs, accountDID: F.accountDID,
      cache: harness.cache, mediaLoader: nil, rawRecords: raw
    )

    let opened = await opener.open(item, circle: item.circle)

    #expect(opened.feedViewPost != nil)
    let call = try #require(await harness.crypto.openCalls.first)
    #expect(Data(call.recordJSON.utf8) == record)
  }

  @Test("Read path: thread nodes (anchor, parent, replies) are sliced byte for byte")
  func threadRecordsAreSlicedByteForByte() throws {
    let (_, record) = Wave2.feedBody(index: 41)
    func node(_ index: Int) -> String {
      """
      {"$type":"app.bsky.feed.defs#threadViewPost","post":{"uri":"\(F.postURI(index).uriString())",\
      "cid":"\(CID.fromDAGCBOR(Data("raw-41".utf8)).string)","author":{"did":"\(F.author.didString())","handle":"bob.test"},\
      "record":\(String(decoding: record, as: UTF8.self)),"indexedAt":"2026-11-07T12:05:01.000Z"}
      """
    }
    let body = Data("""
    {"thread":\(node(41)),"parent":\(node(41))},"replies":[\(node(41))}]},\
    "circle":{"uri":"\(F.spaceURI.uriString())","circleId":"\(F.circleID)","name":"Close","owner":"\(F.owner.didString())","memberCount":3}}
    """.utf8)
    let raw = CircleRawRecordCache()

    raw.register(threadResponse: body)

    let typed = try JSONDecoder().decode(BlueCatbirdCirclePost.self, from: record)
    #expect(raw.record(uri: F.postURI(41), cid: CID.fromDAGCBOR(Data("raw-41".utf8)), envelope: typed) == record)
  }

  @Test("Read path: without the served bytes the opener retries later and never re-encodes")
  func missingRawBytesNeverReencode() async throws {
    let harness = OpenerHarness()
    try await harness.holdKeys([1])
    let opener = CirclePostOpener(
      crypto: harness.crypto, keys: harness.keys, epochs: harness.epochs, accountDID: F.accountDID,
      cache: harness.cache, mediaLoader: nil, rawRecords: CircleRawRecordCache()
    )
    let item = F.encryptedItem(42)

    let opened = await opener.open(item, circle: item.circle)

    expectState(opened, { if case .retryLater = $0 { true } else { false } }, ".retryLater")
    #expect(await harness.crypto.openCalls.isEmpty)
  }

  // MARK: I5: one key store per account DID

  @Test("I5: managers created later for the same DID share one store instance")
  func registrySharesOneStorePerDID() async throws {
    let registry = CircleKeyStoreRegistry()
    var made = 0
    let a = registry.store(accountDID: "did:plc:alice") { made += 1; return InMemoryCircleKeychain() }
    let b = registry.store(accountDID: "did:plc:alice") { made += 1; return InMemoryCircleKeychain() }
    let other = registry.store(accountDID: "did:plc:bob") { made += 1; return InMemoryCircleKeychain() }

    #expect(a === b)
    #expect(a !== other)
    #expect(made == 2)

    // Two managers (e.g. an old coordinator's and a new one's) on that store.
    let first = CircleKeyManager(
      crypto: ScriptedCircleCrypto(), store: a, transport: KeyRecordingCircleTransport(), ownerDID: Wave2.keyOwner
    )
    let second = CircleKeyManager(
      crypto: ScriptedCircleCrypto(), store: b, transport: KeyRecordingCircleTransport(), ownerDID: Wave2.keyOwner
    )
    try await a.setPendingRewrap(
      spaceURI: Wave2.keySpace, did: CircleKeyManager.aclRemovePrefix + "did:plc:mallory",
      reason: CircleKeyManager.aclRemoveReason
    )
    #expect(try await second.pendingRewraps(circle: Wave2.keyCircle).count == 1)
    #expect(try await first.pendingRewraps(circle: Wave2.keyCircle).count == 1)
  }

  @Test("I5: a pending-removal entry survives an interleaved mutation through the shared store")
  func pendingRemovalSurvivesInterleavedMutation() async throws {
    let keychain = InterleavingCircleKeychain()
    let registry = CircleKeyStoreRegistry()
    let oldManagersStore = registry.store(accountDID: "did:plc:alice") { keychain }
    let newManagersStore = registry.store(accountDID: "did:plc:alice") { keychain }
    let removal = CircleKeyManager.aclRemovePrefix + "did:plc:mallory"

    keychain.arm()
    async let first: Void = oldManagersStore.setPendingRewrap(
      spaceURI: Wave2.keySpace, did: removal, reason: CircleKeyManager.aclRemoveReason
    )
    try await Task.sleep(nanoseconds: 50_000_000)
    async let second: Void = newManagersStore.setPendingRewrap(
      spaceURI: Wave2.keySpace, did: "did:plc:carol", reason: "memberEpochRotated"
    )
    _ = try await (first, second)

    let pending = try await newManagersStore.pendingRewraps(spaceURI: Wave2.keySpace).map(\.did)
    #expect(Set(pending) == [removal, "did:plc:carol"])
  }

  @Test("I5 positive control: two separate store actors on one keychain DO lose the entry")
  func separateStoresLoseAnInterleavedEntry() async throws {
    let keychain = InterleavingCircleKeychain()
    let oldStore = CircleKeyStore(accountDID: "did:plc:alice", keychain: keychain)
    let newStore = CircleKeyStore(accountDID: "did:plc:alice", keychain: keychain)
    let removal = CircleKeyManager.aclRemovePrefix + "did:plc:mallory"

    keychain.arm()
    async let first: Void = oldStore.setPendingRewrap(
      spaceURI: Wave2.keySpace, did: removal, reason: CircleKeyManager.aclRemoveReason
    )
    try await Task.sleep(nanoseconds: 50_000_000)
    async let second: Void = newStore.setPendingRewrap(
      spaceURI: Wave2.keySpace, did: "did:plc:carol", reason: "memberEpochRotated"
    )
    _ = try await (first, second)

    let pending = try await newStore.pendingRewraps(spaceURI: Wave2.keySpace).map(\.did)
    #expect(pending.count == 1, "the gate must actually interleave the two load-modify-write cycles")
  }
}
