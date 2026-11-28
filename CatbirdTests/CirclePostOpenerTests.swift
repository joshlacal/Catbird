//
//  CirclePostOpenerTests.swift
//  CatbirdTests
//
//  Opening encrypted Circle posts and media (spec §4.2, §4.5, §6 rule 9;
//  Review Focus 5). Scripted CircleCrypto, an in-memory Keychain, a recording
//  key transport and a fake author-epoch resolver: nothing here touches the
//  real Keychain, network or FFI.
//

import CatbirdMLSCore
import Foundation
import ImageIO
import Petrel
import PetrelCatbird
import Testing
import UniformTypeIdentifiers
@testable import Catbird

// MARK: - Fixtures

enum CircleOpenFixtures {
  static let owner = try! DID(didString: "did:plc:owner")
  static let author = try! DID(didString: "did:plc:bob")
  static let accountDID = "did:plc:reader"
  static let spaceURI = try! SpaceRef(uriString: "at:space/did:plc:owner/blue.catbird.circle.encrypted/3enc")
  static let circleID = "3l7familycirc"
  static let secretText = "only members may read this"
  static let authorHead = Data(repeating: 0x5A, count: 32)

  static let circle = BlueCatbirdCircleDefs.CircleSummary(
    uri: spaceURI,
    circleId: try! TID(tidString: circleID),
    name: "Close",
    owner: owner,
    memberCount: 3,
    muted: nil,
    latestKeyVersion: 1
  )

  static func key(_ version: UInt64) -> Data { Data(repeating: 0x40 &+ UInt8(version), count: 32) }

  /// Valid TIDs: 13 chars from the sortable base32 alphabet.
  static func rkey(_ index: Int) -> String {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
    return "3l7postaaaa\(alphabet[index / 26 % 26])\(alphabet[index % 26])"
  }

  static func postURI(_ index: Int, author: DID = author) -> ATProtocolURI {
    try! ATProtocolURI(uriString: "at://\(author.didString())/blue.catbird.circle.post/\(rkey(index))")
  }

  static let mediaCID = "bafyreigkbxzmswvbita5b7zp6pepsz75yhpj54geciftojsbm4a3kgowde"

  static func payloadJSON(text: String = secretText, withMedia: Bool = true) -> String {
    let media = withMedia
      ? "[{\"alt\":\"a heron\",\"cid\":\"\(mediaCID)\",\"height\":800,\"iv\":[36,36,36,36,36,36,36,36,36,36,36,36],\"key\":[66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66],\"mime_type\":\"image/jpeg\",\"sha256\":\"\(String(repeating: "ab", count: 32))\",\"width\":1200}]"
      : "[]"
    return "{\"created_at\":\"2026-10-26T07:33:20.301Z\",\"media\":\(media),\"post\":{\"$type\":\"app.bsky.feed.post\",\"createdAt\":\"2026-10-26T07:33:20.301Z\",\"langs\":[],\"text\":\"\(text)\"}}"
  }

  static func envelope(keyVersion: Int = 1) -> BlueCatbirdCirclePost {
    BlueCatbirdCirclePost(
      circleId: try! TID(tidString: circleID),
      keyVersion: keyVersion,
      createdAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_793_000_000)),
      ciphertext: Bytes(data: Data(repeating: 0x02, count: 48)),
      sig: Bytes(data: Data(repeating: 0x11, count: 64)),
      authorEpochHead: Bytes(data: authorHead),
      reply: nil,
      attachments: nil
    )
  }

  static let authorProfile = AppBskyActorDefs.ProfileViewBasic(
    did: author,
    handle: try! Handle(handleString: "bob.test"),
    displayName: "Bob",
    pronouns: nil, avatar: nil, associated: nil, viewer: nil, labels: nil,
    createdAt: nil, verification: nil, status: nil, debug: nil
  )

  static func viewer() -> AppBskyFeedDefs.ViewerState {
    AppBskyFeedDefs.ViewerState(
      repost: nil,
      like: try! ATProtocolURI(uriString: "at://did:plc:reader/app.bsky.feed.like/3l7likeaaaaaa"),
      bookmarked: nil, threadMuted: nil, replyDisabled: nil, embeddingDisabled: nil, pinned: nil
    )
  }

  static func encryptedItem(
    _ index: Int, keyVersion: Int = 1, circle: CircleSummary = circle, likeCount: Int = 3
  ) -> BlueCatbirdCircleDefs.FeedItem {
    let record = envelope(keyVersion: keyVersion)
    let cid = CID.fromDAGCBOR(Data("enc-\(index)".utf8))
    CircleRawRecordCache.registerFixture(record, uri: postURI(index), cid: cid)
    let view = BlueCatbirdCircleDefs.EncryptedPostView(
      uri: postURI(index),
      cid: CIDString(cid),
      author: authorProfile,
      record: record,
      indexedAt: ATProtocolDate(date: Date()),
      likeCount: likeCount,
      replyCount: 2,
      viewer: viewer()
    )
    return BlueCatbirdCircleDefs.FeedItem(post: .init(view), circle: circle)
  }

  /// A `getPostThread` node: a plain `PostView` whose record is the envelope.
  static func threadNode(_ index: Int, keyVersion: Int = 1) -> AppBskyFeedDefs.PostView {
    let record = envelope(keyVersion: keyVersion)
    let cid = CID.fromDAGCBOR(Data("enc-\(index)".utf8))
    CircleRawRecordCache.registerFixture(record, uri: postURI(index), cid: cid)
    return AppBskyFeedDefs.PostView(
      uri: postURI(index),
      cid: CIDString(cid),
      author: authorProfile,
      record: .knownType(record),
      embed: nil, bookmarkCount: nil, replyCount: 4, repostCount: nil, likeCount: 7, quoteCount: nil,
      indexedAt: ATProtocolDate(date: Date()), viewer: viewer(), labels: nil, threadgate: nil, debug: nil
    )
  }

  static func keyEntry(version: Int) throws -> BlueCatbirdCircleGetKeys.KeyEntry {
    let headB64 = Data(repeating: 0xA1, count: 32).base64EncodedString()
    let json = """
    {"$type":"blue.catbird.circle.key","circleId":"\(circleID)","keyVersion":\(version),\
    "sender":{"$type":"blue.catbird.labyrinth.mek#labyrinthSender","did":"did:plc:alice","senderEpochHead":{"$bytes":"\(headB64)"},"senderEpoch":{"epochNumber":0,"authPubkey":{"$bytes":"AAEC"},"encryptionPubkey":{"$bytes":"AwQF"},"signingPubkey":{"$bytes":"BgcI"},"membersHash":{"$bytes":"CQoL"},"epochHead":{"$bytes":"\(headB64)"},"selfSig":{"$bytes":"DA0O"},"attestation":{"transportPubkey":{"$bytes":"DxAR"},"sig":{"$bytes":"EhMU"}}}},\
    "recipients":[{"$bytes":"AAEC"}],"reason":"created",\
    "createdAt":"\(ATProtocolDate(date: Date()).iso8601String)"}
    """
    let record = try JSONDecoder().decode(BlueCatbirdCircleKey.self, from: Data(json.utf8))
    return BlueCatbirdCircleGetKeys.KeyEntry(
      uri: try ATProtocolURI(uriString: "at://did:plc:owner/blue.catbird.circle.key/\(String(format: "%06d", version))"),
      cid: CIDString(CID.fromDAGCBOR(Data("open-key-\(version)".utf8))),
      keyVersion: version,
      record: record
    )
  }

  static func jpeg(width: Int = 64, height: Int = 32) throws -> Data {
    let context = try #require(CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
  }
}

// MARK: - Doubles

/// `openPost` returns a scripted payload per post URI (or throws), counting
/// calls and peak concurrency; `openCircleKey` returns scripted keys.
actor OpenScriptedCrypto: CircleCrypto {
  struct OpenCall: Sendable {
    let postURI: String
    let authorDID: String
    let circleKey: Data
    let authorEpochJSON: String
    var recordJSON: String = ""
  }

  private(set) var openCalls: [OpenCall] = []
  private(set) var maxInFlight = 0
  private var inFlight = 0
  var payloads: [String: String] = [:]
  var defaultPayload: String? = CircleOpenFixtures.payloadJSON()
  var failure: (any Error)?
  var holdNanoseconds: UInt64 = 0
  var openable: [UInt64: Data] = [:]

  func setOpenable(_ value: [UInt64: Data]) { openable = value }
  func setFailure(_ error: (any Error)?) { failure = error }
  func setHold(milliseconds: UInt64) { holdNanoseconds = milliseconds * 1_000_000 }

  func generateCircleKey() async throws -> Data { Data(repeating: 1, count: 32) }

  func wrapCircleKey(
    circleID: String, keyVersion: UInt64, spaceURI: String, reason: String,
    memberDIDs: [String], circleKey: Data, createdAt: Date
  ) async throws -> CircleKeyWrapOutcome {
    throw CircleError.invalidResponse
  }

  func openCircleKey(recordJSON: String, spaceURI: String, ownerDID: String) async throws -> OpenedCircleKey? {
    try ScriptedKeyOpen.open(recordJSON: recordJSON, openable: openable)
  }

  func sealPost(
    circleID: String, keyVersion: UInt64, circleKey: Data, postURI: String, authorDID: String,
    createdAt: Date, payloadJSON: String, replyJSON: String?, attachmentsJSON: [String]
  ) async throws -> String { throw CircleError.encryptionUnavailable }

  func openPost(
    recordJSON: String, postURI: String, authorDID: String, circleKey: Data, authorEpochJSON: String
  ) async throws -> String {
    openCalls.append(OpenCall(
      postURI: postURI, authorDID: authorDID, circleKey: circleKey, authorEpochJSON: authorEpochJSON, recordJSON: recordJSON
    ))
    inFlight += 1
    maxInFlight = max(maxInFlight, inFlight)
    if holdNanoseconds > 0 { try? await Task.sleep(nanoseconds: holdNanoseconds) }
    inFlight -= 1
    if let failure { throw failure }
    guard let payload = payloads[postURI] ?? defaultPayload else { throw CircleError.invalidResponse }
    return payload
  }

  nonisolated func postKey(circleKey: Data, circleID: String, postURI: String) throws -> Data {
    Data(repeating: 0, count: 32)
  }
}

struct ScriptedOpenFailure: Error {}

/// Returns a mailboxKeys JSON for any head it knows; throws for the rest.
actor FakeAuthorEpochResolver: AuthorEpochResolver {
  var known: Set<Data> = [CircleOpenFixtures.authorHead]
  private(set) var calls = 0

  func forget(_ head: Data) { known.remove(head) }

  func epochJSON(did: DID, epochHead: Data) async throws -> String {
    calls += 1
    guard known.contains(epochHead) else { throw AuthorEpochResolverError.unknownEpochHead }
    return "{\"current\":{\"epochNumber\":3,\"epochHead\":{\"$bytes\":\"\(epochHead.base64EncodedString())\"}},\"did\":\"\(did.didString())\"}"
  }
}

/// Key delivery for the opener's `CircleKeyManager`: each `getKeys` call
/// answers with the next scripted response (the last one repeats).
actor OpenerKeyTransport: CircleTransport {
  let publicEndpointCallCount: Int = 0
  var responses: [[BlueCatbirdCircleGetKeys.KeyEntry]] = [[]]
  private(set) var getKeysCalls = 0

  func setResponses(_ value: [[BlueCatbirdCircleGetKeys.KeyEntry]]) { responses = value }

  func getKeys(space: SpaceRef, sinceVersion: Int?) async throws -> CircleKeysResponse {
    let index = min(getKeysCalls, responses.count - 1)
    getKeysCalls += 1
    let entries = responses[index].filter { $0.keyVersion > (sinceVersion ?? 0) }
    return .testing(entries, latest: responses[index].map(\.keyVersion).max() ?? 0)
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
  func activateCircle(space: SpaceRef) async throws -> CircleSummary { CircleOpenFixtures.circle }
  func publishPost(destination: CircleSummary, draft: CirclePostDraft) async throws -> ATProtocolURI { throw CircleError.invalidResponse }
  func like(post: AppBskyFeedDefs.PostView, circle: CircleSummary) async throws -> ATProtocolURI { throw CircleError.invalidResponse }
  func deletePost(uri: ATProtocolURI, circle: CircleSummary) async throws {}
  func deleteLike(uri: ATProtocolURI, circle: CircleSummary) async throws {}
  func createSpace(skey: String, circleId: String, name: String, memberDIDs: [DID]) async throws -> CircleSummary { CircleOpenFixtures.circle }
  func deleteSpace(space: SpaceRef) async throws {}
  func addMember(space: SpaceRef, did: DID) async throws {}
  func removeMember(space: SpaceRef, did: DID) async throws {}
  func listMembers(space: SpaceRef) async throws -> [CircleMember] { [] }
}

/// One reader's opener stack, fresh per test.
struct OpenerHarness {
  let crypto = OpenScriptedCrypto()
  let epochs = FakeAuthorEpochResolver()
  let keyTransport = OpenerKeyTransport()
  let store: CircleKeyStore
  let keys: CircleKeyManager
  let cache = CircleFeedCache()
  let mediaLoader = CircleMediaLoader()
  let opener: CirclePostOpener

  /// `resolver` replaces the fake (e.g. a `RepoAuthorEpochResolver` over a scripted fetch).
  init(resolver: (any AuthorEpochResolver)? = nil) {
    store = CircleKeyStore(accountDID: CircleOpenFixtures.accountDID, keychain: InMemoryCircleKeychain())
    keys = CircleKeyManager(
      crypto: crypto, store: store, transport: keyTransport, ownerDID: try! DID(didString: CircleOpenFixtures.accountDID)
    )
    opener = CirclePostOpener(
      crypto: crypto, keys: keys, epochs: resolver ?? epochs,
      accountDID: CircleOpenFixtures.accountDID, cache: cache, mediaLoader: mediaLoader
    )
  }

  /// This device already holds `versions`.
  func holdKeys(_ versions: [UInt64]) async throws {
    for version in versions {
      try await store.store(
        spaceURI: CircleOpenFixtures.spaceURI.uriString(), keyVersion: version,
        circleKey: CircleOpenFixtures.key(version), createdAt: Date(), reason: "created"
      )
    }
  }
}

private func postText(_ item: CircleOpenedItem) -> String? {
  guard case .post(let feedViewPost, _) = item,
        case .knownType(let record) = feedViewPost.post.record,
        let post = record as? AppBskyFeedPost else { return nil }
  return post.text
}

// MARK: - Tests

@Suite("Circle post opener", .serialized)
struct CirclePostOpenerTests {
  @Test("A decryptable envelope opens into a feed post carrying the envelope's counts and viewer state")
  func openerReturnsPostForDecryptableEnvelope() async throws {
    let harness = OpenerHarness()
    try await harness.holdKeys([1])
    let item = CircleOpenFixtures.encryptedItem(0)

    let opened = await harness.opener.open(item, circle: item.circle)

    guard case .post(let feedViewPost, let media) = opened else {
      Issue.record("expected .post, got \(opened)")
      return
    }
    #expect(postText(opened) == CircleOpenFixtures.secretText)
    #expect(feedViewPost.post.uri == CircleOpenFixtures.postURI(0))
    #expect(feedViewPost.post.author.did == CircleOpenFixtures.author)
    #expect(feedViewPost.post.likeCount == 3)
    #expect(feedViewPost.post.replyCount == 2)
    #expect(feedViewPost.post.viewer?.like != nil)

    #expect(media.count == 1)
    let ref = try #require(media.first)
    #expect(ref.cid.string == CircleOpenFixtures.mediaCID)
    #expect(ref.key == Data(repeating: 66, count: 32))
    #expect(ref.iv == Data(repeating: 36, count: 12))
    #expect(ref.mimeType == "image/jpeg")
    #expect(ref.alt == "a heron")
    #expect(ref.width == 1200 && ref.height == 800)
    guard case .appBskyEmbedImagesView(let images) = feedViewPost.post.embed else {
      Issue.record("expected a synthesized images embed")
      return
    }
    #expect(images.images.first?.thumb.uriString().hasSuffix("cid=\(CircleOpenFixtures.mediaCID)") == true)
    #expect(images.images.first?.aspectRatio?.width == 1200)

    let calls = await harness.crypto.openCalls
    #expect(calls.count == 1)
    #expect(calls.first?.postURI == CircleOpenFixtures.postURI(0).uriString())
    #expect(calls.first?.authorDID == CircleOpenFixtures.author.didString())
    #expect(calls.first?.circleKey == CircleOpenFixtures.key(1))
    #expect(calls.first?.authorEpochJSON.contains("epochHead") == true)
    // The media key is handed to the media loader (memory only), not re-derived later.
    #expect(await harness.mediaLoader.registeredKey(
      accountDID: CircleOpenFixtures.accountDID, space: CircleOpenFixtures.spaceURI,
      authorDID: CircleOpenFixtures.author, cid: ref.cid
    ) != nil)
  }

  @Test("An envelope naming a key version this device lacks is held as pendingKey, without throwing or opening")
  func openerReturnsPendingKeyWhenVersionUnknown() async throws {
    let harness = OpenerHarness()
    try await harness.holdKeys([1])
    let item = CircleOpenFixtures.encryptedItem(0, keyVersion: 2)

    let opened = await harness.opener.open(item, circle: item.circle)

    guard case .pendingKey(let uri, let keyVersion) = opened else {
      Issue.record("expected .pendingKey, got \(opened)")
      return
    }
    #expect(uri == CircleOpenFixtures.postURI(0))
    #expect(keyVersion == 2)
    #expect(await harness.crypto.openCalls.isEmpty)
    #expect(await harness.epochs.calls == 0)
  }

  @Test("I12: an envelope older than the earliest held key is posted-before-joined, not unverifiable")
  func openerReportsPostedBeforeJoined() async throws {
    let harness = OpenerHarness()
    try await harness.holdKeys([3, 4])
    let item = CircleOpenFixtures.encryptedItem(0, keyVersion: 2)

    let opened = await harness.opener.open(item, circle: item.circle)

    guard case .postedBeforeJoined(let uri, let keyVersion) = opened else {
      Issue.record("expected .postedBeforeJoined, got \(opened)")
      return
    }
    #expect(uri == CircleOpenFixtures.postURI(0))
    #expect(keyVersion == 2)
    #expect(await harness.crypto.openCalls.isEmpty)
  }

  @Test("I8: an opened payload records the key version it opened under")
  func openedPayloadCarriesKeyVersion() throws {
    let json = #"{"post":{"$type":"app.bsky.feed.post","text":"x","createdAt":"2026-11-07T12:00:00.000Z"},"media":[]}"#
    #expect(try CirclePostOpener.parsePayload(json, keyVersion: 3).keyVersion == 3)
  }

  @Test("A failed signature or AEAD check, or an unknown author epoch, is unverifiable")
  func openerReturnsUnverifiableOnBadSignature() async throws {
    let harness = OpenerHarness()
    try await harness.holdKeys([1])
    await harness.crypto.setFailure(CircleCryptoError.notOpenable("scripted"))
    let item = CircleOpenFixtures.encryptedItem(0)

    let opened = await harness.opener.open(item, circle: item.circle)
    guard case .unverifiable(let uri) = opened else {
      Issue.record("expected .unverifiable, got \(opened)")
      return
    }
    #expect(uri == CircleOpenFixtures.postURI(0))

    // Unknown author epoch head: never reaches the FFI.
    let second = OpenerHarness()
    try await second.holdKeys([1])
    await second.epochs.forget(CircleOpenFixtures.authorHead)
    let unknownEpoch = await second.opener.open(item, circle: item.circle)
    guard case .unverifiable = unknownEpoch else {
      Issue.record("expected .unverifiable for an unknown epoch head, got \(unknownEpoch)")
      return
    }
    #expect(await second.crypto.openCalls.isEmpty)

    // A post claiming another Circle never opens.
    let third = OpenerHarness()
    try await third.holdKeys([1])
    let otherCircle = BlueCatbirdCircleDefs.CircleSummary(
      uri: CircleOpenFixtures.spaceURI, circleId: try TID(tidString: "3l7othercircl"), name: "Other",
      owner: CircleOpenFixtures.owner, memberCount: 2, muted: nil, latestKeyVersion: 1
    )
    let mismatch = await third.opener.open(item, circle: otherCircle)
    guard case .unverifiable = mismatch else {
      Issue.record("expected .unverifiable for a circle mismatch, got \(mismatch)")
      return
    }
  }

  @Test("Concurrent opens of the same URI run the FFI once and are memoized")
  func openerDedupesConcurrentOpensOfSameURI() async throws {
    let harness = OpenerHarness()
    try await harness.holdKeys([1])
    await harness.crypto.setHold(milliseconds: 80)
    let item = CircleOpenFixtures.encryptedItem(0)
    let opener = harness.opener

    let results = await withTaskGroup(of: CircleOpenedItem.self) { group in
      for _ in 0..<5 { group.addTask { await opener.open(item, circle: item.circle) } }
      var collected: [CircleOpenedItem] = []
      for await result in group { collected.append(result) }
      return collected
    }

    #expect(results.count == 5)
    #expect(results.allSatisfy { postText($0) == CircleOpenFixtures.secretText })
    #expect(await harness.crypto.openCalls.count == 1)

    // Memoized for later opens too.
    _ = await opener.open(item, circle: item.circle)
    #expect(await harness.crypto.openCalls.count == 1)
  }

  @Test("At most two openPost calls run at once per account")
  func openerBoundsConcurrency() async throws {
    let harness = OpenerHarness()
    try await harness.holdKeys([1])
    await harness.crypto.setHold(milliseconds: 60)
    let opener = harness.opener
    let items = (0..<6).map { CircleOpenFixtures.encryptedItem($0) }

    await withTaskGroup(of: Void.self) { group in
      for item in items { group.addTask { _ = await opener.open(item, circle: item.circle) } }
    }

    #expect(await harness.crypto.openCalls.count == 6)
    let peak = await harness.crypto.maxInFlight
    #expect(peak <= 2)
    #expect(peak >= 1)
  }

  @Test("A thread node whose record is a blue.catbird.circle.post opens through the same opener")
  func threadNodeWithCirclePostRecordOpens() async throws {
    let harness = OpenerHarness()
    try await harness.holdKeys([1])

    let node = CircleOpenFixtures.threadNode(0)
    let opened = await harness.opener.open(postView: node, circle: CircleOpenFixtures.circle)
    guard case .post(let feedViewPost, _) = opened else {
      Issue.record("expected .post, got \(opened)")
      return
    }
    #expect(postText(opened) == CircleOpenFixtures.secretText)
    #expect(feedViewPost.post.likeCount == 7)
    #expect(feedViewPost.post.replyCount == 4)

    // The same node after a wire round trip (whatever container Petrel decodes
    // the record into) still opens.
    let wire = try JSONEncoder().encode(CircleOpenFixtures.threadNode(1))
    let decoded = try JSONDecoder().decode(AppBskyFeedDefs.PostView.self, from: wire)
    let reopened = await harness.opener.open(postView: decoded, circle: CircleOpenFixtures.circle)
    #expect(postText(reopened) == CircleOpenFixtures.secretText)

    // A plaintext post view passes through unchanged.
    let plain = CircleTestFixtures.makePostView(
      uri: try ATProtocolURI(uriString: "at://did:plc:alice/app.bsky.feed.post/3l7plainaaaaa"), text: "plain"
    )
    let passed = await harness.opener.open(postView: plain, circle: CircleOpenFixtures.circle)
    #expect(postText(passed) == "plain")
  }

  @Test("The media loader decrypts a ciphertext blob with the key ref and verifies its digest")
  func mediaLoaderDecryptsWithKeyRef() async throws {
    let jpeg = try CircleOpenFixtures.jpeg()
    let sealed = try BlobCrypto.encrypt(plaintext: jpeg)
    let cid = CID.fromDAGCBOR(Data("enc-media".utf8))
    let ref = CircleMediaKeyRef(
      cid: cid, key: sealed.key, iv: sealed.iv, sha256: sealed.sha256,
      mimeType: "image/jpeg", alt: nil, width: 64, height: 32
    )

    let plaintext = try CircleMediaLoader.decrypt(sealed.ciphertext, with: ref)
    #expect(Array(plaintext.prefix(3)) == [0xFF, 0xD8, 0xFF])
    #expect(Array(sealed.ciphertext.prefix(3)) != [0xFF, 0xD8, 0xFF])

    let transport = MockCircleTransport()
    await transport.setMediaData(sealed.ciphertext)
    let loader = CircleMediaLoader(service: CircleService(transport: transport))
    let image = try await loader.image(
      accountDID: CircleOpenFixtures.accountDID, space: CircleOpenFixtures.spaceURI,
      authorDID: CircleOpenFixtures.author, cid: cid, targetBucket: 0, decryptWith: ref
    )
    #expect(image.size.width == 64)
    #expect(image.size.height == 32)

    // A tampered digest is refused, never decoded.
    let wrongDigest = CircleMediaKeyRef(
      cid: cid, key: sealed.key, iv: sealed.iv, sha256: String(repeating: "00", count: 32),
      mimeType: "image/jpeg", alt: nil, width: 64, height: 32
    )
    #expect(throws: CircleMediaError.decryptionFailed) {
      try CircleMediaLoader.decrypt(sealed.ciphertext, with: wrongDigest)
    }
  }

  @Test("The author epoch resolver walks immutable copies down to the signing head and caches it")
  func epochResolverWalksImmutableCopies() async throws {
    let did = CircleOpenFixtures.author
    func epochJSON(_ number: Int) -> String {
      let head = Data(repeating: UInt8(number), count: 32).base64EncodedString()
      return "{\"$type\":\"blue.catbird.labyrinth.mailboxKeys\",\"current\":{\"epochNumber\":\(number),\"epochHead\":{\"$bytes\":\"\(head)\"}}}"
    }
    let fetched = FetchLog()
    let resolver = RepoAuthorEpochResolver { requestDID, rkey in
      await fetched.append(rkey)
      #expect(requestDID == did.didString())
      if rkey == "self" { return epochJSON(9) }
      guard let number = Int(rkey), rkey.count == 12 else { return nil }
      return epochJSON(number)
    }

    let json = try await resolver.epochJSON(did: did, epochHead: Data(repeating: 6, count: 32))
    #expect(json == epochJSON(6))
    #expect(await fetched.rkeys == ["self", "000000000008", "000000000007", "000000000006"])

    _ = try await resolver.epochJSON(did: did, epochHead: Data(repeating: 6, count: 32))
    #expect(await fetched.rkeys.count == 4)

    // A head that never appears is refused once the walk bottoms out.
    await #expect(throws: AuthorEpochResolverError.self) {
      _ = try await resolver.epochJSON(did: did, epochHead: Data(repeating: 0xEE, count: 32))
    }
  }

  @Test("The author epoch resolver gives up after 64 steps")
  func epochResolverGivesUpAfter64Steps() async throws {
    let fetched = FetchLog()
    let resolver = RepoAuthorEpochResolver { _, rkey in
      await fetched.append(rkey)
      let number = rkey == "self" ? 500 : (Int(rkey) ?? 0)
      let head = Data(repeating: UInt8(number % 251), count: 31) + Data([0x01])
      return "{\"current\":{\"epochNumber\":\(number),\"epochHead\":{\"$bytes\":\"\(head.base64EncodedString())\"}}}"
    }
    await #expect(throws: AuthorEpochResolverError.self) {
      _ = try await resolver.epochJSON(did: CircleOpenFixtures.author, epochHead: Data(repeating: 0xEE, count: 32))
    }
    #expect(await fetched.rkeys.count == 65) // self + 64 immutable copies
  }
}

actor FetchLog {
  private(set) var rkeys: [String] = []
  func append(_ rkey: String) { rkeys.append(rkey) }
}
