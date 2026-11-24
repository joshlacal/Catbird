//
//  CirclePostSealerTests.swift
//  CatbirdTests
//
//  Sealing posts and media for encrypted Circles (spec §4.2, §4.3, §4.5;
//  D13). Uses a recording transport, a scripted CircleCrypto and an in-memory
//  Keychain; nothing here touches the real Keychain, network or FFI.
//

import CatbirdMLSCore
import CryptoKit
import Foundation
import ImageIO
import Petrel
import PetrelCatbird
import Testing
import UniformTypeIdentifiers
@testable import Catbird

// MARK: - Fixtures

private enum SealFixtures {
  static let author = try! DID(didString: "did:plc:alice")
  static let spaceURI = try! SpaceRef(uriString: "at://did:plc:alice/space/blue.catbird.circle.encrypted/3enc")
  static let plainSpaceURI = try! SpaceRef(uriString: "at://did:plc:alice/space/blue.catbird.circle/3pln")
  static let circleID = "3l7familycirc"
  static let secretText = "the plaintext nobody outside the circle may read"

  static func circle(latestKeyVersion: Int? = nil) -> CircleSummary {
    BlueCatbirdCircleDefs.CircleSummary(
      uri: spaceURI,
      circleId: try! TID(tidString: circleID),
      name: "Close",
      owner: author,
      memberCount: 2,
      muted: nil,
      latestKeyVersion: latestKeyVersion
    )
  }

  /// The exact payload `payloadMatchesRustShape` produces. Verified (2026-11-07)
  /// to deserialize into verbatim copies of `catbird-mls` `CirclePostPayload` /
  /// `CircleMediaKey` with `serde_json` and to satisfy the `createdAt` rule of
  /// `check_record_payload_consistency`. A change here is a wire change.
  static let rustAcceptedPayload = "{\"created_at\":\"2026-10-26T07:33:20.301Z\",\"media\":[{\"alt\":\"a heron\",\"cid\":\"bafyreigkbxzmswvbita5b7zp6pepsz75yhpj54geciftojsbm4a3kgowde\",\"height\":800,\"iv\":[36,36,36,36,36,36,36,36,36,36,36,36],\"key\":[66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66,66],\"mime_type\":\"image/jpeg\",\"sha256\":\"abababababababababababababababababababababababababababababababab\",\"width\":1200}],\"post\":{\"$type\":\"app.bsky.feed.post\",\"createdAt\":\"2026-10-26T07:33:20.301Z\",\"langs\":[],\"text\":\"the plaintext nobody outside the circle may read\"}}"

  static func key(_ version: UInt64) -> Data { Data(repeating: 0x40 &+ UInt8(version), count: 32) }

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
      uri: try ATProtocolURI(uriString: "at://did:plc:alice/blue.catbird.circle.key/\(String(format: "%06d", version))"),
      cid: CIDString(CID.fromDAGCBOR(Data("seal-key-\(version)".utf8))),
      keyVersion: version,
      record: record
    )
  }

  static func blob(_ seed: String) throws -> Blob {
    let cid = CID.fromDAGCBOR(Data(seed.utf8))
    return Blob(type: "blob", ref: ATProtoLink(cid: cid), mimeType: "application/octet-stream", size: 1234)
  }

  static func media(_ seed: String) throws -> CircleEncryptedMedia {
    CircleEncryptedMedia(
      blob: try blob(seed),
      key: Data(repeating: 0x42, count: 32),
      iv: Data(repeating: 0x24, count: 12),
      sha256: String(repeating: "ab", count: 32),
      mimeType: "image/jpeg",
      alt: "a heron",
      width: 1200,
      height: 800
    )
  }

  static func canonicalURI(rkey: String) throws -> ATProtocolURI {
    try ATProtocolURI(uriString: "at://\(author.didString())/blue.catbird.circle.post/\(rkey)")
  }

  static func draft(text: String = secretText, createdAt: Date = Date()) -> CirclePostDraft {
    CirclePostDraft(text: text, langs: [], createdAt: ATProtocolDate(date: createdAt))
  }
}

// MARK: - Scripted crypto

/// Records every seal call and returns a structurally faithful envelope: the
/// cleartext header fields the FFI would build, and a "ciphertext" that is a
/// digest of the payload (so the plaintext can never leak through it).
actor SealRecordingCrypto: CircleCrypto {
  struct SealCall: Sendable {
    let circleID: String
    let keyVersion: UInt64
    let circleKey: Data
    let postURI: String
    let authorDID: String
    let createdAt: Date
    let payloadJSON: String
    let replyJSON: String?
    let attachmentsJSON: [String]
  }

  private(set) var seals: [SealCall] = []
  var openable: [UInt64: Data] = [:]
  var sealError: (any Error)?

  func setOpenable(_ value: [UInt64: Data]) { openable = value }
  func setSealError(_ value: (any Error)?) { sealError = value }

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
  ) async throws -> String {
    if let sealError { throw sealError }
    seals.append(SealCall(
      circleID: circleID, keyVersion: keyVersion, circleKey: circleKey, postURI: postURI,
      authorDID: authorDID, createdAt: createdAt, payloadJSON: payloadJSON,
      replyJSON: replyJSON, attachmentsJSON: attachmentsJSON
    ))
    let digest = Data(SHA256.hash(data: Data(payloadJSON.utf8))).base64EncodedString()
    var record: [String: Any] = [
      "$type": "blue.catbird.circle.post",
      "circleId": circleID,
      "keyVersion": keyVersion,
      "createdAt": ATProtocolDate(date: createdAt).iso8601String,
      "ciphertext": ["$bytes": digest],
      "sig": ["$bytes": Data(repeating: 7, count: 64).base64EncodedString()],
      "authorEpochHead": ["$bytes": Data(repeating: 9, count: 32).base64EncodedString()]
    ]
    if let replyJSON {
      record["reply"] = try JSONSerialization.jsonObject(with: Data(replyJSON.utf8))
    }
    if !attachmentsJSON.isEmpty {
      record["attachments"] = try attachmentsJSON.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) }
    }
    let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }

  func openPost(
    recordJSON: String, postURI: String, authorDID: String, circleKey: Data, authorEpochJSON: String
  ) async throws -> String { "{}" }

  nonisolated func postKey(circleKey: Data, circleID: String, postURI: String) throws -> Data {
    Data(repeating: 0, count: 32)
  }
}

// MARK: - Recording transport

actor SealRecordingTransport: CircleTransport {
  struct EncryptedWrite: Sendable { let space: SpaceRef; let rkey: String; let recordJSON: String }

  let publicEndpointCallCount: Int = 0
  var keyEntries: [BlueCatbirdCircleGetKeys.KeyEntry] = []
  var serverLatest: Int?
  private(set) var plaintextPublishes = 0
  private(set) var encryptedWrites: [EncryptedWrite] = []

  func setKeyEntries(_ value: [BlueCatbirdCircleGetKeys.KeyEntry], serverLatest: Int? = nil) {
    keyEntries = value
    self.serverLatest = serverLatest
  }

  /// Number of `getKeys` calls (each is one key fetch).
  private(set) var getKeysCalls = 0
  /// When set, `getKeys` throws it (e.g. offline).
  var getKeysError: CircleError?
  func setGetKeysError(_ value: CircleError?) { getKeysError = value }

  /// When set, `getKeys` calls after this many succeed throw `URLError(.notConnectedToInternet)`.
  var getKeysSucceedingCalls: Int?
  func setGetKeysSucceedingCalls(_ value: Int?) { getKeysSucceedingCalls = value }
  /// Every `sinceVersion` asked for, in order.
  private(set) var getKeysSince: [Int?] = []

  func getKeys(space: SpaceRef, sinceVersion: Int?) async throws -> CircleKeysResponse {
    getKeysCalls += 1
    getKeysSince.append(sinceVersion)
    if let getKeysError { throw getKeysError }
    if let limit = getKeysSucceedingCalls, getKeysCalls > limit { throw URLError(.notConnectedToInternet) }
    let entries = keyEntries.filter { $0.keyVersion > (sinceVersion ?? 0) }
    return .testing(entries, latest: serverLatest ?? keyEntries.map(\.keyVersion).max() ?? 0)
  }

  /// I7: each encrypted publish first publishes one newer key version (the
  /// owner rotated between seal and publish), `rotations` times in all.
  var rotations = 0
  private(set) var deletedEncrypted: [ATProtocolURI] = []
  func setRotations(_ value: Int) { rotations = value }

  func deleteEncryptedPost(uri: ATProtocolURI, circle: CircleSummary) async throws {
    deletedEncrypted.append(uri)
  }

  func publishEncryptedPost(destination: CircleSummary, postURI: ATProtocolURI, recordJSON: String) async throws -> ATProtocolURI {
    let rkey = postURI.recordKey ?? ""
    encryptedWrites.append(EncryptedWrite(space: destination.uri, rkey: rkey, recordJSON: recordJSON))
    if rotations > 0 {
      rotations -= 1
      let next = (keyEntries.map(\.keyVersion).max() ?? 0) + 1
      keyEntries.append(try SealFixtures.keyEntry(version: next))
    }
    // The server may answer with the space form; crypto must not depend on it.
    return try ATProtocolURI(uriString: "\(destination.uri.uriString())/did:plc:alice/blue.catbird.circle.post/\(rkey)")
  }

  func publishPost(destination: CircleSummary, draft: CirclePostDraft) async throws -> ATProtocolURI {
    plaintextPublishes += 1
    return try ATProtocolURI(uriString: "at://did:plc:alice/app.bsky.feed.post/3plaintext")
  }

  /// `getCapabilities.supportsEncryptedPosts` (off unless a test turns it on).
  var supportsEncryptedPosts = false
  func setSupportsEncryptedPosts(_ value: Bool) { supportsEncryptedPosts = value }

  func capabilities() async throws -> CircleCapability {
    CircleCapability(
      enabled: true, protocolRevision: CircleConfiguration.protocolRevision, supportsImages: true,
      supportsEncryptedPosts: supportsEncryptedPosts
    )
  }
  func listCircles(cursor: String?) async throws -> CircleListPage { CircleListPage(circles: [], cursor: nil) }
  func getFeed(space: SpaceRef?, cursor: String?) async throws -> CircleFeedPage { CircleFeedPage(items: [], cursor: nil) }
  func getPostThread(uri: ATProtocolURI, space: SpaceRef) async throws -> CircleThreadPage { throw CircleError.invalidResponse }
  func listNotifications(cursor: String?) async throws -> CircleNotificationPage { CircleNotificationPage(notifications: [], cursor: nil) }
  func media(space: SpaceRef, authorDID: DID, cid: CID) async throws -> Data { Data() }
  func updatePreferences(space: SpaceRef, muted: Bool) async throws -> Bool { muted }
  /// Every report sent: disclosure nil for the plain entry point.
  private(set) var reports: [(post: ATProtocolURI, disclosure: CircleReportDisclosure?)] = []
  func report(post: ATProtocolURI, circle: CircleSummary, reason: CircleReportReason, details: String?) async throws -> UUID {
    reports.append((post, nil))
    return UUID()
  }
  func report(
    post: ATProtocolURI, circle: CircleSummary, reason: CircleReportReason, details: String?,
    disclosure: CircleReportDisclosure?
  ) async throws -> UUID {
    reports.append((post, disclosure))
    return UUID()
  }
  func activateCircle(space: SpaceRef) async throws -> CircleSummary { SealFixtures.circle() }
  func like(post: AppBskyFeedDefs.PostView, circle: CircleSummary) async throws -> ATProtocolURI { throw CircleError.invalidResponse }
  func deletePost(uri: ATProtocolURI, circle: CircleSummary) async throws {}
  func deleteLike(uri: ATProtocolURI, circle: CircleSummary) async throws {}
  func createSpace(skey: String, circleId: String, name: String, memberDIDs: [DID]) async throws -> CircleSummary { SealFixtures.circle() }
  func deleteSpace(space: SpaceRef) async throws {}
  func addMember(space: SpaceRef, did: DID) async throws {}
  func removeMember(space: SpaceRef, did: DID) async throws {}
  func listMembers(space: SpaceRef) async throws -> [CircleMember] { [] }
}

// MARK: - Harness

private struct SealHarness {
  let crypto = SealRecordingCrypto()
  let transport = SealRecordingTransport()
  let store: CircleKeyStore
  let manager: CircleKeyManager
  let sealer: CirclePostSealer
  let service: CircleService

  init() {
    store = CircleKeyStore(accountDID: SealFixtures.author.didString(), keychain: InMemoryCircleKeychain())
    manager = CircleKeyManager(crypto: crypto, store: store, transport: transport, ownerDID: SealFixtures.author)
    sealer = CirclePostSealer(crypto: crypto, keys: manager)
    service = CircleService(
      transport: transport, keyManager: manager, crypto: crypto, accountDID: SealFixtures.author
    )
  }

  /// Versions `1...n` are published remotely and openable by this account.
  func publishKeys(_ versions: ClosedRange<Int>, serverLatest: Int? = nil) async throws {
    let entries = try versions.map { try SealFixtures.keyEntry(version: $0) }
    await transport.setKeyEntries(entries, serverLatest: serverLatest)
    var openable: [UInt64: Data] = [:]
    for version in versions { openable[UInt64(version)] = SealFixtures.key(UInt64(version)) }
    await crypto.setOpenable(openable)
  }

  func postURI(_ rkey: String = "3l7familycirc") throws -> ATProtocolURI {
    try ATProtocolURI(uriString: "at://did:plc:alice/blue.catbird.circle.post/\(rkey)")
  }
}

private func jsonObject(_ string: String) throws -> [String: Any] {
  try #require(try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
}

/// A small, real JPEG (ImageIO-encoded) carrying a GPS dictionary, so the
/// metadata strip has something to remove.
private func makeJPEG() throws -> Data {
  let width = 8, height = 8
  let context = try #require(CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
  ))
  context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  let image = try #require(context.makeImage())
  let output = NSMutableData()
  let destination = try #require(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
  let properties: [CFString: Any] = [
    kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLongitude: 122.03]
  ]
  CGImageDestinationAddImage(destination, image, properties as CFDictionary)
  #expect(CGImageDestinationFinalize(destination))
  return output as Data
}

// MARK: - Tests

@Suite("CirclePostSealer")
struct CirclePostSealerTests {
  @Test("I7: a post sealed under a key rotated mid-publish is reposted under the latest key")
  func staleKeyPublishIsRepostedOnce() async throws {
    let h = SealHarness()
    try await h.publishKeys(1...1)
    await h.crypto.setOpenable([1: SealFixtures.key(1), 2: SealFixtures.key(2)])
    await h.transport.setRotations(1)

    let result = try await h.service.publish(destination: SealFixtures.circle(), draft: SealFixtures.draft())

    #expect(result.repostedAfterKeyRefresh)
    let writes = await h.transport.encryptedWrites
    try #require(writes.count == 2)
    #expect(try jsonObject(writes[0].recordJSON)["keyVersion"] as? Int == 1)
    #expect(try jsonObject(writes[1].recordJSON)["keyVersion"] as? Int == 2)
    #expect(writes[0].rkey != writes[1].rkey)
    #expect(result.uri.recordKey == writes[1].rkey)
    let stale = try SealFixtures.canonicalURI(rkey: writes[0].rkey)
    #expect(await h.transport.deletedEncrypted == [stale])
    #expect(CirclePostCopy.repostedAfterKeyRefresh == "Reposted after key refresh")
  }

  @Test("I7: an up-to-date publish writes once and deletes nothing")
  func currentKeyPublishIsNotReposted() async throws {
    let h = SealHarness()
    try await h.publishKeys(1...1)

    let result = try await h.service.publish(destination: SealFixtures.circle(), draft: SealFixtures.draft())

    #expect(!result.repostedAfterKeyRefresh)
    #expect(await h.transport.encryptedWrites.count == 1)
    #expect(await h.transport.deletedEncrypted.isEmpty)
  }

  @Test("I7: the repost is bounded to one retry")
  func repostIsBoundedToOneRetry() async throws {
    let h = SealHarness()
    try await h.publishKeys(1...1)
    await h.crypto.setOpenable([1: SealFixtures.key(1), 2: SealFixtures.key(2), 3: SealFixtures.key(3)])
    await h.transport.setRotations(2)

    let result = try await h.service.publish(destination: SealFixtures.circle(), draft: SealFixtures.draft())

    #expect(result.repostedAfterKeyRefresh)
    #expect(await h.transport.encryptedWrites.count == 2)
    #expect(await h.transport.deletedEncrypted.count == 1)
  }

  @Test func sealProducesEnvelopeWithoutPlaintext() async throws {
    let h = SealHarness()
    try await h.publishKeys(1...1)
    _ = try await h.manager.refreshKeys(circle: SealFixtures.circle())

    let result = try await h.sealer.seal(
      draft: SealFixtures.draft(), media: [try SealFixtures.media("m1")],
      circle: SealFixtures.circle(), authorDID: SealFixtures.author, postURI: try h.postURI()
    )

    #expect(!result.recordJSON.contains(SealFixtures.secretText))
    #expect(!result.recordJSON.contains("a heron"))
    let record = try jsonObject(result.recordJSON)
    #expect(record["$type"] as? String == "blue.catbird.circle.post")
    #expect(record["text"] == nil)
    #expect(result.attachments.count == 1)

    let call = try #require(await h.crypto.seals.first)
    // Plaintext goes only into the payload the FFI encrypts.
    #expect(call.payloadJSON.contains(SealFixtures.secretText))
    // The cleartext attachment manifest is blob refs only: no keys, no alt text.
    for attachment in call.attachmentsJSON {
      #expect(!attachment.contains(SealFixtures.secretText))
      #expect(!attachment.contains("a heron"))
      let object = try jsonObject(attachment)
      #expect(Set(object.keys).isSubset(of: ["$type", "ref", "mimeType", "size"]))
    }
    #expect(call.replyJSON == nil)
  }

  @Test func sealUsesLatestKeyVersion() async throws {
    let h = SealHarness()
    try await h.publishKeys(1...3)

    _ = try await h.sealer.seal(
      draft: SealFixtures.draft(), media: [], circle: SealFixtures.circle(latestKeyVersion: 3),
      authorDID: SealFixtures.author, postURI: try h.postURI()
    )
    let call = try #require(await h.crypto.seals.first)
    #expect(call.keyVersion == 3)
    #expect(call.circleKey == SealFixtures.key(3))
    #expect(call.circleID == SealFixtures.circleID)

    // D13: the server knows a newer version this device cannot open → refuse,
    // never seal under the older one.
    let stale = SealHarness()
    try await stale.publishKeys(1...2, serverLatest: 3)
    await #expect(throws: CircleError.encryptionUnavailable) {
      _ = try await stale.sealer.seal(
        draft: SealFixtures.draft(), media: [], circle: SealFixtures.circle(),
        authorDID: SealFixtures.author, postURI: try stale.postURI()
      )
    }
    // The summary's latestKeyVersion is honoured too.
    let summaryAhead = SealHarness()
    try await summaryAhead.publishKeys(1...2)
    await #expect(throws: CircleError.encryptionUnavailable) {
      _ = try await summaryAhead.sealer.seal(
        draft: SealFixtures.draft(), media: [], circle: SealFixtures.circle(latestKeyVersion: 4),
        authorDID: SealFixtures.author, postURI: try summaryAhead.postURI()
      )
    }
    #expect(await stale.crypto.seals.isEmpty)
    #expect(await summaryAhead.crypto.seals.isEmpty)
  }

  @Test func publishFailsClosedWithoutKey() async throws {
    let h = SealHarness()
    // Key records exist but none is openable by this account.
    await h.transport.setKeyEntries([try SealFixtures.keyEntry(version: 1)])

    await #expect(throws: CircleError.encryptionUnavailable) {
      _ = try await h.service.publishPost(destination: SealFixtures.circle(), draft: SealFixtures.draft())
    }
    #expect(await h.transport.encryptedWrites.isEmpty)
    #expect(await h.transport.plaintextPublishes == 0)
    #expect(await h.crypto.seals.isEmpty)

    // No key manager / crypto at all (encryption unavailable on this device).
    let bare = SealRecordingTransport()
    let service = CircleService(transport: bare)
    await #expect(throws: CircleError.encryptionUnavailable) {
      _ = try await service.publishPost(destination: SealFixtures.circle(), draft: SealFixtures.draft())
    }
    #expect(await bare.plaintextPublishes == 0)
    #expect(await bare.encryptedWrites.isEmpty)

    // A seal failure in the FFI never falls back to a plaintext write.
    let failing = SealHarness()
    try await failing.publishKeys(1...1)
    await failing.crypto.setSealError(CircleError.invalidResponse)
    await #expect(throws: CircleError.encryptionUnavailable) {
      _ = try await failing.service.publishPost(destination: SealFixtures.circle(), draft: SealFixtures.draft())
    }
    #expect(await failing.transport.plaintextPublishes == 0)
    #expect(await failing.transport.encryptedWrites.isEmpty)
  }

  @Test func imagesAreEncryptedForEncryptedCircle() async throws {
    let jpeg = try makeJPEG()
    #expect(Array(jpeg.prefix(3)) == [0xFF, 0xD8, 0xFF])

    let uploads = UploadRecorder()
    let media = try await CircleMediaSealer.encryptAndUpload(
      jpeg: jpeg, alt: "a heron", width: 8, height: 8
    ) { data, mimeType in
      await uploads.record(data: data, mimeType: mimeType)
      return Blob(
        type: "blob", ref: ATProtoLink(cid: CID.fromDAGCBOR(data)), mimeType: mimeType, size: data.count
      )
    }

    let upload = try #require(await uploads.calls.first)
    #expect(await uploads.calls.count == 1)
    #expect(upload.mimeType == "application/octet-stream")
    #expect(Array(upload.data.prefix(3)) != [0xFF, 0xD8, 0xFF])
    #expect(upload.data != jpeg)
    #expect(media.mimeType == "image/jpeg")
    #expect(media.key.count == 32)
    #expect(media.iv.count == 12)
    #expect(media.alt == "a heron")
    #expect(media.width == 8 && media.height == 8)
    #expect(media.blob.mimeType == "application/octet-stream")

    // The ciphertext opens back to a JPEG without the GPS metadata.
    let plaintext = try BlobCrypto.decrypt(
      ciphertext: upload.data, key: media.key, iv: media.iv, expectedSHA256: media.sha256
    )
    #expect(Array(plaintext.prefix(3)) == [0xFF, 0xD8, 0xFF])
    let source = try #require(CGImageSourceCreateWithData(plaintext as CFData, nil))
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    #expect(properties?[kCGImagePropertyGPSDictionary] == nil)
  }

  @Test func payloadMatchesRustShape() async throws {
    let h = SealHarness()
    try await h.publishKeys(1...1)
    let createdAt = Date(timeIntervalSince1970: 1_793_000_000.301)

    _ = try await h.sealer.seal(
      draft: SealFixtures.draft(createdAt: createdAt), media: [try SealFixtures.media("m1")],
      circle: SealFixtures.circle(), authorDID: SealFixtures.author, postURI: try h.postURI()
    )
    let call = try #require(await h.crypto.seals.first)
    #expect(call.payloadJSON == SealFixtures.rustAcceptedPayload)
    let payload = try jsonObject(call.payloadJSON)

    // `catbird-mls/src/circles/post.rs` `CirclePostPayload` / `CircleMediaKey`
    // derive serde with NO rename_all: snake_case keys, `Vec<u8>` as integer arrays.
    #expect(Set(payload.keys) == ["post", "media", "created_at"])
    let createdAtString = try #require(payload["created_at"] as? String)
    #expect(createdAtString == ATProtocolDate(date: createdAt).iso8601String)

    let post = try #require(payload["post"] as? [String: Any])
    #expect(post["$type"] as? String == "app.bsky.feed.post")
    #expect(post["text"] as? String == SealFixtures.secretText)
    #expect(post["createdAt"] as? String == createdAtString)
    #expect(post["embed"] == nil)

    let media = try #require(payload["media"] as? [[String: Any]])
    let entry = try #require(media.first)
    #expect(Set(["cid", "key", "iv", "sha256", "mime_type"]).isSubset(of: Set(entry.keys)))
    #expect(Set(entry.keys).isSubset(of: ["cid", "key", "iv", "sha256", "mime_type", "alt", "width", "height"]))
    #expect(entry["cid"] as? String == (try SealFixtures.blob("m1")).ref?.cid.string)
    let keyBytes = try #require(entry["key"] as? [Int])
    #expect(keyBytes == Array(repeating: 0x42, count: 32))
    #expect((entry["iv"] as? [Int])?.count == 12)
    #expect(entry["mime_type"] as? String == "image/jpeg")
    #expect(entry["width"] as? Int == 1200)

    // The header string handed to the FFI (as a Date) formats to the same string.
    #expect(ATProtocolDate(date: call.createdAt).iso8601String == createdAtString)
  }

  @Test func sealUsesCanonicalStandardURI() async throws {
    let h = SealHarness()
    try await h.publishKeys(1...1)

    _ = try await h.service.publishPost(destination: SealFixtures.circle(), draft: SealFixtures.draft())

    let call = try #require(await h.crypto.seals.first)
    let write = try #require(await h.transport.encryptedWrites.first)
    #expect(call.postURI == "at://did:plc:alice/blue.catbird.circle.post/\(write.rkey)")
    #expect(call.authorDID == "did:plc:alice")
    #expect((try? TID(tidString: write.rkey)) != nil)
    #expect(write.space == SealFixtures.spaceURI)
    #expect(try jsonObject(write.recordJSON)["keyVersion"] as? Int == 1)
    #expect(!write.recordJSON.contains(SealFixtures.secretText))
    #expect(await h.transport.plaintextPublishes == 0)
  }

  @Test func plaintextCircleStillPublishesPlaintext() async throws {
    let transport = SealRecordingTransport()
    let service = CircleService(transport: transport)
    let plain = BlueCatbirdCircleDefs.CircleSummary(
      uri: SealFixtures.plainSpaceURI, circleId: try TID(tidString: SealFixtures.circleID),
      name: "Open", owner: SealFixtures.author, memberCount: 1, muted: nil
    )
    _ = try await service.publishPost(destination: plain, draft: SealFixtures.draft())
    #expect(await transport.plaintextPublishes == 1)

    // Encrypted media can never be written into a plaintext Circle.
    let withMedia = CirclePostDraft(text: "x", encryptedMedia: [try SealFixtures.media("m1")])
    await #expect(throws: CircleError.self) {
      _ = try await service.publishPost(destination: plain, draft: withMedia)
    }
    #expect(await transport.plaintextPublishes == 1)
  }
}

private actor UploadRecorder {
  struct Call: Sendable { let data: Data; let mimeType: String }
  private(set) var calls: [Call] = []
  func record(data: Data, mimeType: String) { calls.append(Call(data: data, mimeType: mimeType)) }
}


// MARK: - Reports carry no keys (Signal model)

@Suite("Circle reports disclose nothing", .serialized)
struct CircleReportDisclosureTests {
  @Test("An encrypted Circle report carries no post key or media keys, even for a post opened here")
  func encryptedReportCarriesNoKeys() async throws {
    let h = SealHarness()
    try await h.publishKeys(1...1)
    _ = try await h.manager.refreshKeys(circle: SealFixtures.circle())
    let uri = try h.postURI("3l7reportaaa1")
    let cid = CID.fromDAGCBOR(Data("report-envelope-1".utf8))

    _ = try await h.service.report(post: uri, circle: SealFixtures.circle(), reason: .abuse, cid: cid)

    let report = try #require(await h.transport.reports.first)
    #expect(report.disclosure == nil)
  }

  @Test("A plaintext report has no disclosure fields")
  func plaintextReportIsUnchanged() async throws {
    let h = SealHarness()
    let plain = CircleSummary(
      uri: try SpaceRef(uriString: "at://did:plc:alice/space/blue.catbird.circle/3plain"),
      circleId: try TID(tidString: "3l7familycirc"), name: "Plain", owner: SealFixtures.author
    )
    let uri = try ATProtocolURI(uriString: "at://did:plc:bob/app.bsky.feed.post/3l7postaaaaa")

    _ = try await h.service.report(post: uri, circle: plain, reason: .other)

    let report = try #require(await h.transport.reports.first)
    #expect(report.disclosure == nil)
    let input = try GatewayCircleTransport.reportInput(
      post: uri, circle: plain, reason: .other, details: nil, disclosure: nil
    )
    #expect(input.disclosedPostKey == nil)
    #expect(input.disclosedMedia == nil)
  }

  @Test("Circle reports to Catbird's moderation service name ids only")
  func ozoneSubjectIsIdsOnly() throws {
    let uri = try ATProtocolURI(uriString: "at://did:plc:bob/blue.catbird.circle.post/3l7postaaaaa")
    let cid = CIDString(CID.fromDAGCBOR(Data("post".utf8)))
    guard case .comAtprotoRepoStrongRef(let ref) = CatbirdModeration.circlePostSubject(uri: uri, cid: cid) else {
      Issue.record("a Circle post is reported by strong ref")
      return
    }
    #expect(ref.uri.uriString() == uri.uriString())
    #expect(CatbirdModeration.circleReason(space: "at://did:plc:alice/space/blue.catbird.circle/3c")
      == "Catbird Circle report. Circle: at://did:plc:alice/space/blue.catbird.circle/3c")
    #expect(CatbirdModeration.reasonType(for: .abuse).rawValue == "com.atproto.moderation.defs#reasonRude")
  }
}

// MARK: - Fix wave 2 (D13 refresh before every post, I7 failure surfaced, I3)

extension CirclePostSealerTests {
  @Test("D13: a summary saying v3 does not skip the refresh; getKeys returns v4 and the post is sealed under v4")
  func postIsSealedUnderNewestKeyAfterRefresh() async throws {
    let h = SealHarness()
    try await h.publishKeys(1...3)
    _ = try await h.manager.refreshKeys(circle: SealFixtures.circle())
    #expect(try await h.manager.latestLocalVersion(circle: SealFixtures.circle()) == 3)
    // Another owner device rotated to v4; this device's summary still says 3.
    try await h.publishKeys(1...4)
    let before = await h.transport.getKeysCalls

    let result = try await h.service.publish(
      destination: SealFixtures.circle(latestKeyVersion: 3), draft: SealFixtures.draft()
    )

    let writes = await h.transport.encryptedWrites
    try #require(writes.count == 1)
    #expect(try jsonObject(writes[0].recordJSON)["keyVersion"] as? Int == 4)
    #expect(await h.crypto.seals.last?.keyVersion == 4)
    #expect(!result.repostedAfterKeyRefresh)
    // The refresh asked only for versions newer than the held latest.
    #expect(await h.transport.getKeysCalls > before)
    #expect(await h.transport.getKeysSince.dropFirst(before).first == 3)
  }

  @Test("I7: a failed post-publish key check is reported, not swallowed")
  func postPublishKeyCheckFailureIsSurfaced() async throws {
    let h = SealHarness()
    try await h.publishKeys(1...1)
    // keyForPosting's refresh succeeds; the post-publish check is offline.
    await h.transport.setGetKeysSucceedingCalls(1)

    let result = try await h.service.publish(destination: SealFixtures.circle(), draft: SealFixtures.draft())

    #expect(result.keyCheckFailed)
    #expect(!result.repostedAfterKeyRefresh)
    #expect(await h.transport.encryptedWrites.count == 1)
    #expect(CirclePostCopy.keyCheckFailed.hasPrefix("Posted, but"))
  }

  @Test("I3: an offline key check before posting is a retryable error, not 'keys unavailable'")
  func offlinePostingKeyCheckIsRetryable() async throws {
    let h = SealHarness()
    try await h.publishKeys(1...1)
    await h.transport.setGetKeysSucceedingCalls(0)

    await #expect(throws: CircleError.keysTemporarilyUnavailable) {
      try await h.service.requireEncryptedPostingKey(circle: SealFixtures.circle())
    }
    await #expect(throws: CircleError.keysTemporarilyUnavailable) {
      _ = try await h.service.publish(destination: SealFixtures.circle(), draft: SealFixtures.draft())
    }
    #expect(await h.transport.encryptedWrites.isEmpty)
  }
}
