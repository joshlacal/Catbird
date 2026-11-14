//
//  CrossLanguageFixtureTests.swift
//  CatbirdTests
//
//  Swift consumes the records `catbird-mls` emits (E2EE Circles Task 18 B,
//  refreshed in fix wave 2). The fixtures are byte-exact copies of
//  catbird-mls/tests/fixtures/rust_*.json (see Fixtures/CrossLanguage/README.md).
//  The opener-guard tests run against scripted crypto that returns the
//  manifest's payload; the "real FFI" tests call the local CatbirdMLS
//  xcframework through `FFICircleCrypto` (no network, no enrollment).
//

import CatbirdMLS
import CatbirdMLSCore
import Foundation
import Petrel
import PetrelCatbird
import Testing
@testable import Catbird

// MARK: - Fixture loading

private final class CrossLanguageBundleToken {}

enum CrossLanguageFixtures {
  static let directory = "Fixtures/CrossLanguage"

  /// The test bundle's copy, falling back to the source tree (the simulator
  /// can read host paths) if the synchronized group did not copy it.
  static func data(_ name: String) throws -> Data {
    let bundle = Bundle(for: CrossLanguageBundleToken.self)
    if let url = bundle.url(forResource: name, withExtension: "json")
      ?? bundle.url(forResource: name, withExtension: "json", subdirectory: directory)
      ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "CrossLanguage") {
      return try Data(contentsOf: url)
    }
    let source = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent(directory)
      .appendingPathComponent("\(name).json")
    return try Data(contentsOf: source)
  }

  /// The JSON value exactly as Rust serialized it: the file minus the
  /// trailing newline the fixture writer appends (outside the JSON value, so
  /// never part of a response slice).
  static func record(_ name: String) throws -> Data {
    var bytes = try data(name)
    while let last = bytes.last, [0x0A, 0x0D, 0x20, 0x09].contains(last) { bytes.removeLast() }
    return bytes
  }

  static func keyRecord() throws -> Data { try record("rust_circle_key_record") }
  static func postRecord() throws -> Data { try record("rust_circle_post_record") }
  static func mailboxKeys() throws -> Data { try record("rust_author_mailbox_keys") }

  struct Manifest: Decodable {
    let author_did: String
    let circle_id: String
    let circle_key_hex: String
    let expected_text: String
    let key_version: Int
    let owner_did: String
    let owner_epoch_head_hex: String
    let post_key_hex: String
    let post_uri: String
    let recipient_did: String
    let space_uri: String
  }

  static func manifest() throws -> Manifest {
    try JSONDecoder().decode(Manifest.self, from: data("rust_cross_language_manifest_TEST_ONLY"))
  }

  static func hex(_ string: String) -> Data {
    var bytes: [UInt8] = []
    var index = string.startIndex
    while index < string.endIndex {
      let next = string.index(index, offsetBy: 2)
      bytes.append(UInt8(string[index..<next], radix: 16)!)
      index = next
    }
    return Data(bytes)
  }

  /// The regenerated fixtures carry the real Space URI form
  /// (`at://<did>/space/<type>/<skey>`), parsed as is.
  static func spaceRef(_ manifest: Manifest) throws -> SpaceRef {
    let space = try SpaceRef(uriString: manifest.space_uri)
    #expect(space.uriString() == manifest.space_uri)
    return space
  }

  /// `body` with `fixture` spliced in verbatim at `{{FIXTURE}}`.
  static func wrap(_ fixture: Data, in body: String) -> Data {
    let parts = body.components(separatedBy: "{{FIXTURE}}")
    precondition(parts.count == 2)
    return Data(parts[0].utf8) + fixture + Data(parts[1].utf8)
  }
}

// MARK: - Tests

@Suite("Cross-language Circle fixtures (Rust → Swift)", .serialized)
struct CrossLanguageFixtureTests {
  typealias F = CrossLanguageFixtures

  // (1) RawJSON slices each fixture byte-exactly out of a synthetic response.

  @Test("getKeys: the raw keys[0].record slice equals the Rust key record byte for byte")
  func keyRecordSliceIsByteExact() throws {
    let fixture = try F.keyRecord()
    let body = F.wrap(fixture, in: """
      {"keys": [ {"uri":"at://did:plc:owner/blue.catbird.circle.key/000003","cid":"bafyreigkbxzmswvbita5b7zp6pepsz75yhpj54geciftojsbm4a3kgowde","keyVersion":3,
        "record": {{FIXTURE}} } ], "latestKeyVersion": 3}
      """)
    let response = try CircleKeysResponse(responseBody: body)
    #expect(response.entries.count == 1)
    #expect(response.latestKeyVersion == 3)
    let entry = try #require(response.entries.first)
    #expect(Data(entry.recordJSON.utf8) == fixture)
    #expect(entry.keyVersion == 3)
  }

  @Test("getRecord: the raw value slice equals the Rust post record and mailboxKeys record byte for byte")
  func valueSlicesAreByteExact() throws {
    for fixture in [try F.postRecord(), try F.mailboxKeys()] {
      let body = F.wrap(fixture, in: #"{"uri":"at://did:plc:owner/x.y.z/self","cid":"bafyreigkbxzmswvbita5b7zp6pepsz75yhpj54geciftojsbm4a3kgowde","value":{{FIXTURE}}}"#)
      #expect(RawJSON.member("value", in: body) == fixture)
      #expect(try RepoAuthorEpochResolver.recordValueJSON(statusCode: 200, body: body).map { Data($0.utf8) } == fixture)
    }
  }

  // (2) Typed decode succeeds; Petrel's re-encode is NOT the Rust bytes
  // (the positive control for passing raw bytes to the FFI).

  @Test("The key record decodes typed, and Petrel's re-encode differs from the raw bytes")
  func keyRecordTypedDecodeAndReencodeDiffers() throws {
    let fixture = try F.keyRecord()
    let manifest = try F.manifest()
    let record = try JSONDecoder().decode(BlueCatbirdCircleKey.self, from: fixture)
    #expect(record.circleId.description == manifest.circle_id)
    #expect(record.keyVersion == manifest.key_version)
    #expect(record.recipients.count == 8)
    let reencoded = try JSONEncoder().encode(record)
    #expect(reencoded != fixture, "if this ever matches, re-encoding would be safe; it is not today")
  }

  @Test("The post record decodes typed, and Petrel's re-encode differs from the raw bytes")
  func postRecordTypedDecodeAndReencodeDiffers() throws {
    let fixture = try F.postRecord()
    let manifest = try F.manifest()
    let record = try JSONDecoder().decode(BlueCatbirdCirclePost.self, from: fixture)
    #expect(record.circleId.description == manifest.circle_id)
    #expect(record.keyVersion == manifest.key_version)
    #expect(record.authorEpochHead.data == F.hex(manifest.owner_epoch_head_hex))
    #expect(record.reply != nil)
    #expect(record.createdAt.iso8601String.hasPrefix("2026-11-07T12:05:00"))
    let reencoded = try JSONEncoder().encode(record)
    #expect(reencoded != fixture)
  }

  // (3) CirclePostOpener's guard path, scripted crypto.

  private static func openerInputs() throws -> (
    manifest: F.Manifest, record: BlueCatbirdCirclePost, circle: CircleSummary, author: AppBskyActorDefs.ProfileViewBasic
  ) {
    let manifest = try F.manifest()
    let record = try JSONDecoder().decode(BlueCatbirdCirclePost.self, from: F.postRecord())
    let circle = BlueCatbirdCircleDefs.CircleSummary(
      uri: try F.spaceRef(manifest),
      circleId: try TID(tidString: manifest.circle_id),
      name: "Cross-language",
      owner: try DID(didString: manifest.owner_did),
      memberCount: 2,
      muted: nil,
      latestKeyVersion: manifest.key_version
    )
    let author = AppBskyActorDefs.ProfileViewBasic(
      did: try DID(didString: manifest.author_did),
      handle: try Handle(handleString: "owner.test"),
      displayName: "Owner",
      pronouns: nil, avatar: nil, associated: nil, viewer: nil, labels: nil,
      createdAt: nil, verification: nil, status: nil, debug: nil
    )
    return (manifest, record, circle, author)
  }

  private static func item(
    uri: ATProtocolURI, record: BlueCatbirdCirclePost, author: AppBskyActorDefs.ProfileViewBasic, circle: CircleSummary
  ) -> BlueCatbirdCircleDefs.FeedItem {
    let view = BlueCatbirdCircleDefs.EncryptedPostView(
      uri: uri,
      cid: CIDString(CID.fromDAGCBOR(Data("cross-language-post".utf8))),
      author: author,
      record: record,
      indexedAt: ATProtocolDate(date: Date()),
      likeCount: 0,
      replyCount: 0,
      viewer: nil
    )
    // What the AppView served for this post: the Rust fixture's exact bytes.
    if let served = try? F.postRecord() {
      CircleRawRecordCache.shared.register(raw: served, uri: uri, cid: view.cid)
    }
    return BlueCatbirdCircleDefs.FeedItem(post: .init(view), circle: circle)
  }

  /// A resolver over the Rust mailboxKeys fixture: `self` is the only record.
  private static func fixtureResolver() throws -> RepoAuthorEpochResolver {
    let mailbox = String(decoding: try F.mailboxKeys(), as: UTF8.self)
    return RepoAuthorEpochResolver { _, rkey in rkey == "self" ? mailbox : nil }
  }

  private static func payload(text: String, createdAt: String = "2026-11-07T12:05:00.000Z") -> String {
    "{\"created_at\":\"\(createdAt)\",\"media\":[],\"post\":{\"$type\":\"app.bsky.feed.post\",\"createdAt\":\"\(createdAt)\",\"langs\":[],\"text\":\"\(text)\"}}"
  }

  /// The manifest's post URI. Since the regeneration its rkey is a TID, so
  /// it is the canonical form the AAD binds (Task 18 concern 1 is closed).
  private static func canonicalPostURI(_ manifest: F.Manifest) throws -> (uri: ATProtocolURI, manifestIsCanonical: Bool) {
    let rkey = String(manifest.post_uri.split(separator: "/").last ?? "")
    return (try ATProtocolURI(uriString: manifest.post_uri), (try? TID(tidString: rkey)) != nil)
  }

  @Test("The opener accepts the Rust post record under the manifest's Circle and Space")
  func openerAcceptsUnderManifestCircle() async throws {
    let (manifest, record, circle, author) = try Self.openerInputs()
    let harness = OpenerHarness(resolver: try Self.fixtureResolver())
    let circleKey = F.hex(manifest.circle_key_hex)
    try await harness.store.store(
      spaceURI: circle.uri.uriString(), keyVersion: UInt64(manifest.key_version),
      circleKey: circleKey, createdAt: Date(), reason: "created"
    )
    await harness.crypto.setDefaultPayload(Self.payload(text: manifest.expected_text))
    let (uri, _) = try Self.canonicalPostURI(manifest)

    let opened = await harness.opener.open(Self.item(uri: uri, record: record, author: author, circle: circle), circle: circle)

    guard case .post(let feedViewPost, let media) = opened,
          case .knownType(let value) = feedViewPost.post.record,
          let post = value as? AppBskyFeedPost
    else {
      Issue.record("expected .post, got \(opened)")
      return
    }
    #expect(post.text == manifest.expected_text)
    #expect(media.isEmpty)
    let calls = await harness.crypto.openCalls
    #expect(calls.count == 1)
    let call = try #require(calls.first)
    #expect(call.circleKey == circleKey)
    #expect(call.authorDID == manifest.author_did)
    #expect(call.postURI == uri.uriString())
    // The FFI receives the author epoch and the post record exactly as the Rust side wrote them.
    #expect(Data(call.authorEpochJSON.utf8) == (try F.mailboxKeys()))
    #expect(Data(call.recordJSON.utf8) == (try F.postRecord()))
  }

  @Test("The opener rejects the same record under a different Space or Circle without calling the FFI")
  func openerRejectsUnderDifferentSpace() async throws {
    let (manifest, record, circle, author) = try Self.openerInputs()
    let harness = OpenerHarness(resolver: try Self.fixtureResolver())
    try await harness.store.store(
      spaceURI: circle.uri.uriString(), keyVersion: UInt64(manifest.key_version),
      circleKey: F.hex(manifest.circle_key_hex), createdAt: Date(), reason: "created"
    )
    await harness.crypto.setDefaultPayload(Self.payload(text: manifest.expected_text))
    let (uri, _) = try Self.canonicalPostURI(manifest)

    // Same circleId, other Space: no key is held there.
    let otherSpace = BlueCatbirdCircleDefs.CircleSummary(
      uri: try SpaceRef(spaceDID: manifest.owner_did, spaceType: "blue.catbird.circle.encrypted", skey: "3kother"),
      circleId: circle.circleId, name: "Other", owner: circle.owner, memberCount: 2, muted: nil,
      latestKeyVersion: manifest.key_version
    )
    let underOtherSpace = await harness.opener.open(
      Self.item(uri: uri, record: record, author: author, circle: otherSpace), circle: otherSpace
    )
    if case .post = underOtherSpace { Issue.record("opened under a Space holding no key") }

    // Other Space and other circleId: the header guard rejects it outright.
    let otherCircle = BlueCatbirdCircleDefs.CircleSummary(
      uri: otherSpace.uri, circleId: try TID(tidString: "3kothercirc22"), name: "Other", owner: circle.owner,
      memberCount: 2, muted: nil, latestKeyVersion: manifest.key_version
    )
    let underOtherCircle = await harness.opener.open(
      Self.item(uri: uri, record: record, author: author, circle: otherCircle), circle: otherCircle
    )
    guard case .unverifiable = underOtherCircle else {
      Issue.record("expected .unverifiable, got \(underOtherCircle)")
      return
    }
    #expect(await harness.crypto.openCalls.isEmpty)
  }

  @Test("The regenerated manifest's post URI is canonical (TID rkey), so the opener reaches the FFI")
  func manifestPostURIIsCanonical() throws {
    let manifest = try F.manifest()
    let (uri, canonical) = try Self.canonicalPostURI(manifest)
    #expect(canonical)
    #expect(uri.uriString().hasPrefix("at://\(manifest.author_did)/blue.catbird.circle.post/"))
  }

  // (4) AuthorEpochResolver's parser and walk accept the mailboxKeys fixture.

  @Test("The epoch parser extracts epochNumber and epochHead from the Rust mailboxKeys record")
  func epochParserAcceptsMailboxKeys() async throws {
    let manifest = try F.manifest()
    let mailbox = String(decoding: try F.mailboxKeys(), as: UTF8.self)
    let parsed = try #require(RepoAuthorEpochResolver.parse(mailbox))
    #expect(parsed.number == 0)
    #expect(parsed.head == F.hex(manifest.owner_epoch_head_hex))

    let resolver = try Self.fixtureResolver()
    let json = try await resolver.epochJSON(
      did: try DID(didString: manifest.owner_did), epochHead: F.hex(manifest.owner_epoch_head_hex)
    )
    #expect(json == mailbox)
  }
}

extension OpenScriptedCrypto {
  func setDefaultPayload(_ value: String?) { defaultPayload = value }
}

// MARK: - Real FFI (local CatbirdMLS xcframework)

private final class FixtureKeyStore: PlatformKeyStore, @unchecked Sendable {
  private let lock = NSLock()
  private var dbKeys: [String: Data] = [:]
  private var keypairs: [String: Data] = [:]

  func loadOrCreateDbKey(accountDidHash: String) throws -> Data {
    lock.withLock {
      if let key = dbKeys[accountDidHash] { return key }
      let key = Data((0..<32).map { UInt8(($0 &* 29 &+ 7) & 0xff) })
      dbKeys[accountDidHash] = key
      return key
    }
  }
  func loadSignatureKeypair(keyId: String) throws -> Data? { lock.withLock { keypairs[keyId] } }
  func storeSignatureKeypair(keyId: String, keypairBytes: Data) throws { lock.withLock { keypairs[keyId] = keypairBytes } }
  func deleteAccountKeys(accountDidHash: String) throws { lock.withLock { dbKeys[accountDidHash] = nil } }
  func loadCachedChatDpopToken(accountDidHash: String) throws -> String? { nil }
  func storeCachedChatDpopToken(accountDidHash: String, token: String, expiresAtMs: Int64) throws {}
}

/// Every request fails closed: nothing in these tests may reach a network.
private final class FixtureOfflineTransport: PlatformTransport, @unchecked Sendable {
  func executeHttp(request _: PlatformHttpRequest) throws -> PlatformHttpResponse {
    PlatformHttpResponse(status: 503, headers: [], body: Data("{}".utf8))
  }
  func connectRealtimeStream(homeDsEndpoint _: String, cursorSeq _: Int64?) throws {}
  func disconnectRealtimeStream() throws {}
}

/// A real, UNENROLLED coordinator for the fixture's recipient (`alice`) in a
/// throwaway storage root. Enough for the stateless Circle calls and for the
/// FFI's checks that run before a Labyrinth session; not enough to open a
/// wrap or a post: that needs an enrolled session (mailbox keys, a directory
/// to attest the author's epoch), which only the Labyrinth E2E harness's mock
/// Space server can provide. The same limit is recorded in
/// CatbirdMLSCore's `CircleCryptoTests`.
@MainActor
private struct RealFFI {
  let coordinator: MLSClientCoordinator
  let root: URL
  let crypto: any CircleCrypto

  init(accountDID: String) throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CatbirdCrossLanguageFFI-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    coordinator = try MLSClientCoordinator(
      config: CatbirdMlsClientConfig(
        storageRoot: root.path,
        accountDid: accountDID,
        deviceId: UUID().uuidString.lowercased(),
        homeDsDid: "did:web:chat.catbird.blue",
        homeDsEndpoint: "https://chat.catbird.blue",
        pdsEndpoint: "https://pds.catbird.blue"
      ),
      keystore: FixtureKeyStore(),
      transport: FixtureOfflineTransport()
    )
    crypto = coordinator.circleCrypto()
  }

  func trash() {
    let fm = FileManager.default
    let trash = fm.temporaryDirectory.appendingPathComponent("_trash-CatbirdCrossLanguageFFI", isDirectory: true)
    try? fm.createDirectory(at: trash, withIntermediateDirectories: true)
    try? fm.moveItem(at: root, to: trash.appendingPathComponent(root.lastPathComponent))
  }
}

/// `getKeys` serving the Rust key record fixture verbatim.
private actor FixtureKeyTransport: CircleTransport {
  let publicEndpointCallCount: Int = 0
  let body: Data
  init(body: Data) { self.body = body }

  func getKeys(space: SpaceRef, sinceVersion: Int?) async throws -> CircleKeysResponse {
    try CircleKeysResponse(responseBody: body)
  }
  func capabilities() async throws -> CircleCapability {
    CircleCapability(enabled: true, protocolRevision: CircleConfiguration.protocolRevision, supportsImages: true)
  }
  func listCircles(cursor: String?) async throws -> CircleListPage { CircleListPage(circles: [], cursor: nil) }
  func getFeed(space: SpaceRef?, cursor: String?) async throws -> CircleFeedPage { CircleFeedPage(items: [], cursor: nil) }
  func getPostThread(uri: ATProtocolURI, space: SpaceRef) async throws -> CircleThreadPage { throw CircleError.invalidResponse }
  func listNotifications(cursor: String?) async throws -> CircleNotificationPage { CircleNotificationPage(notifications: [], cursor: nil) }
  func media(space: SpaceRef, authorDID: DID, cid: CID) async throws -> Data { Data() }
  func updatePreferences(space: SpaceRef, muted: Bool) async throws -> Bool { muted }
  func report(post: ATProtocolURI, circle: CircleSummary, reason: CircleReportReason, details: String?) async throws -> UUID { UUID() }
  func activateCircle(space: SpaceRef) async throws -> CircleSummary { throw CircleError.invalidResponse }
  func publishPost(destination: CircleSummary, draft: CirclePostDraft) async throws -> ATProtocolURI { throw CircleError.invalidResponse }
  func like(post: AppBskyFeedDefs.PostView, circle: CircleSummary) async throws -> ATProtocolURI { throw CircleError.invalidResponse }
  func deletePost(uri: ATProtocolURI, circle: CircleSummary) async throws {}
  func deleteLike(uri: ATProtocolURI, circle: CircleSummary) async throws {}
  func createSpace(skey: String, circleId: String, name: String, memberDIDs: [DID]) async throws -> CircleSummary { throw CircleError.invalidResponse }
  func deleteSpace(space: SpaceRef) async throws {}
  func addMember(space: SpaceRef, did: DID) async throws {}
  func removeMember(space: SpaceRef, did: DID) async throws {}
  func listMembers(space: SpaceRef) async throws -> [CircleMember] { [] }
}

@Suite("Cross-language Circle fixtures through the real FFI", .serialized)
@MainActor
struct CrossLanguageRealFFITests {
  typealias F = CrossLanguageFixtures

  @Test("Real FFI: Swift derives the same per-post key as Rust for the fixture post")
  func realFFIPostKeyMatchesRust() throws {
    let manifest = try F.manifest()
    let ffi = try RealFFI(accountDID: manifest.recipient_did)
    defer { ffi.trash() }

    let postKey = try ffi.crypto.postKey(
      circleKey: F.hex(manifest.circle_key_hex), circleID: manifest.circle_id, postURI: manifest.post_uri
    )

    #expect(postKey == F.hex(manifest.post_key_hex))
  }

  @Test("Real FFI: the fixture key record's owner/Space pair passes Rust's authority check and reaches the session step")
  func realFFIKeyOpenReachesSession() async throws {
    let manifest = try F.manifest()
    let ffi = try RealFFI(accountDID: manifest.recipient_did)
    defer { ffi.trash() }
    let record = String(decoding: try F.keyRecord(), as: UTF8.self)

    // A bogus owner is refused before any session (positive control).
    do {
      _ = try await ffi.crypto.openCircleKey(
        recordJSON: record, spaceURI: manifest.space_uri, ownerDID: manifest.recipient_did
      )
      Issue.record("a non-authority owner must be refused")
    } catch let error as CircleCryptoError {
      guard case .untrusted = error else { Issue.record("expected .untrusted, got \(error)"); return }
      #expect(CircleOpenFailure(error) == .ownerMismatch)
    }

    // The real owner passes Rust's authority check; the unenrolled client
    // then stops at the session (transient), never at a trust verdict.
    do {
      let opened = try await ffi.crypto.openCircleKey(
        recordJSON: record, spaceURI: manifest.space_uri, ownerDID: manifest.owner_did
      )
      Issue.record("an unenrolled client cannot open a wrap; got \(String(describing: opened))")
    } catch let error as CircleCryptoError {
      guard case .unavailable = error else { Issue.record("expected .unavailable, got \(error)"); return }
    }
  }

  @Test("Real FFI: CircleKeyManager hands the FFI the served key record; the unenrolled session aborts the sync, nothing stored")
  func realFFIKeySyncThroughManager() async throws {
    let manifest = try F.manifest()
    let ffi = try RealFFI(accountDID: manifest.recipient_did)
    defer { ffi.trash() }
    let body = F.wrap(try F.keyRecord(), in: """
      {"keys":[{"uri":"at://\(manifest.owner_did)/blue.catbird.circle.key/000003",\
      "cid":"bafyreigkbxzmswvbita5b7zp6pepsz75yhpj54geciftojsbm4a3kgowde","keyVersion":3,"record":{{FIXTURE}}}],\
      "latestKeyVersion":3}
      """)
    let store = CircleKeyStore(accountDID: manifest.recipient_did, keychain: InMemoryCircleKeychain())
    let manager = CircleKeyManager(
      crypto: ffi.crypto, store: store, transport: FixtureKeyTransport(body: body),
      ownerDID: try DID(didString: manifest.recipient_did)
    )
    let circle = BlueCatbirdCircleDefs.CircleSummary(
      uri: try F.spaceRef(manifest), circleId: try TID(tidString: manifest.circle_id), name: "Cross-language",
      owner: try DID(didString: manifest.owner_did), memberCount: 2, muted: nil, latestKeyVersion: manifest.key_version
    )

    do {
      _ = try await manager.refreshKeys(circle: circle)
      Issue.record("an unenrolled client cannot open the wrap")
    } catch {
      #expect(CircleOpenFailure(error) == .transient, "got \(error)")
      #expect(CircleService.postingKeyError(error) == .keysTemporarilyUnavailable)
    }
    #expect(try await store.latestVersion(spaceURI: circle.uri.uriString()) == nil)
  }

  @Test("Real FFI: the opener hands the FFI the served post record; an unenrolled session is Waiting…, not unverifiable")
  func realFFIPostOpenThroughOpener() async throws {
    let manifest = try F.manifest()
    let ffi = try RealFFI(accountDID: manifest.recipient_did)
    defer { ffi.trash() }
    let record = try JSONDecoder().decode(BlueCatbirdCirclePost.self, from: F.postRecord())
    let circle = BlueCatbirdCircleDefs.CircleSummary(
      uri: try F.spaceRef(manifest), circleId: try TID(tidString: manifest.circle_id), name: "Cross-language",
      owner: try DID(didString: manifest.owner_did), memberCount: 2, muted: nil, latestKeyVersion: manifest.key_version
    )
    let store = CircleKeyStore(accountDID: manifest.recipient_did, keychain: InMemoryCircleKeychain())
    try await store.store(
      spaceURI: circle.uri.uriString(), keyVersion: UInt64(manifest.key_version),
      circleKey: F.hex(manifest.circle_key_hex), createdAt: Date(), reason: "created"
    )
    let keys = CircleKeyManager(
      crypto: ffi.crypto, store: store, transport: FixtureKeyTransport(body: Data("{}".utf8)),
      ownerDID: try DID(didString: manifest.recipient_did)
    )
    let mailbox = String(decoding: try F.mailboxKeys(), as: UTF8.self)
    let opener = CirclePostOpener(
      crypto: ffi.crypto, keys: keys,
      epochs: RepoAuthorEpochResolver { _, rkey in rkey == "self" ? mailbox : nil },
      accountDID: manifest.recipient_did, cache: CircleFeedCache(), mediaLoader: nil
    )
    let author = AppBskyActorDefs.ProfileViewBasic(
      did: try DID(didString: manifest.author_did), handle: try Handle(handleString: "owner.test"),
      displayName: nil, pronouns: nil, avatar: nil, associated: nil, viewer: nil, labels: nil,
      createdAt: nil, verification: nil, status: nil, debug: nil
    )
    let uri = try ATProtocolURI(uriString: manifest.post_uri)
    let cid = CID.fromDAGCBOR(Data("real-ffi-post".utf8))
    CircleRawRecordCache.shared.register(raw: try F.postRecord(), uri: uri, cid: cid)
    let view = BlueCatbirdCircleDefs.EncryptedPostView(
      uri: uri, cid: CIDString(cid), author: author, record: record, indexedAt: ATProtocolDate(date: Date()),
      likeCount: 0, replyCount: 0, viewer: nil
    )

    let opened = await opener.open(BlueCatbirdCircleDefs.FeedItem(post: .init(view), circle: circle), circle: circle)

    guard case .retryLater = opened else {
      Issue.record("expected .retryLater from the unenrolled session, got \(opened)")
      return
    }
  }
}
