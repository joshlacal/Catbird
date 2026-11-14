//
//  CircleKeyManagerTests.swift
//  CatbirdTests
//
//  Encrypted Circle key lifecycle (spec §6, D8, D14, D15) and the Keychain-backed
//  CircleKeyStore. Uses a recording transport, a scripted CircleCrypto and an
//  in-memory Keychain; nothing here touches the real Keychain or network.
//

import CatbirdMLSCore
import Foundation
import Security
import Petrel
import PetrelCatbird
import Testing
@testable import Catbird

// MARK: - Fixtures

private enum KeyFixtures {
  static let owner = try! DID(didString: "did:plc:alice")
  static let bob = try! DID(didString: "did:plc:bob")
  static let carol = try! DID(didString: "did:plc:carol")
  static let dave = try! DID(didString: "did:plc:dave")
  static let spaceURI = try! SpaceRef(uriString: "at://did:plc:alice/space/blue.catbird.circle.encrypted/3enc")
  static let circle = BlueCatbirdCircleDefs.CircleSummary(
    uri: spaceURI,
    circleId: try! TID(tidString: "3l7familycirc"),
    name: "Close",
    owner: owner,
    memberCount: 2,
    muted: nil
  )
  static var space: String { spaceURI.uriString() }

  static func rkey(_ version: UInt64) -> String { String(format: "%06llu", version) }
}

// MARK: - In-memory Keychain

final class InMemoryCircleKeychain: CircleKeychain, @unchecked Sendable {
  struct Item { var data: Data; var accessibility: String }
  private let lock = NSLock()
  private var items: [String: [String: Item]] = [:]

  func read(service: String, account: String) throws -> Data? {
    lock.withLock { items[service]?[account]?.data }
  }

  func write(service: String, account: String, data: Data, accessibility: String) throws {
    lock.withLock { items[service, default: [:]][account] = Item(data: data, accessibility: accessibility) }
  }

  func delete(service: String, account: String) throws {
    lock.withLock { _ = items[service]?.removeValue(forKey: account) }
  }

  func accounts(service: String) throws -> [String] {
    lock.withLock { items[service].map { Array($0.keys) } ?? [] }
  }

  func accessibility(service: String, account: String) -> String? {
    lock.withLock { items[service]?[account]?.accessibility }
  }
}

// MARK: - Scripted CircleCrypto

actor ScriptedCircleCrypto: CircleCrypto {
  struct WrapCall: Sendable {
    let keyVersion: UInt64
    let reason: String
    let memberDIDs: [String]
    let createdAt: Date
  }

  private var nextKeyByte: UInt8 = 1
  private(set) var wraps: [WrapCall] = []
  /// Owner epoch head embedded in every wrapped record's `sender`.
  var ownerHead = Data(repeating: 0xA1, count: 32)
  /// Members excluded from every wrap (if present in the roster), with reasons.
  var exclusions: [String: String] = [:]
  /// Versions this account can open in `openCircleKey`, and the key returned.
  var openable: [UInt64: Data] = [:]

  func setOwnerHead(_ head: Data) { ownerHead = head }
  func setExclusions(_ value: [String: String]) { exclusions = value }
  func setOpenable(_ value: [UInt64: Data]) { openable = value }
  /// Every record JSON handed to `openCircleKey`, verbatim.
  private(set) var openedRecordJSONs: [String] = []
  /// Versions whose wrap throws (simulates a mid-way failure).
  var failingVersions: Set<UInt64> = []
  func setFailingVersions(_ value: Set<UInt64>) { failingVersions = value }
  /// Versions whose `openCircleKey` throws (an untrusted or malformed record).
  var throwingOpens: Set<UInt64> = []
  func setThrowingOpens(_ value: Set<UInt64>) { throwingOpens = value }
  /// Per-version error `openCircleKey` throws instead (overrides `throwingOpens`).
  var openErrors: [UInt64: CircleCryptoError] = [:]
  func setOpenErrors(_ value: [UInt64: CircleCryptoError]) { openErrors = value }
  /// Per-version authenticated identity the "FFI" returns (C3 via FFI).
  var authenticatedIdentity: [UInt64: (circleID: String, keyVersion: UInt64)] = [:]
  func setAuthenticatedIdentity(_ value: [UInt64: (circleID: String, keyVersion: UInt64)]) { authenticatedIdentity = value }

  func generateCircleKey() async throws -> Data {
    defer { nextKeyByte &+= 1 }
    return Data(repeating: nextKeyByte, count: 32)
  }

  func wrapCircleKey(
    circleID: String, keyVersion: UInt64, spaceURI: String, reason: String,
    memberDIDs: [String], circleKey: Data, createdAt: Date
  ) async throws -> CircleKeyWrapOutcome {
    if failingVersions.contains(keyVersion) { throw CircleError.upstreamUnavailable }
    wraps.append(WrapCall(keyVersion: keyVersion, reason: reason, memberDIDs: memberDIDs, createdAt: createdAt))
    let excluded = memberDIDs.compactMap { did in exclusions[did].map { (did: did, reason: $0) } }
    let json = Self.recordJSON(
      circleID: circleID, keyVersion: keyVersion, reason: reason, createdAt: createdAt, head: ownerHead
    )
    return CircleKeyWrapOutcome(recordJSON: json, rkey: KeyFixtures.rkey(keyVersion), excluded: excluded)
  }

  func openCircleKey(recordJSON: String, spaceURI: String, ownerDID: String) async throws -> OpenedCircleKey? {
    openedRecordJSONs.append(recordJSON)
    guard
      let object = try JSONSerialization.jsonObject(with: Data(recordJSON.utf8)) as? [String: Any],
      let version = object["keyVersion"] as? Int
    else { return nil }
    if let error = openErrors[UInt64(version)] { throw error }
    if throwingOpens.contains(UInt64(version)) { throw CircleCryptoError.malformed("scripted") }
    return try ScriptedKeyOpen.open(recordJSON: recordJSON, openable: openable, identity: authenticatedIdentity)
  }

  func sealPost(
    circleID: String, keyVersion: UInt64, circleKey: Data, postURI: String, authorDID: String,
    createdAt: Date, payloadJSON: String, replyJSON: String?, attachmentsJSON: [String]
  ) async throws -> String { "{}" }

  func openPost(
    recordJSON: String, postURI: String, authorDID: String, circleKey: Data, authorEpochJSON: String
  ) async throws -> String { "{}" }

  nonisolated func postKey(circleKey: Data, circleID: String, postURI: String) throws -> Data {
    Data(repeating: 0, count: 32)
  }

  /// A `blue.catbird.circle.key` JSON whose sender is an unknown-typed object
  /// carrying `senderEpochHead` (enough for the manager's head comparison and
  /// for Petrel's typed decode via the union's `unexpected` case).
  static func recordJSON(circleID: String, keyVersion: UInt64, reason: String, createdAt: Date, head: Data) -> String {
    let headB64 = head.base64EncodedString()
    return """
    {"$type":"blue.catbird.circle.key","circleId":"\(circleID)","keyVersion":\(keyVersion),\
    "sender":{"$type":"blue.catbird.labyrinth.mek#labyrinthSender","did":"did:plc:alice","senderEpochHead":{"$bytes":"\(headB64)"},"senderEpoch":{"epochNumber":0,"authPubkey":{"$bytes":"AAEC"},"encryptionPubkey":{"$bytes":"AwQF"},"signingPubkey":{"$bytes":"BgcI"},"membersHash":{"$bytes":"CQoL"},"epochHead":{"$bytes":"\(headB64)"},"selfSig":{"$bytes":"DA0O"},"attestation":{"transportPubkey":{"$bytes":"DxAR"},"sig":{"$bytes":"EhMU"}}}},\
    "recipients":[{"$bytes":"AAEC"}],"reason":"\(reason)",\
    "createdAt":"\(ATProtocolDate(date: createdAt).iso8601String)"}
    """
  }
}

// MARK: - Recording transport

actor KeyRecordingCircleTransport: CircleTransport {
  struct PutCall: Sendable { let rkey: String; let recordJSON: String }

  let publicEndpointCallCount: Int = 0
  private(set) var events: [String] = []
  private(set) var puts: [PutCall] = []
  private(set) var getKeysSince: [Int?] = []
  var roster: [DID] = []
  var keyEntries: [BlueCatbirdCircleGetKeys.KeyEntry] = []
  var removeMemberError: (any Error)?
  var addMemberError: (any Error)?
  /// When set for a version, a write at that version is "lost" to another
  /// writer: the stored (read-back) record is this one instead.
  var readBackOverride: [Int: BlueCatbirdCircleKey] = [:]

  func setRoster(_ value: [DID]) { roster = value }
  func setKeyEntries(_ value: [BlueCatbirdCircleGetKeys.KeyEntry]) { keyEntries = value }
  /// Raw record JSON per version, as written (the AppView serves stored JSON).
  var rawRecords: [Int: String] = [:]
  /// When set, getKeys decodes this exact response body (the production path).
  var rawResponseBody: Data?
  func setRawResponseBody(_ value: Data?) { rawResponseBody = value }
  func setRemoveMemberError(_ value: (any Error)?) { removeMemberError = value }
  func setAddMemberError(_ value: (any Error)?) { addMemberError = value }
  func setReadBackOverride(version: Int, record: BlueCatbirdCircleKey) { readBackOverride[version] = record }
  /// When set for a version, the AppView serves these exact bytes for the
  /// written record (e.g. another serializer's key order, or a mangled copy).
  var rawReadBackOverride: [Int: String] = [:]
  func setRawReadBackOverride(version: Int, json: String) { rawReadBackOverride[version] = json }
  /// Applied to every written record before it is served back (raw bytes only).
  var readBackMutation: (@Sendable (String) -> String)?
  func setReadBackMutation(_ value: (@Sendable (String) -> String)?) { readBackMutation = value }
  func setRawRecord(version: Int, json: String) { rawRecords[version] = json }
  /// getKeys page size (nil: one page with everything) and `skipped` per page.
  var pageSize: Int?
  var skippedPerPage = 0
  func setPaging(size: Int?, skipped: Int = 0) { pageSize = size; skippedPerPage = skipped }

  func putReasons() -> [String] {
    puts.compactMap { put in
      (try? JSONSerialization.jsonObject(with: Data(put.recordJSON.utf8)) as? [String: Any])?["reason"] as? String
    }
  }

  // Encrypted-Circle surface
  func getKeys(space: SpaceRef, sinceVersion: Int?) async throws -> CircleKeysResponse {
    getKeysSince.append(sinceVersion)
    if let rawResponseBody { return try CircleKeysResponse(responseBody: rawResponseBody) }
    var entries = keyEntries.filter { $0.keyVersion > (sinceVersion ?? 0) }.sorted { $0.keyVersion < $1.keyVersion }
    if let pageSize { entries = Array(entries.prefix(pageSize)) }
    return .testing(
      entries, latest: keyEntries.map(\.keyVersion).max() ?? 0, raw: rawRecords, skipped: skippedPerPage
    )
  }

  func putKeyRecord(space: SpaceRef, rkey: String, recordJSON: String) async throws -> ATProtocolURI {
    events.append("putKeyRecord:\(rkey)")
    puts.append(PutCall(rkey: rkey, recordJSON: recordJSON))
    let uri = try ATProtocolURI(uriString: "at://did:plc:alice/blue.catbird.circle.key/\(rkey)")
    // Behave like the AppView: the written record becomes readable via getKeys.
    let written = try JSONDecoder().decode(BlueCatbirdCircleKey.self, from: Data(recordJSON.utf8))
    let version = written.keyVersion
    let record = readBackOverride[version] ?? written
    let cid = CID.fromDAGCBOR((try? JSONEncoder().encode(record)) ?? Data(recordJSON.utf8))
    keyEntries.removeAll { $0.keyVersion == version }
    keyEntries.append(BlueCatbirdCircleGetKeys.KeyEntry(uri: uri, cid: CIDString(cid), keyVersion: version, record: record))
    let served = readBackMutation.map { $0(recordJSON) } ?? recordJSON
    rawRecords[version] = rawReadBackOverride[version] ?? (readBackOverride[version] == nil ? served : nil)
    return uri
  }

  func createEncryptedSpace(skey: String, circleId: String, name: String) async throws -> CircleSummary {
    events.append("createEncryptedSpace")
    return KeyFixtures.circle
  }

  // Space administration
  func createSpace(skey: String, circleId: String, name: String, memberDIDs: [DID]) async throws -> CircleSummary {
    events.append("createSpace")
    return KeyFixtures.circle
  }
  func deleteSpace(space: SpaceRef) async throws {}
  func addMember(space: SpaceRef, did: DID) async throws {
    events.append("addMember:\(did.didString())")
    if let addMemberError { throw addMemberError }
    if !roster.contains(did) { roster.append(did) }
  }
  func removeMember(space: SpaceRef, did: DID) async throws {
    events.append("removeMember:\(did.didString())")
    if let removeMemberError { throw removeMemberError }
    roster.removeAll { $0 == did }
  }
  func listMembers(space: SpaceRef) async throws -> [CircleMember] {
    roster.map { CircleMember(did: $0, read: true, write: true) }
  }

  // Unused reads/writes
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
  func activateCircle(space: SpaceRef) async throws -> CircleSummary { KeyFixtures.circle }
  func publishPost(destination: CircleSummary, draft: CirclePostDraft) async throws -> ATProtocolURI { throw CircleError.invalidResponse }
  func like(post: AppBskyFeedDefs.PostView, circle: CircleSummary) async throws -> ATProtocolURI { throw CircleError.invalidResponse }
  func deletePost(uri: ATProtocolURI, circle: CircleSummary) async throws {}
  func deleteLike(uri: ATProtocolURI, circle: CircleSummary) async throws {}
}

// MARK: - Harness

private struct Harness {
  let crypto = ScriptedCircleCrypto()
  let keychain = InMemoryCircleKeychain()
  let transport = KeyRecordingCircleTransport()
  let store: CircleKeyStore
  let manager: CircleKeyManager

  init() {
    store = CircleKeyStore(accountDID: KeyFixtures.owner.didString(), keychain: keychain)
    manager = CircleKeyManager(crypto: crypto, store: store, transport: transport, ownerDID: KeyFixtures.owner)
  }

  /// Seeds versions 1...n locally (as if written by this device earlier).
  func seed(
    versions: ClosedRange<UInt64>, createdAt: Date = Date(), head: Data = Data(repeating: 0xA1, count: 32),
    lastRewrapAt: Date = Date()
  ) async throws {
    for version in versions {
      try await store.store(
        spaceURI: KeyFixtures.space, keyVersion: version,
        circleKey: Data(repeating: UInt8(version), count: 32),
        createdAt: createdAt, reason: version == 1 ? "created" : "manualRotation"
      )
      try await store.setSenderEpochHead(spaceURI: KeyFixtures.space, keyVersion: version, head: head)
    }
    try await store.setLastRewrapAt(spaceURI: KeyFixtures.space, date: lastRewrapAt)
  }
}

private func makeKeyEntry(version: Int, reason: String = "created", createdAt: Date = Date()) throws -> BlueCatbirdCircleGetKeys.KeyEntry {
  let json = ScriptedCircleCrypto.recordJSON(
    circleID: "3l7familycirc", keyVersion: UInt64(version), reason: reason,
    createdAt: createdAt, head: Data(repeating: 0xA1, count: 32)
  )
  let record = try JSONDecoder().decode(BlueCatbirdCircleKey.self, from: Data(json.utf8))
  return BlueCatbirdCircleGetKeys.KeyEntry(
    uri: try ATProtocolURI(uriString: "at://did:plc:alice/blue.catbird.circle.key/\(KeyFixtures.rkey(UInt64(version)))"),
    cid: CIDString(CID.fromDAGCBOR(Data("key-\(version)-\(reason)".utf8))),
    keyVersion: version,
    record: record
  )
}

// MARK: - CircleKeyManager

@Suite("CircleKeyManager")
struct CircleKeyManagerTests {
  @Test func createWritesKeyBeforeMembers() async throws {
    let h = Harness()
    let service = CircleService(transport: h.transport, keyManager: h.manager)

    _ = try await service.createSpace(
      skey: "3enc", circleId: "3l7familycirc", name: "Close",
      memberDIDs: [KeyFixtures.bob, KeyFixtures.carol], encrypted: true
    )

    let events = await h.transport.events
    #expect(events.first == "createEncryptedSpace")
    let put = try #require(events.firstIndex(of: "putKeyRecord:000001"))
    let firstAdd = try #require(events.firstIndex { $0.hasPrefix("addMember:") })
    #expect(put < firstAdd)
    #expect(events.filter { $0.hasPrefix("addMember:") }.count == 2)
    #expect(await h.transport.putReasons() == ["created"])
    #expect(try await h.store.latestVersion(spaceURI: KeyFixtures.space) == 1)
    let wrap = try #require(await h.crypto.wraps.first)
    #expect(Set(wrap.memberDIDs) == [KeyFixtures.bob.didString(), KeyFixtures.carol.didString()])
  }

  @Test func removeRotatesBeforeACL() async throws {
    let h = Harness()
    try await h.seed(versions: 1...1)
    await h.transport.setRoster([KeyFixtures.bob, KeyFixtures.carol])
    let service = CircleService(transport: h.transport, keyManager: h.manager)

    try await service.removeMember(circle: KeyFixtures.circle, did: KeyFixtures.bob)

    let events = await h.transport.events
    let put = try #require(events.firstIndex(of: "putKeyRecord:000002"))
    let remove = try #require(events.firstIndex(of: "removeMember:did:plc:bob"))
    #expect(put < remove)
    #expect(await h.transport.putReasons() == ["memberRemoved"])
    let wrap = try #require(await h.crypto.wraps.last)
    #expect(wrap.memberDIDs == [KeyFixtures.carol.didString()])
    #expect(try await h.store.latestVersion(spaceURI: KeyFixtures.space) == 2)
  }

  @Test func removeACLFailureIsQueuedAndRetriedWithoutSecondRotation() async throws {
    let h = Harness()
    try await h.seed(versions: 1...1)
    await h.transport.setRoster([KeyFixtures.bob, KeyFixtures.carol])
    await h.transport.setRemoveMemberError(CircleError.upstreamUnavailable)
    let service = CircleService(transport: h.transport, keyManager: h.manager)

    await #expect(throws: CircleError.upstreamUnavailable) {
      try await service.removeMember(circle: KeyFixtures.circle, did: KeyFixtures.bob)
    }
    let pending = try await h.store.pendingRewraps(spaceURI: KeyFixtures.space)
    #expect(pending.contains { $0.did == "__acl__:did:plc:bob" && $0.reason == "aclRemovePending:rotated" })
    #expect(try await h.store.latestVersion(spaceURI: KeyFixtures.space) == 2)

    await h.transport.setRemoveMemberError(nil)
    try await h.manager.retryPendingRewraps(circle: KeyFixtures.circle)

    #expect(try await h.store.pendingRewraps(spaceURI: KeyFixtures.space).isEmpty)
    #expect(try await h.store.latestVersion(spaceURI: KeyFixtures.space) == 2)
    #expect(await h.transport.puts.count == 1)
  }

  @Test func addWithHistoryRewritesExistingVersions() async throws {
    let h = Harness()
    try await h.seed(versions: 1...3)
    await h.transport.setRoster([KeyFixtures.bob, KeyFixtures.dave])

    try await h.manager.rewrapForAddedMember(
      circle: KeyFixtures.circle, historyVisible: true
    )

    let puts = await h.transport.puts
    #expect(puts.map(\.rkey) == ["000003", "000002", "000001"])
    #expect(await h.transport.putReasons() == ["manualRotation", "manualRotation", "created"])
    #expect(try await h.store.latestVersion(spaceURI: KeyFixtures.space) == 3)
    let wraps = await h.crypto.wraps
    #expect(wraps.allSatisfy { Set($0.memberDIDs) == [KeyFixtures.bob.didString(), KeyFixtures.dave.didString()] })
  }

  @Test func addWithHistorySkipsVersionsOlderThanMaxAge() async throws {
    let h = Harness()
    try await h.seed(versions: 1...1, createdAt: Date().addingTimeInterval(-CircleConfiguration.maxRewrapAge - 86_400))
    try await h.seed(versions: 2...2)
    await h.transport.setRoster([KeyFixtures.bob])

    try await h.manager.rewrapForAddedMember(
      circle: KeyFixtures.circle, historyVisible: true
    )

    #expect(await h.transport.puts.map(\.rkey) == ["000002"])
  }

  @Test func addWithoutHistoryRotates() async throws {
    let h = Harness()
    try await h.seed(versions: 1...1)
    await h.transport.setRoster([KeyFixtures.bob, KeyFixtures.dave])

    try await h.manager.rewrapForAddedMember(
      circle: KeyFixtures.circle, historyVisible: false
    )

    #expect(await h.transport.puts.map(\.rkey) == ["000002"])
    #expect(await h.transport.putReasons() == ["memberAdded"])
    #expect(try await h.store.latestVersion(spaceURI: KeyFixtures.space) == 2)
  }

  /// Swift never re-encodes a record it hands to the FFI: the key record
  /// reaches `openCircleKey` as the exact bytes the AppView served, unknown
  /// fields and spacing included.
  @Test func keyRecordPassedToFFIIsRawServerJSON() async throws {
    let h = Harness()
    let head = Data(repeating: 0xA1, count: 32).base64EncodedString()
    let record = """
    { "createdAt":"2026-11-07T12:00:00.000Z", "$type":"blue.catbird.circle.key", "circleId":"3l7familycirc",\
     "keyVersion":1, "futureField":{"note":"a \\"quoted\\" } brace"},\
     "sender":{"$type":"blue.catbird.labyrinth.mek#labyrinthSender","did":"did:plc:alice","senderEpochHead":{"$bytes":"\(head)"},"senderEpoch":{"epochNumber":0,"authPubkey":{"$bytes":"AAEC"},"encryptionPubkey":{"$bytes":"AwQF"},"signingPubkey":{"$bytes":"BgcI"},"membersHash":{"$bytes":"CQoL"},"epochHead":{"$bytes":"\(head)"},"selfSig":{"$bytes":"DA0O"},"attestation":{"transportPubkey":{"$bytes":"DxAR"},"sig":{"$bytes":"EhMU"}}}},\
     "recipients":[{"$bytes":"AAEC"}], "reason":"created" }
    """
    let body = """
    {"keys":[{"uri":"at://did:plc:alice/blue.catbird.circle.key/000001",\
    "cid":"\(CID.fromDAGCBOR(Data("key-1".utf8)).string)","keyVersion":1,"record":\(record)}],\
    "latestKeyVersion":1}
    """
    await h.transport.setRawResponseBody(Data(body.utf8))
    await h.crypto.setOpenable([1: Data(repeating: 0x11, count: 32)])

    _ = try await h.manager.refreshKeys(circle: KeyFixtures.circle)

    #expect(await h.crypto.openedRecordJSONs == [record])
    #expect(try await h.store.key(spaceURI: KeyFixtures.space, keyVersion: 1) == Data(repeating: 0x11, count: 32))
    // Positive control: Petrel's typed round trip strips spacing and reorders keys (petrel != record).
    let typed = try JSONDecoder().decode(BlueCatbirdCircleKey.self, from: Data(record.utf8))
    let petrel = String(decoding: try JSONEncoder().encode(typed), as: UTF8.self)
    #expect(petrel != record)
  }

  @Test func refreshKeysStoresOpenedVersions() async throws {
    let h = Harness()
    let entries = try (1...3).map { version -> BlueCatbirdCircleGetKeys.KeyEntry in
      let json = ScriptedCircleCrypto.recordJSON(
        circleID: "3l7familycirc", keyVersion: UInt64(version), reason: "created",
        createdAt: Date(), head: Data(repeating: 0xA1, count: 32)
      )
      let record = try JSONDecoder().decode(BlueCatbirdCircleKey.self, from: Data(json.utf8))
      return BlueCatbirdCircleGetKeys.KeyEntry(
        uri: try ATProtocolURI(uriString: "at://did:plc:alice/blue.catbird.circle.key/\(KeyFixtures.rkey(UInt64(version)))"),
        cid: CIDString(CID.fromDAGCBOR(Data("key-\(version)".utf8))),
        keyVersion: version,
        record: record
      )
    }
    await h.transport.setKeyEntries(entries)
    await h.crypto.setOpenable([1: Data(repeating: 0x11, count: 32), 3: Data(repeating: 0x33, count: 32)])

    let latest = try await h.manager.refreshKeys(circle: KeyFixtures.circle)

    #expect(latest == 3)
    #expect(await h.transport.getKeysSince == [nil])
    #expect(try await h.store.allVersions(spaceURI: KeyFixtures.space) == [1, 3])
    #expect(try await h.store.key(spaceURI: KeyFixtures.space, keyVersion: 3) == Data(repeating: 0x33, count: 32))
    #expect(try await h.store.key(spaceURI: KeyFixtures.space, keyVersion: 2) == nil)
    let current = try #require(try await h.manager.currentKey(circle: KeyFixtures.circle))
    #expect(current.version == 3)
  }

  @Test func excludedMembersBecomePendingRewrap() async throws {
    let h = Harness()
    try await h.seed(versions: 1...1)
    await h.transport.setRoster([KeyFixtures.bob, KeyFixtures.carol])
    await h.crypto.setExclusions([KeyFixtures.bob.didString(): "directory unreachable"])

    _ = try await h.manager.rotate(
      circle: KeyFixtures.circle, reason: "manualRotation"
    )

    #expect(await h.transport.puts.map(\.rkey) == ["000002"])
    let pending = try await h.store.pendingRewraps(spaceURI: KeyFixtures.space)
    #expect(pending.map(\.did) == [KeyFixtures.bob.didString()])
    #expect(pending.first?.reason == "directory unreachable")

    // The fault clears: the retry re-wraps the current version and empties the list.
    await h.crypto.setExclusions([:])
    try await h.manager.retryPendingRewraps(circle: KeyFixtures.circle)
    #expect(await h.transport.puts.map(\.rkey) == ["000002", "000002"])
    #expect(try await h.store.pendingRewraps(spaceURI: KeyFixtures.space).isEmpty)
    #expect(try await h.store.latestVersion(spaceURI: KeyFixtures.space) == 2)
  }

  @Test func reconcileRewrapsCurrentVersionOnOwnerEpochChange() async throws {
    let h = Harness()
    try await h.seed(versions: 1...2, head: Data(repeating: 0xA1, count: 32))
    await h.transport.setRoster([KeyFixtures.bob])

    // Same owner head: nothing is written.
    try await h.manager.reconcileEpochs(circle: KeyFixtures.circle)
    #expect(await h.transport.puts.isEmpty)

    await h.crypto.setOwnerHead(Data(repeating: 0xB2, count: 32))
    try await h.manager.reconcileEpochs(circle: KeyFixtures.circle)

    #expect(await h.transport.puts.map(\.rkey) == ["000002"])
    #expect(await h.transport.putReasons() == ["ownerEpochRotated"])
    #expect(try await h.store.latestVersion(spaceURI: KeyFixtures.space) == 2)
    #expect(try await h.store.senderEpochHead(spaceURI: KeyFixtures.space, keyVersion: 2) == Data(repeating: 0xB2, count: 32))

    // The new head is now the stored one: a second reconcile is a no-op.
    try await h.manager.reconcileEpochs(circle: KeyFixtures.circle)
    #expect(await h.transport.puts.count == 1)
  }

  @Test func reconcileRewrapsOnMemberEpochChange() async throws {
    let h = Harness()
    try await h.seed(versions: 1...1)
    await h.transport.setRoster([KeyFixtures.bob, KeyFixtures.carol])
    // An earlier wrap could not reach bob's current epoch.
    try await h.store.setPendingRewrap(
      spaceURI: KeyFixtures.space, did: KeyFixtures.bob.didString(), reason: "epoch chain changed since last wrap"
    )

    try await h.manager.reconcileEpochs(circle: KeyFixtures.circle)

    #expect(await h.transport.puts.map(\.rkey) == ["000001"])
    #expect(await h.transport.putReasons() == ["memberEpochRotated"])
    #expect(try await h.store.latestVersion(spaceURI: KeyFixtures.space) == 1)
    #expect(try await h.store.pendingRewraps(spaceURI: KeyFixtures.space).isEmpty)
  }
  // MARK: Review fix round 1

  @Test func pendingACLMemberIsNeverWrappedAgain() async throws {
    let h = Harness()
    try await h.seed(versions: 1...1)
    await h.transport.setRoster([KeyFixtures.bob, KeyFixtures.carol])
    await h.transport.setRemoveMemberError(CircleError.upstreamUnavailable)
    let service = CircleService(transport: h.transport, keyManager: h.manager)
    await #expect(throws: CircleError.upstreamUnavailable) {
      try await service.removeMember(circle: KeyFixtures.circle, did: KeyFixtures.bob)
    }

    // bob is still on the ACL roster; neither a history add nor a rotation may wrap him.
    try await service.addMember(circle: KeyFixtures.circle, did: KeyFixtures.dave, historyVisible: true)
    _ = try await h.manager.rotate(
      circle: KeyFixtures.circle, reason: "manualRotation"
    )
    try await h.manager.reconcileEpochs(circle: KeyFixtures.circle)

    let wraps = await h.crypto.wraps
    #expect(wraps.count >= 4)
    #expect(wraps.allSatisfy { !$0.memberDIDs.contains(KeyFixtures.bob.didString()) })
    #expect(wraps.contains { $0.keyVersion == 1 && $0.memberDIDs.contains(KeyFixtures.dave.didString()) })
  }

  @Test func hiddenHistoryAddRotatesBeforeACL() async throws {
    let h = Harness()
    try await h.seed(versions: 1...1)
    await h.transport.setRoster([KeyFixtures.bob])
    let service = CircleService(transport: h.transport, keyManager: h.manager)

    try await service.addMember(circle: KeyFixtures.circle, did: KeyFixtures.dave, historyVisible: false)

    let events = await h.transport.events
    let put = try #require(events.firstIndex(of: "putKeyRecord:000002"))
    let grant = try #require(events.firstIndex(of: "addMember:did:plc:dave"))
    #expect(put < grant)
    #expect(await h.transport.putReasons() == ["memberAdded"])
    let wraps = await h.crypto.wraps
    #expect(wraps.count == 1)
    #expect(Set(wraps[0].memberDIDs) == [KeyFixtures.bob.didString(), KeyFixtures.dave.didString()])
    #expect(try await h.store.pendingRewraps(spaceURI: KeyFixtures.space).isEmpty)
  }

  @Test func failedHiddenAddNeverWrapsOldVersionToNewcomer() async throws {
    let h = Harness()
    try await h.seed(versions: 1...1)
    await h.transport.setRoster([KeyFixtures.bob])
    await h.transport.setAddMemberError(CircleError.upstreamUnavailable)
    let service = CircleService(transport: h.transport, keyManager: h.manager)

    await #expect(throws: CircleError.upstreamUnavailable) {
      try await service.addMember(circle: KeyFixtures.circle, did: KeyFixtures.dave, historyVisible: false)
    }
    let pending = try await h.store.pendingRewraps(spaceURI: KeyFixtures.space)
    #expect(pending.map(\.did) == ["__aclAdd__:did:plc:dave"])
    #expect(pending.first?.reason == "aclAddPending")

    // The retry grants only; it never re-wraps anything to the newcomer.
    await h.transport.setAddMemberError(nil)
    try await h.manager.retryPendingRewraps(circle: KeyFixtures.circle)
    // A weekly reconcile of the current version keeps the newcomer in v2.
    try await h.store.setLastRewrapAt(spaceURI: KeyFixtures.space, date: Date.distantPast)
    try await h.manager.reconcileEpochs(circle: KeyFixtures.circle)

    let events = await h.transport.events
    #expect(events.filter { $0 == "addMember:did:plc:dave" }.count == 2)
    #expect(try await h.store.pendingRewraps(spaceURI: KeyFixtures.space).isEmpty)
    let wraps = await h.crypto.wraps
    let toDave = wraps.filter { $0.memberDIDs.contains(KeyFixtures.dave.didString()) }
    #expect(!toDave.isEmpty)
    #expect(toDave.allSatisfy { $0.keyVersion == 2 })
    #expect(try await h.store.latestVersion(spaceURI: KeyFixtures.space) == 2)
  }

  @Test func addWithHistoryIncludesRemoteVersions() async throws {
    let h = Harness()
    try await h.seed(versions: 1...4)
    await h.transport.setKeyEntries([try makeKeyEntry(version: 5, reason: "manualRotation")])
    await h.crypto.setOpenable([5: Data(repeating: 0x55, count: 32)])
    let service = CircleService(transport: h.transport, keyManager: h.manager)

    try await service.addMember(circle: KeyFixtures.circle, did: KeyFixtures.dave, historyVisible: true)

    #expect(await h.transport.getKeysSince.first == 4)
    #expect(await h.transport.puts.map(\.rkey) == ["000005", "000004", "000003", "000002", "000001"])
    let wraps = await h.crypto.wraps
    #expect(wraps.first?.keyVersion == 5)
    #expect(wraps.allSatisfy { $0.memberDIDs.contains(KeyFixtures.dave.didString()) })
    #expect(try await h.store.latestVersion(spaceURI: KeyFixtures.space) == 5)
  }

  @Test func interleavedRemovesExcludeBothMembers() async throws {
    let h = Harness()
    try await h.seed(versions: 1...1)
    await h.transport.setRoster([KeyFixtures.bob, KeyFixtures.carol, KeyFixtures.dave])
    let service = CircleService(transport: h.transport, keyManager: h.manager)

    async let first: Void = service.removeMember(circle: KeyFixtures.circle, did: KeyFixtures.bob)
    async let second: Void = service.removeMember(circle: KeyFixtures.circle, did: KeyFixtures.carol)
    _ = try await (first, second)

    #expect(try await h.store.latestVersion(spaceURI: KeyFixtures.space) == 3)
    let last = try #require(await h.crypto.wraps.last)
    #expect(last.keyVersion == 3)
    #expect(last.memberDIDs == [KeyFixtures.dave.didString()])
  }

  @Test func putThenReadBackMismatchDoesNotStoreLocalKey() async throws {
    let h = Harness()
    try await h.seed(versions: 1...1)
    await h.transport.setRoster([KeyFixtures.bob])
    let foreign = try makeKeyEntry(version: 2, reason: "manualRotation").record
    await h.transport.setReadBackOverride(version: 2, record: foreign)

    await #expect(throws: CircleError.keyVersionConflict) {
      _ = try await h.manager.rotate(circle: KeyFixtures.circle, reason: "memberRemoved")
    }
    #expect(try await h.store.latestVersion(spaceURI: KeyFixtures.space) == 1)
    #expect(try await h.store.key(spaceURI: KeyFixtures.space, keyVersion: 2) == nil)
  }

  @Test func refreshAdoptsRemoteKeyWhenRecordCIDChanged() async throws {
    let h = Harness()
    try await h.seed(versions: 1...1)
    try await h.store.setRecordCID(spaceURI: KeyFixtures.space, keyVersion: 1, cid: "bafy-mine")
    await h.transport.setKeyEntries([try makeKeyEntry(version: 1, reason: "created")])
    await h.crypto.setOpenable([1: Data(repeating: 0xEE, count: 32)])

    _ = try await h.manager.refreshKeys(circle: KeyFixtures.circle)

    #expect(try await h.store.key(spaceURI: KeyFixtures.space, keyVersion: 1) == Data(repeating: 0xEE, count: 32))
  }

  @Test func reconcileRewrapsCurrentWeekly() async throws {
    let h = Harness()
    try await h.seed(versions: 1...2, lastRewrapAt: Date().addingTimeInterval(-8 * 24 * 3600))
    await h.transport.setRoster([KeyFixtures.bob, KeyFixtures.carol])

    try await h.manager.reconcileEpochs(circle: KeyFixtures.circle)

    #expect(await h.transport.puts.map(\.rkey) == ["000002"])
    #expect(await h.transport.putReasons() == ["memberEpochRotated"])
    #expect(try await h.store.latestVersion(spaceURI: KeyFixtures.space) == 2)

    // Just re-wrapped: the next reconcile writes nothing.
    try await h.manager.reconcileEpochs(circle: KeyFixtures.circle)
    #expect(await h.transport.puts.count == 1)
  }
  // MARK: Review fix round 2

  @Test func reconcileAfterCompletedRemovalExcludesRemovedMember() async throws {
    let h = Harness()
    try await h.seed(versions: 1...1)
    await h.transport.setRoster([KeyFixtures.bob, KeyFixtures.carol])
    let service = CircleService(transport: h.transport, keyManager: h.manager)

    try await service.removeMember(circle: KeyFixtures.circle, did: KeyFixtures.bob)
    #expect(try await h.store.pendingRewraps(spaceURI: KeyFixtures.space).isEmpty)
    // Force the weekly rule so reconcile actually wraps the current version.
    try await h.store.setLastRewrapAt(spaceURI: KeyFixtures.space, date: .distantPast)
    try await h.manager.reconcileEpochs(circle: KeyFixtures.circle)

    let wraps = await h.crypto.wraps
    #expect(wraps.count >= 2)
    #expect(wraps.allSatisfy { !$0.memberDIDs.contains(KeyFixtures.bob.didString()) })
    #expect(await h.transport.putReasons().last == "memberEpochRotated")
  }

  @Test func killBetweenRotationAndACLStillExcludesMember() async throws {
    let h = Harness()
    try await h.seed(versions: 1...1)
    await h.transport.setRoster([KeyFixtures.bob, KeyFixtures.carol])
    await h.transport.setRemoveMemberError(CircleError.upstreamUnavailable)
    await #expect(throws: CircleError.upstreamUnavailable) {
      try await h.manager.removeMember(circle: KeyFixtures.circle, did: KeyFixtures.bob)
    }

    // "Relaunch": a fresh store and manager over the same Keychain; bob is still on the ACL.
    let store = CircleKeyStore(accountDID: KeyFixtures.owner.didString(), keychain: h.keychain)
    let manager = CircleKeyManager(crypto: h.crypto, store: store, transport: h.transport, ownerDID: KeyFixtures.owner)
    try await store.setLastRewrapAt(spaceURI: KeyFixtures.space, date: .distantPast)
    try await manager.reconcileEpochs(circle: KeyFixtures.circle)
    #expect(await h.crypto.wraps.allSatisfy { !$0.memberDIDs.contains(KeyFixtures.bob.didString()) })

    await h.transport.setRemoveMemberError(nil)
    try await manager.retryPendingRewraps(circle: KeyFixtures.circle)

    #expect(try await store.pendingRewraps(spaceURI: KeyFixtures.space).isEmpty)
    #expect(try await store.latestVersion(spaceURI: KeyFixtures.space) == 2)
    #expect(await h.transport.puts.allSatisfy { $0.rkey == "000002" })
    #expect(await !h.transport.roster.contains(KeyFixtures.bob))
  }

  @Test func unrotatedPendingRemovalRotatesBeforeACLOnRetry() async throws {
    let h = Harness()
    try await h.seed(versions: 1...1)
    await h.transport.setRoster([KeyFixtures.bob, KeyFixtures.carol])
    // A crash right after the entry was recorded, before the rotation landed.
    try await h.store.setPendingRewrap(spaceURI: KeyFixtures.space, did: "__acl__:did:plc:bob", reason: "aclRemovePending")

    try await h.manager.retryPendingRewraps(circle: KeyFixtures.circle)

    let events = await h.transport.events
    let put = try #require(events.firstIndex(of: "putKeyRecord:000002"))
    let remove = try #require(events.firstIndex(of: "removeMember:did:plc:bob"))
    #expect(put < remove)
    #expect(await h.crypto.wraps.last?.memberDIDs == [KeyFixtures.carol.didString()])
    #expect(try await h.store.pendingRewraps(spaceURI: KeyFixtures.space).isEmpty)
  }

  @Test func hiddenAddNewcomerNeverReceivesOlderVersionsViaLaterVisibleAdd() async throws {
    let h = Harness()
    let erin = try DID(didString: "did:plc:erin")
    try await h.seed(versions: 1...1)
    await h.transport.setRoster([KeyFixtures.bob])
    let service = CircleService(transport: h.transport, keyManager: h.manager)

    try await service.addMember(circle: KeyFixtures.circle, did: KeyFixtures.dave, historyVisible: false)
    #expect(try await h.store.joinedAtVersion(spaceURI: KeyFixtures.space, did: KeyFixtures.dave.didString()) == 2)
    try await service.addMember(circle: KeyFixtures.circle, did: erin, historyVisible: true)

    let wraps = await h.crypto.wraps
    let v1 = wraps.filter { $0.keyVersion == 1 }
    #expect(!v1.isEmpty)
    #expect(v1.allSatisfy { !$0.memberDIDs.contains(KeyFixtures.dave.didString()) })
    #expect(v1.allSatisfy { $0.memberDIDs.contains(erin.didString()) })
    let lastV2 = try #require(wraps.last { $0.keyVersion == 2 })
    #expect(lastV2.memberDIDs.contains(KeyFixtures.dave.didString()))
    #expect(lastV2.memberDIDs.contains(erin.didString()))
  }

  @Test func historyRetryKeepsPendingUntilAllVersionsSucceed() async throws {
    let h = Harness()
    try await h.seed(versions: 1...3)
    await h.transport.setRoster([KeyFixtures.bob])
    try await h.store.setPendingRewrap(
      spaceURI: KeyFixtures.space, did: KeyFixtures.bob.didString(), reason: "historyRewrapPending: rewrap failed"
    )
    await h.crypto.setFailingVersions([1])

    await #expect(throws: CircleError.upstreamUnavailable) {
      try await h.manager.retryPendingRewraps(circle: KeyFixtures.circle)
    }
    #expect(try await h.store.pendingRewraps(spaceURI: KeyFixtures.space).map(\.did) == [KeyFixtures.bob.didString()])

    await h.crypto.setFailingVersions([])
    try await h.manager.retryPendingRewraps(circle: KeyFixtures.circle)
    #expect(try await h.store.pendingRewraps(spaceURI: KeyFixtures.space).isEmpty)
    #expect(await h.transport.puts.map(\.rkey).suffix(3) == ["000003", "000002", "000001"])
  }
}

// MARK: - CircleKeyStore

@Suite("CircleKeyStore")
struct CircleKeyStoreTests {
  private let space = "at://did:plc:alice/space/blue.catbird.circle.encrypted/3enc"

  @Test func storeThenReadBack() async throws {
    let keychain = InMemoryCircleKeychain()
    let store = CircleKeyStore(accountDID: "did:plc:alice", keychain: keychain)
    let created = Date(timeIntervalSince1970: 1_800_000_000.123)
    let key = Data((0..<32).map { UInt8($0) })

    try await store.store(spaceURI: space, keyVersion: 1, circleKey: key, createdAt: created, reason: "created")

    #expect(try await store.key(spaceURI: space, keyVersion: 1) == key)
    #expect(try await store.key(spaceURI: space, keyVersion: 2) == nil)
    let meta = try #require(try await store.versionMeta(spaceURI: space, keyVersion: 1))
    #expect(abs(meta.createdAt.timeIntervalSince(created)) < 0.001)
    #expect(meta.reason == "created")

    // A fresh store over the same Keychain sees the same data (persistence).
    let reopened = CircleKeyStore(accountDID: "did:plc:alice", keychain: keychain)
    #expect(try await reopened.key(spaceURI: space, keyVersion: 1) == key)
  }

  @Test func latestVersionIsMax() async throws {
    let store = CircleKeyStore(accountDID: "did:plc:alice", keychain: InMemoryCircleKeychain())
    #expect(try await store.latestVersion(spaceURI: space) == nil)
    for version: UInt64 in [3, 1, 10, 2] {
      try await store.store(spaceURI: space, keyVersion: version, circleKey: Data(count: 32), createdAt: Date(), reason: "manualRotation")
    }
    #expect(try await store.latestVersion(spaceURI: space) == 10)
    #expect(try await store.allVersions(spaceURI: space) == [1, 2, 3, 10])
  }

  @Test func pendingRewrapRoundTrip() async throws {
    let store = CircleKeyStore(accountDID: "did:plc:alice", keychain: InMemoryCircleKeychain())
    try await store.setPendingRewrap(spaceURI: space, did: "did:plc:bob", reason: "directory unreachable")
    try await store.setPendingRewrap(spaceURI: space, did: "__acl__:did:plc:carol", reason: "aclRemovePending")
    try await store.setPendingRewrap(spaceURI: space, did: "did:plc:bob", reason: "epoch chain changed")

    let pending = try await store.pendingRewraps(spaceURI: space)
    #expect(pending.count == 2)
    #expect(pending.first { $0.did == "did:plc:bob" }?.reason == "epoch chain changed")

    try await store.clearPendingRewrap(spaceURI: space, did: "did:plc:bob")
    #expect(try await store.pendingRewraps(spaceURI: space).map(\.did) == ["__acl__:did:plc:carol"])
  }

  @Test func joinedAtVersionRoundTrip() async throws {
    let store = CircleKeyStore(accountDID: "did:plc:alice", keychain: InMemoryCircleKeychain())
    #expect(try await store.joinedAtVersion(spaceURI: space, did: "did:plc:dave") == 0)
    try await store.setJoinedAtVersion(spaceURI: space, did: "did:plc:dave", version: 4)
    #expect(try await store.joinedAtVersion(spaceURI: space, did: "did:plc:dave") == 4)
    try await store.setJoinedAtVersion(spaceURI: space, did: "did:plc:dave", version: 0)
    #expect(try await store.joinedAtVersions(spaceURI: space).isEmpty)
  }

  @Test func keychainItemIsDeviceOnlyAfterFirstUnlock() async throws {
    let keychain = InMemoryCircleKeychain()
    let store = CircleKeyStore(accountDID: "did:plc:alice", keychain: keychain)
    try await store.store(spaceURI: space, keyVersion: 1, circleKey: Data(count: 32), createdAt: Date(), reason: "created")

    let accounts = try keychain.accounts(service: CircleKeyStore.keychainService)
    #expect(accounts == ["did:plc:alice|\(space)"])
    #expect(
      keychain.accessibility(service: CircleKeyStore.keychainService, account: "did:plc:alice|\(space)")
        == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
    )
  }

  @Test func signOutWipesCircleKeys() async throws {
    let keychain = InMemoryCircleKeychain()
    let alice = CircleKeyStore(accountDID: "did:plc:alice", keychain: keychain)
    let bob = CircleKeyStore(accountDID: "did:plc:bob", keychain: keychain)
    try await alice.store(spaceURI: space, keyVersion: 1, circleKey: Data(count: 32), createdAt: Date(), reason: "created")
    try await alice.store(spaceURI: space + "2", keyVersion: 1, circleKey: Data(count: 32), createdAt: Date(), reason: "created")
    try await bob.store(spaceURI: space, keyVersion: 1, circleKey: Data(count: 32), createdAt: Date(), reason: "created")

    try CircleKeyStore.wipe(accountDID: "did:plc:alice", keychain: keychain)

    #expect(try await alice.latestVersion(spaceURI: space) == nil)
    #expect(try await alice.latestVersion(spaceURI: space + "2") == nil)
    #expect(try await bob.latestVersion(spaceURI: space) == 1)
  }
}

// MARK: - Fix wave 1 (C1 read-back, C2, C3, I1, I2)

private extension KeyFixtures {
  /// The real owner's Space, but the AppView claims `bob` owns it.
  static let lyingOwnerCircle = BlueCatbirdCircleDefs.CircleSummary(
    uri: spaceURI, circleId: circle.circleId, name: "Close", owner: bob, memberCount: 2, muted: nil
  )

  static func circle(latestKeyVersion: Int?) -> BlueCatbirdCircleDefs.CircleSummary {
    BlueCatbirdCircleDefs.CircleSummary(
      uri: spaceURI, circleId: circle.circleId, name: "Close", owner: owner, memberCount: 2, muted: nil,
      latestKeyVersion: latestKeyVersion
    )
  }

  static func recordJSON(version: UInt64, circleID: String = "3l7familycirc") -> String {
    ScriptedCircleCrypto.recordJSON(
      circleID: circleID, keyVersion: version, reason: "manualRotation", createdAt: Date(),
      head: Data(repeating: 0xA1, count: 32)
    )
  }
}

extension CircleKeyManagerTests {
  @Test("Read-back compares the served raw record to the written raw record, not typed re-encodings")
  func readBackComparesRawRecords() async throws {
    let h = Harness()
    try await h.seed(versions: 1...1)
    await h.transport.setRoster([KeyFixtures.bob])
    // A field the typed decode drops: a typed comparison would call these equal.
    await h.transport.setReadBackMutation { json in String(json.dropLast()) + ",\"futureField\":1}" }

    await #expect(throws: CircleError.keyVersionConflict) {
      _ = try await h.manager.rotate(circle: KeyFixtures.circle, reason: "manualRotation")
    }
    #expect(try await h.store.latestVersion(spaceURI: KeyFixtures.space) == 1)
  }

  @Test("Read-back accepts the same record in another serializer's key order")
  func readBackAcceptsReorderedKeys() async throws {
    let h = Harness()
    try await h.seed(versions: 1...1)
    await h.transport.setRoster([KeyFixtures.bob])
    await h.transport.setReadBackMutation { json in
      let object = try! JSONSerialization.jsonObject(with: Data(json.utf8))
      let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      return String(decoding: data, as: UTF8.self)
    }

    _ = try await h.manager.rotate(circle: KeyFixtures.circle, reason: "manualRotation")

    #expect(try await h.store.latestVersion(spaceURI: KeyFixtures.space) == 2)
  }

  @Test("A summary whose owner is not the Space authority is refused and nothing is opened or stored")
  func lyingOwnerIsRefused() async throws {
    let h = Harness()
    await h.transport.setKeyEntries([try makeKeyEntry(version: 1)])
    await h.crypto.setOpenable([1: Data(repeating: 0x11, count: 32)])

    await #expect(throws: CircleError.ownerMismatch) {
      _ = try await h.manager.refreshKeys(circle: KeyFixtures.lyingOwnerCircle)
    }
    await #expect(throws: CircleError.ownerMismatch) {
      _ = try await h.manager.keyForPosting(circle: KeyFixtures.lyingOwnerCircle)
    }
    #expect(await h.crypto.openedRecordJSONs.isEmpty)
    #expect(try await h.store.latestVersion(spaceURI: KeyFixtures.space) == nil)
    #expect(CircleError.ownerMismatch.errorDescription == "This Circle's data looks inconsistent. Try again later.")
  }

  @Test("A record relabelled with a newer version never replaces the held key")
  func relabelledRecordDoesNotOverwriteHeldKey() async throws {
    let h = Harness()
    try await h.seed(versions: 1...5)
    try await h.store.setRecordCID(spaceURI: KeyFixtures.space, keyVersion: 5, cid: "bafy-mine")
    // The AppView labels v3's genuine bytes as v5 with a made-up CID.
    await h.transport.setKeyEntries([try makeKeyEntry(version: 5)])
    await h.transport.setRawRecord(version: 5, json: KeyFixtures.recordJSON(version: 3))
    await h.crypto.setOpenable([3: Data(repeating: 0x33, count: 32)])

    _ = try await h.manager.refreshKeys(circle: KeyFixtures.circle)

    #expect(try await h.store.key(spaceURI: KeyFixtures.space, keyVersion: 5) == Data(repeating: 5, count: 32))
    #expect(try await h.store.recordCID(spaceURI: KeyFixtures.space, keyVersion: 5) == "bafy-mine")
  }

  @Test("A relabelled record is not stored under the label's version on a device without it")
  func relabelledRecordIsNotStored() async throws {
    let h = Harness()
    try await h.seed(versions: 1...4)
    await h.transport.setKeyEntries([try makeKeyEntry(version: 5)])
    await h.transport.setRawRecord(version: 5, json: KeyFixtures.recordJSON(version: 3))
    await h.crypto.setOpenable([3: Data(repeating: 0x33, count: 32)])

    _ = try await h.manager.refreshKeys(circle: KeyFixtures.circle)

    #expect(try await h.store.key(spaceURI: KeyFixtures.space, keyVersion: 5) == nil)
    #expect(try await h.store.latestVersion(spaceURI: KeyFixtures.space) == 4)
  }

  @Test("A record for another Circle is not stored")
  func foreignCircleRecordIsNotStored() async throws {
    let h = Harness()
    await h.transport.setKeyEntries([try makeKeyEntry(version: 1)])
    await h.transport.setRawRecord(version: 1, json: KeyFixtures.recordJSON(version: 1, circleID: "3l7othercircl"))
    await h.crypto.setOpenable([1: Data(repeating: 0x11, count: 32)])

    _ = try await h.manager.refreshKeys(circle: KeyFixtures.circle)

    #expect(try await h.store.latestVersion(spaceURI: KeyFixtures.space) == nil)
  }

  @Test("getKeys is paged until the server's latest version")
  func pagedGetKeysReachesLatest() async throws {
    let h = Harness()
    await h.transport.setKeyEntries(try (1...5).map { try makeKeyEntry(version: $0) })
    await h.transport.setPaging(size: 2)
    await h.crypto.setOpenable(Dictionary(uniqueKeysWithValues: (1...5).map { (UInt64($0), Data(repeating: UInt8($0), count: 32)) }))

    let latest = try await h.manager.refreshKeys(circle: KeyFixtures.circle)

    #expect(latest == 5)
    #expect(await h.transport.getKeysSince == [nil, 2, 4])
    let posting = try await h.manager.keyForPosting(circle: KeyFixtures.circle(latestKeyVersion: nil))
    #expect(posting.version == 5)
  }

  @Test("A page with skipped rows does not abort the sync")
  func skippedRowsDoNotAbortSync() async throws {
    let h = Harness()
    await h.transport.setKeyEntries([try makeKeyEntry(version: 1), try makeKeyEntry(version: 3)])
    await h.transport.setPaging(size: nil, skipped: 1)
    await h.crypto.setOpenable([1: Data(repeating: 1, count: 32), 3: Data(repeating: 3, count: 32)])

    let latest = try await h.manager.refreshKeys(circle: KeyFixtures.circle)

    #expect(latest == 3)
    #expect(try await h.store.key(spaceURI: KeyFixtures.space, keyVersion: 1) != nil)
  }

  @Test("One record that fails to open does not block later versions")
  func badRecordDoesNotBlockLaterVersions() async throws {
    let h = Harness()
    try await h.seed(versions: 1...1)
    await h.transport.setKeyEntries(try (1...3).map { try makeKeyEntry(version: $0) })
    await h.crypto.setThrowingOpens([2])
    await h.crypto.setOpenable([3: Data(repeating: 3, count: 32)])

    let posting = try await h.manager.keyForPosting(circle: KeyFixtures.circle(latestKeyVersion: nil))

    #expect(posting.version == 3)
    #expect(try await h.store.key(spaceURI: KeyFixtures.space, keyVersion: 2) == nil)
  }

  @Test("D13: posting refreshes keys before every post; a summary naming the held version is not trusted")
  func postingRefreshesKeysBeforeEveryPost() async throws {
    let h = Harness()
    try await h.seed(versions: 1...3)
    await h.transport.setKeyEntries(try (1...4).map { try makeKeyEntry(version: $0) })
    await h.crypto.setOpenable([4: Data(repeating: 4, count: 32)])

    // The summary says 3 (what this device holds); the server has 4.
    let posting = try await h.manager.keyForPosting(circle: KeyFixtures.circle(latestKeyVersion: 3))

    #expect(posting.version == 4)
    #expect(posting.key == Data(repeating: 4, count: 32))
    #expect(await h.transport.getKeysSince == [3])

    // Nothing newer: still one small incremental request per post.
    let again = try await h.manager.keyForPosting(circle: KeyFixtures.circle(latestKeyVersion: 4))
    #expect(again.version == 4)
    #expect(await h.transport.getKeysSince == [3, 4])
  }
}

@Suite("Circle keychain query (I6)")
struct CircleKeychainQueryTests {
  @Test func usesDataProtectionKeychainAndKeepsDeviceOnlyAccess() {
    let query = SystemCircleKeychain.baseQuery(service: "blue.catbird.circle", account: "a")
    #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
    #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
    #expect(query[kSecAttrAccount as String] as? String == "a")
    #expect(CircleKeyStore.accessibility == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
  }
}

// MARK: - Fix wave 2 (C3 via FFI, Rust owner mismatch, I3 classes, I7 read-back types)

extension CircleKeyManagerTests {
  @Test("C3 via FFI: a key is stored under the version the FFI authenticated, never the record's own field")
  func authenticatedVersionFromFFIDecides() async throws {
    let h = Harness()
    await h.transport.setKeyEntries([try makeKeyEntry(version: 2)])
    await h.crypto.setOpenable([2: Data(repeating: 0x22, count: 32)])
    // The record's fields and label say v2; the wrap's AAD authenticated v3.
    await h.crypto.setAuthenticatedIdentity([2: (circleID: KeyFixtures.circle.circleId.description, keyVersion: 3)])

    _ = try await h.manager.refreshKeys(circle: KeyFixtures.circle)

    #expect(try await h.store.key(spaceURI: KeyFixtures.space, keyVersion: 2) == nil)
    #expect(try await h.store.key(spaceURI: KeyFixtures.space, keyVersion: 3) == nil)
    #expect(try await h.store.latestVersion(spaceURI: KeyFixtures.space) == nil)
  }

  @Test("C3 via FFI: a key whose authenticated Circle differs is not stored")
  func authenticatedCircleFromFFIDecides() async throws {
    let h = Harness()
    await h.transport.setKeyEntries([try makeKeyEntry(version: 1)])
    await h.crypto.setOpenable([1: Data(repeating: 0x11, count: 32)])
    await h.crypto.setAuthenticatedIdentity([1: (circleID: "3l7othercircl", keyVersion: 1)])

    _ = try await h.manager.refreshKeys(circle: KeyFixtures.circle)

    #expect(try await h.store.latestVersion(spaceURI: KeyFixtures.space) == nil)
  }

  @Test("The Rust owner/Space check (.untrusted) surfaces as ownerMismatch")
  func rustOwnerMismatchSurfacesAsOwnerMismatch() async throws {
    let h = Harness()
    await h.transport.setKeyEntries([try makeKeyEntry(version: 1)])
    await h.crypto.setOpenErrors([1: .untrusted("owner is not the space authority")])

    await #expect(throws: CircleError.ownerMismatch) {
      _ = try await h.manager.refreshKeys(circle: KeyFixtures.circle)
    }
    await #expect(throws: CircleError.ownerMismatch) {
      _ = try await h.manager.keyForPosting(circle: KeyFixtures.circle)
    }
    #expect(CircleService.postingKeyError(CircleError.ownerMismatch) == .ownerMismatch)
  }

  @Test("I3: an untrusted record is skipped (retryable), later versions still open")
  func untrustedRecordIsSkipped() async throws {
    let h = Harness()
    await h.transport.setKeyEntries(try (1...2).map { try makeKeyEntry(version: $0) })
    await h.crypto.setOpenErrors([1: .untrusted("directory fork")])
    await h.crypto.setOpenable([2: Data(repeating: 2, count: 32)])

    let latest = try await h.manager.refreshKeys(circle: KeyFixtures.circle)

    #expect(latest == 2)
    #expect(try await h.store.key(spaceURI: KeyFixtures.space, keyVersion: 1) == nil)
  }

  @Test("I3: a transient (.unavailable) open aborts the sync and stores nothing after it")
  func transientOpenAbortsSync() async throws {
    let h = Harness()
    await h.transport.setKeyEntries(try (1...3).map { try makeKeyEntry(version: $0) })
    await h.crypto.setOpenErrors([2: .unavailable("directory unreachable")])
    await h.crypto.setOpenable([1: Data(repeating: 1, count: 32), 3: Data(repeating: 3, count: 32)])

    await #expect(throws: CircleCryptoError.unavailable("directory unreachable")) {
      _ = try await h.manager.refreshKeys(circle: KeyFixtures.circle)
    }
    #expect(try await h.store.key(spaceURI: KeyFixtures.space, keyVersion: 3) == nil)

    // Posting maps it to the retryable state, never "keys unavailable".
    do {
      _ = try await h.manager.keyForPosting(circle: KeyFixtures.circle)
      Issue.record("posting must not proceed past a transient key failure")
    } catch {
      #expect(CircleService.postingKeyError(error) == .keysTemporarilyUnavailable)
    }
  }

  @Test("I3: posting errors keep their class")
  func postingKeyErrorClasses() {
    #expect(CircleService.postingKeyError(URLError(.notConnectedToInternet)) == .keysTemporarilyUnavailable)
    #expect(CircleService.postingKeyError(CircleError.networkError("x")) == .keysTemporarilyUnavailable)
    #expect(CircleService.postingKeyError(CircleCryptoError.unavailable("x")) == .keysTemporarilyUnavailable)
    #expect(CircleService.postingKeyError(CircleKeychainError.status(errSecInteractionNotAllowed)) == .keyStoreUnavailable)
    #expect(CircleService.postingKeyError(CircleCryptoError.notOpenable("x")) == .encryptionUnavailable)
    #expect(CircleService.postingKeyError(CircleCryptoError.malformed("x")) == .encryptionUnavailable)
    #expect(CircleService.postingKeyError(CircleError.encryptionUnavailable) == .encryptionUnavailable)
    #expect(CircleService.postingKeyError(CircleCryptoError.untrusted("owner is not the space authority")) == .ownerMismatch)
    #expect(CircleError.keysTemporarilyUnavailable.errorDescription != CircleError.encryptionUnavailable.errorDescription)
    #expect(CircleError.keyStoreUnavailable.errorDescription != CircleError.encryptionUnavailable.errorDescription)
  }

  @Test("Read-back keeps JSON types: true is not 1, member order still does not matter")
  func readBackComparisonKeepsJSONTypes() {
    #expect(!CircleKeyManager.sameJSON(#"{"a":true}"#, #"{"a":1}"#))
    #expect(!CircleKeyManager.sameJSON(#"{"a":{"b":false}}"#, #"{"a":{"b":0}}"#))
    #expect(CircleKeyManager.sameJSON(#"{"a":1,"b":[true,"x"]}"#, #"{ "b": [true, "x"], "a": 1 }"#))
    #expect(!CircleKeyManager.sameJSON(#"{"a":1}"#, #"{"a":1,"b":null}"#))
    #expect(!CircleKeyManager.sameJSON("[1]", "[1]"))
  }

  @Test("A read-back whose value changed JSON type (1 → true) is a conflict")
  func readBackTypeChangeIsConflict() async throws {
    let h = Harness()
    await h.transport.setReadBackMutation { json in
      json.replacingOccurrences(of: "\"keyVersion\":1", with: "\"keyVersion\":true")
    }

    await #expect(throws: CircleError.keyVersionConflict) {
      _ = try await h.manager.createInitialKey(circle: KeyFixtures.circle, memberDIDs: [KeyFixtures.bob])
    }
    #expect(try await h.store.latestVersion(spaceURI: KeyFixtures.space) == nil)
  }
}
