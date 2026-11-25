//
//  CircleTestSupport.swift
//  CatbirdTests
//

import CatbirdMLSCore
import Foundation
import Petrel
import PetrelCatbird
@testable import Catbird
#if canImport(UIKit)
import UIKit
#endif

/// An age checker for a region with no age requirement, so tests that post,
/// like or reply are not stopped by the platform age gate.
struct NoAgeRequirement: AgeRegulatoryChecking {
  func preflight() async -> PlatformAgeSignal { .none }
  #if canImport(UIKit)
  func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
  #endif
}

/// An `AppState` whose age gate has already confirmed there is no age
/// requirement, so ordinary writes are allowed.
@MainActor
func writableTestAppState(userDID: String = "did:plc:testuser", client: ATProtoClient) async -> AppState {
  let appState = AppState(userDID: userDID, client: client, regulatoryChecker: NoAgeRequirement())
  await appState.ageAccess.refreshRequirements()
  return appState
}

/// What a scripted `openCircleKey` returns: the key for the record's own
/// `keyVersion` (if openable) with the record's `circleId`/`keyVersion` as the
/// "authenticated" identity, as the FFI returns it from the wrap's AAD.
/// `identity` overrides that identity per version (a record whose AAD
/// authenticates something other than its fields).
enum ScriptedKeyOpen {
  static func open(
    recordJSON: String, openable: [UInt64: Data], identity: [UInt64: (circleID: String, keyVersion: UInt64)] = [:]
  ) throws -> OpenedCircleKey? {
    guard
      let object = try JSONSerialization.jsonObject(with: Data(recordJSON.utf8)) as? [String: Any],
      let version = object["keyVersion"] as? Int,
      let key = openable[UInt64(version)]
    else { return nil }
    let authenticated = identity[UInt64(version)]
      ?? (circleID: object["circleId"] as? String ?? "", keyVersion: UInt64(version))
    return OpenedCircleKey(circleKey: key, circleID: authenticated.circleID, keyVersion: authenticated.keyVersion)
  }
}

extension CircleRawRecordCache {
  /// Test fixtures build typed envelopes; their "served" bytes are this
  /// encoding, registered so the opener finds them.
  static func registerFixture(_ record: BlueCatbirdCirclePost, uri: ATProtocolURI, cid: CID) {
    if let raw = try? JSONEncoder().encode(record) { shared.register(raw: raw, uri: uri, cid: cid) }
  }
}

// MARK: - Test Transport Double

actor MockCircleTransport: CircleTransport {
  var feedItems: [BlueCatbirdCircleDefs.FeedItem] = []
  var nextCursor: String?
  var lastQueriedSpace: SpaceRef?
  var lastQueriedCursor: String?
  var feedCallCount: Int = 0
  var errorToThrow: (any Error)?
  var onGetFeed: (@Sendable () async -> Void)?
  var onListCircles: (@Sendable () async -> Void)?
  var notifications: [BlueCatbirdCircleDefs.Notification] = []
  var onListNotifications: (@Sendable () async -> Void)?
  var onMedia: (@Sendable () async -> Void)?
  var mediaData: Data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAKeyNrvgAAAABJRU5ErkJggg==")!
  var lastMediaSpace: SpaceRef?
  var lastMediaAuthorDID: DID?
  var lastMediaCID: CID?
  var mediaCallCount: Int = 0
  var threadPage: CircleThreadPage?
  var threadCallCount: Int = 0
  let publicEndpointCallCount: Int = 0

  init(
    feedItems: [BlueCatbirdCircleDefs.FeedItem] = [],
    nextCursor: String? = nil,
    errorToThrow: (any Error)? = nil,
    threadPage: CircleThreadPage? = nil
  ) {
    self.feedItems = feedItems
    self.nextCursor = nextCursor
    self.errorToThrow = errorToThrow
    self.threadPage = threadPage
  }

  func setFeedItems(_ items: [BlueCatbirdCircleDefs.FeedItem], cursor: String?) {
    self.feedItems = items
    self.nextCursor = cursor
  }

  func setOnGetFeed(_ action: (@Sendable () async -> Void)?) {
    self.onGetFeed = action
  }

  func setOnListCircles(_ action: (@Sendable () async -> Void)?) { onListCircles = action }

  func setNotifications(_ notifications: [BlueCatbirdCircleDefs.Notification]) { self.notifications = notifications }

  func setOnListNotifications(_ action: (@Sendable () async -> Void)?) { onListNotifications = action }

  func setOnMedia(_ action: (@Sendable () async -> Void)?) { onMedia = action }

  func setMediaData(_ data: Data) { mediaData = data }

  func capabilities() async throws -> CircleCapability {
    CircleCapability(enabled: true, protocolRevision: CircleConfiguration.protocolRevision, supportsImages: true)
  }

  func listCircles(cursor: String?) async throws -> CircleListPage {
    if let onListCircles { await onListCircles() }
    return CircleListPage(circles: [CircleTestFixtures.family, CircleTestFixtures.work], cursor: nil)
  }

  func getFeed(space: SpaceRef?, cursor: String?) async throws -> CircleFeedPage {
    if let onGetFeed {
      await onGetFeed()
    }
    if let errorToThrow { throw errorToThrow }
    feedCallCount += 1
    lastQueriedSpace = space
    lastQueriedCursor = cursor
    return CircleFeedPage(items: feedItems, cursor: nextCursor)
  }

  func getPostThread(uri: ATProtocolURI, space: SpaceRef) async throws -> CircleThreadPage {
    if let errorToThrow { throw errorToThrow }
    threadCallCount += 1
    if let threadPage {
      return threadPage
    }
    let author = AppBskyActorDefs.ProfileViewBasic(
      did: CircleTestFixtures.alice,
      handle: try! Handle(handleString: "alice.test"),
      displayName: "Alice",
      pronouns: nil,
      avatar: nil,
      associated: nil,
      viewer: nil,
      labels: nil,
      createdAt: nil,
      verification: nil,
      status: nil,
      debug: nil
    )
    let post = AppBskyFeedDefs.PostView(
      uri: uri,
      cid: CIDString(CID.fromDAGCBOR(Data("cid-thread".utf8))),
      author: author,
      record: .knownType(
        AppBskyFeedPost(
          text: "Thread post in space",
          entities: nil,
          facets: nil,
          reply: nil,
          embed: nil,
          langs: nil,
          labels: nil,
          tags: nil,
          createdAt: ATProtocolDate(date: Date())
        )
      ),
      embed: nil,
      bookmarkCount: nil,
      replyCount: 0,
      repostCount: 0,
      likeCount: 0,
      quoteCount: nil,
      indexedAt: ATProtocolDate(date: Date()),
      viewer: nil,
      labels: nil,
      threadgate: nil,
      debug: nil
    )
    let thread = AppBskyFeedDefs.ThreadViewPost(post: post, parent: nil, replies: nil, threadContext: nil)
    return CircleThreadPage(thread: thread, circle: CircleTestFixtures.family)
  }

  func listNotifications(cursor: String?) async throws -> CircleNotificationPage {
    if let onListNotifications { await onListNotifications() }
    return CircleNotificationPage(notifications: notifications, cursor: nil)
  }

  func media(space: SpaceRef, authorDID: DID, cid: CID) async throws -> Data {
    if let onMedia { await onMedia() }
    if let errorToThrow { throw errorToThrow }
    mediaCallCount += 1
    lastMediaSpace = space
    lastMediaAuthorDID = authorDID
    lastMediaCID = cid
    return mediaData
  }

  func updatePreferences(space: SpaceRef, muted: Bool) async throws -> Bool {
    muted
  }

  func report(post: ATProtocolURI, circle: CircleSummary, reason: CircleReportReason, details: String?) async throws -> UUID {
    UUID()
  }

  func activateCircle(space: SpaceRef) async throws -> CircleSummary {
    CircleTestFixtures.family
  }

  func publishPost(destination: CircleSummary, draft: CirclePostDraft) async throws -> ATProtocolURI {
    try! ATProtocolURI(uriString: "\(destination.uri.uriString())/\(destination.owner.didString())/app.bsky.feed.post/123")
  }

  func like(post: AppBskyFeedDefs.PostView, circle: CircleSummary) async throws -> ATProtocolURI {
    try! ATProtocolURI(uriString: "\(circle.uri.uriString())/\(circle.owner.didString())/app.bsky.feed.like/123")
  }

  func deletePost(uri: ATProtocolURI, circle: CircleSummary) async throws {}
  func deleteLike(uri: ATProtocolURI, circle: CircleSummary) async throws {}

  func createSpace(skey: String, circleId: String, name: String, memberDIDs: [DID]) async throws -> CircleSummary {
    CircleTestFixtures.family
  }
  func deleteSpace(space: SpaceRef) async throws {}
  func addMember(space: SpaceRef, did: DID) async throws {}
  func removeMember(space: SpaceRef, did: DID) async throws {}
  func listMembers(space: SpaceRef) async throws -> [CircleMember] {
    []
  }
}

// MARK: - Test Feed Item Helper

func makeFeedItem(circle: CircleSummary, rkey: String, text: String) -> BlueCatbirdCircleDefs.FeedItem {
  let author = AppBskyActorDefs.ProfileViewBasic(
    did: circle.owner,
    handle: try! Handle(handleString: "\(circle.name.lowercased()).test"),
    displayName: "\(circle.name) Author",
    pronouns: nil,
    avatar: nil,
    associated: nil,
    viewer: nil,
    labels: nil,
    createdAt: nil,
    verification: nil,
    status: nil,
    debug: nil
  )
  let postView = AppBskyFeedDefs.PostView(
    uri: try! ATProtocolURI(uriString: "\(circle.uri.uriString())/\(circle.owner.didString())/app.bsky.feed.post/\(rkey)"),
    cid: CIDString(CID.fromDAGCBOR(Data("cid-\(rkey)".utf8))),
    author: author,
    record: .knownType(
      AppBskyFeedPost(
        text: text,
        entities: nil,
        facets: nil,
        reply: nil,
        embed: nil,
        langs: nil,
        labels: nil,
        tags: nil,
        createdAt: ATProtocolDate(date: Date())
      )
    ),
    embed: nil,
    bookmarkCount: nil,
    replyCount: 0,
    repostCount: 0,
    likeCount: 0,
    quoteCount: nil,
    indexedAt: ATProtocolDate(date: Date()),
    viewer: nil,
    labels: nil,
    threadgate: nil,
    debug: nil
  )
  let feedViewPost = AppBskyFeedDefs.FeedViewPost(
    post: postView,
    reply: nil,
    reason: nil,
    feedContext: nil,
    reqId: nil
  )
  return BlueCatbirdCircleDefs.FeedItem(post: .init(feedViewPost), circle: circle)
}

// MARK: - Test Synchronization Barrier

actor CircleAsyncGate {
  private var enteredContinuations: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
  private var isEntered = false
  private var isReleased = false

  func enter() async {
    isEntered = true
    for continuation in enteredContinuations {
      continuation.resume()
    }
    enteredContinuations.removeAll()

    if !isReleased {
      await withCheckedContinuation { continuation in
        releaseContinuations.append(continuation)
      }
    }
  }

  func awaitEntry() async {
    if isEntered { return }
    await withCheckedContinuation { continuation in
      enteredContinuations.append(continuation)
    }
  }

  func release() {
    isReleased = true
    for continuation in releaseContinuations {
      continuation.resume()
    }
    releaseContinuations.removeAll()
  }
}

// MARK: - getKeys responses for doubles

extension CircleKeysResponse {
  /// A response over typed entries. Each record's raw JSON is `raw[version]`
  /// when given, else Petrel's encoding (fine for crypto doubles that do not
  /// inspect exact bytes; `keyRecordPassedToFFIIsRawServerJSON` covers those).
  static func testing(
    _ entries: [BlueCatbirdCircleGetKeys.KeyEntry], latest: Int, raw: [Int: String] = [:], skipped: Int = 0
  ) -> CircleKeysResponse {
    CircleKeysResponse(
      entries: entries.map { entry in
        let json = raw[entry.keyVersion]
          ?? String(decoding: (try? JSONEncoder().encode(entry.record)) ?? Data(), as: UTF8.self)
        return Entry(typed: entry, recordJSON: json)
      },
      latestKeyVersion: latest,
      skipped: skipped
    )
  }
}
