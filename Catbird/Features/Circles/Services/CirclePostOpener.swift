import CatbirdMLSCore
import CryptoKit
import Foundation
import OSLog
import Petrel
import PetrelCatbird

// MARK: - Results

/// The key for one encrypted media blob of an opened Circle post, taken from
/// the sealed payload (spec §4.3). `key` is raw key material: never log it.
/// Lives in memory only (the opened-post store and `CircleMediaLoader`).
struct CircleMediaKeyRef: Sendable {
  let cid: CID
  let key: Data
  let iv: Data
  /// Hex SHA-256 of the CIPHERTEXT, checked before decrypting.
  let sha256: String
  /// MIME type of the plaintext.
  let mimeType: String
  let alt: String?
  let width: Int?
  let height: Int?
}

/// The decrypted content of one opened envelope: the only decrypted state
/// memoized (memory only, in `CircleFeedCache`). Views are re-synthesized
/// from the current envelope on every open, so counts and viewer state stay live.
struct CircleOpenedPayload: Sendable {
  let post: AppBskyFeedPost
  let media: [CircleMediaKeyRef]
  /// The circle key version the post opened under (I8: a report discloses
  /// the post key derived from it).
  var keyVersion: UInt64 = 0
}

/// The outcome of opening one Circle feed item or thread node.
enum CircleOpenedItem: Sendable {
  /// Plaintext, or an envelope that opened. The synthesized post carries the
  /// envelope view's counts and viewer state, and an images embed whose URIs
  /// name the blob CIDs (rendered only through `CircleMediaView`).
  case post(AppBskyFeedDefs.FeedViewPost, media: [CircleMediaKeyRef])
  /// Sealed under a key version newer than any this device holds (§6 rule 9):
  /// held unread and retried after a key refresh, never discarded.
  case pendingKey(uri: ATProtocolURI, keyVersion: UInt64)
  /// Failed the signature/AEAD/consistency checks, names an unknown author
  /// epoch, belongs to another Circle, or needs a key this device will never
  /// hold (an older version with history hidden).
  case unverifiable(uri: ATProtocolURI)
  /// Sealed under a key version older than the earliest this device holds:
  /// the post predates this member's access (history hidden when they were
  /// added), so it is not a verification failure (I12).
  case postedBeforeJoined(uri: ATProtocolURI, keyVersion: UInt64)
  /// This device's key store could not be read (for example the Keychain
  /// before first unlock). Not a verdict on the post; never memoized (I3).
  case unavailable(uri: ATProtocolURI)
  /// A transient failure (offline, directory or session unavailable, the
  /// served record bytes not at hand): shown as "Waiting…" and opened again
  /// next time; never memoized (I3).
  case retryLater(uri: ATProtocolURI)

  var feedViewPost: AppBskyFeedDefs.FeedViewPost? {
    if case .post(let post, _) = self { return post }
    return nil
  }

  var isPendingKey: Bool {
    if case .pendingKey = self { return true }
    return false
  }
}

// MARK: - Opener

/// Opens Circle feed items and thread nodes (spec §4.2, §4.5, §6 rule 9).
///
/// One per account (`AppState.circlePostOpener()`), shared by feeds and
/// threads:
/// - Plaintext items pass through as `.post`.
/// - An envelope (the feed union's `encryptedPostView`, or a thread `PostView`
///   whose record is a `blue.catbird.circle.post`) opens with the stored key
///   for its `keyVersion` and the author epoch named by `authorEpochHead`.
///   A version newer than any held → `.pendingKey`; a Keychain failure →
///   `.unavailable`; a transient failure → `.retryLater`; a rejected or
///   untrusted post → `.unverifiable` (`CircleOpenFailure`). Never throws.
/// - The FFI gets the record's exact served bytes (`CircleRawRecordCache`),
///   never a Petrel re-encoding.
/// - The Circle, keyVersion and canonical-URI guards run before any memo.
/// - At most `maxConcurrentOpens` (2) author-epoch fetch + `openPost` pairs
///   run at once; opens of the same `(space, uri, cid)` are de-duplicated while
///   in flight. The decrypted PAYLOAD is memoized in `CircleFeedCache`'s
///   per-account opened store (the only place decrypted content is kept;
///   memory only, purged with the account or Space, never returned for another
///   Space); the view is re-synthesized from the current envelope every time.
/// - Rejected opens (`notOpenable`/`malformed`) and malformed payloads are
///   memoized per `(space, uri, cid, keyVersion, authorEpochHead, key
///   fingerprint)` for `failedOpenTTL`; nothing else is.
/// - Media keys of an opened post are registered with `CircleMediaLoader`
///   (memory only) so `CircleMediaView` can decrypt the blobs.
///
/// Plaintext, keys and FFI messages are never logged.
actor CirclePostOpener {
  static let defaultMaxConcurrentOpens = 2

  private struct Envelope: Sendable {
    let uri: ATProtocolURI
    let cid: CIDString
    let author: AppBskyActorDefs.ProfileViewBasic
    let record: BlueCatbirdCirclePost
    let indexedAt: ATProtocolDate
    let likeCount: Int?
    let replyCount: Int?
    let repostCount: Int?
    let viewer: AppBskyFeedDefs.ViewerState?
    let labels: [ComAtprotoLabelDefs.Label]?
  }

  private let logger = Logger(subsystem: "blue.catbird", category: "CirclePostOpener")
  private let crypto: any CircleCrypto
  private let keys: CircleKeyManager
  private let epochs: any AuthorEpochResolver
  private let accountDID: String
  private let cache: CircleFeedCache
  private let mediaLoader: CircleMediaLoader?
  private let limiter: CircleOpenLimiter
  private let rawRecords: CircleRawRecordCache
  private var inFlight: [String: Task<Outcome, Never>] = [:]
  private var failedOpens: [String: Date] = [:]

  init(
    crypto: any CircleCrypto,
    keys: CircleKeyManager,
    epochs: any AuthorEpochResolver,
    accountDID: String = "",
    cache: CircleFeedCache = .shared,
    mediaLoader: CircleMediaLoader? = .shared,
    rawRecords: CircleRawRecordCache = .shared,
    maxConcurrentOpens: Int = CirclePostOpener.defaultMaxConcurrentOpens
  ) {
    self.rawRecords = rawRecords
    self.crypto = crypto
    self.keys = keys
    self.epochs = epochs
    self.accountDID = accountDID
    self.cache = cache
    self.mediaLoader = mediaLoader
    self.limiter = CircleOpenLimiter(limit: maxConcurrentOpens)
  }

  // MARK: Public API

  func open(_ item: BlueCatbirdCircleDefs.FeedItem, circle: CircleSummary) async -> CircleOpenedItem {
    switch item.post {
    case .appBskyFeedDefsFeedViewPost(let post):
      return .post(post, media: [])
    case .blueCatbirdCircleDefsEncryptedPostView(let view):
      return await open(
        envelope: Envelope(
          uri: view.uri, cid: view.cid, author: view.author, record: view.record, indexedAt: view.indexedAt,
          likeCount: view.likeCount, replyCount: view.replyCount, repostCount: nil, viewer: view.viewer, labels: nil
        ),
        circle: circle
      )
    case .unexpected:
      return .unverifiable(uri: Self.unknownURI)
    }
  }

  /// A thread node: encrypted nodes are ordinary `PostView`s whose record is a
  /// `blue.catbird.circle.post`; anything else passes through.
  func open(postView: AppBskyFeedDefs.PostView, circle: CircleSummary) async -> CircleOpenedItem {
    guard let record = Self.circlePostRecord(postView.record) else {
      return .post(AppBskyFeedDefs.FeedViewPost(post: postView), media: [])
    }
    return await open(
      envelope: Envelope(
        uri: postView.uri, cid: postView.cid, author: postView.author, record: record,
        indexedAt: postView.indexedAt, likeCount: postView.likeCount, replyCount: postView.replyCount,
        repostCount: postView.repostCount, viewer: postView.viewer, labels: postView.labels
      ),
      circle: circle
    )
  }

  /// Fetches every key record for `circle` (see `CircleKeyManager.refreshKeys`);
  /// the newest version held afterwards, or nil.
  func refreshKeys(circle: CircleSummary) async -> UInt64? {
    do {
      return try await keys.refreshKeys(circle: circle)
    } catch {
      logger.error("Circles: key refresh failed (\(String(describing: type(of: error)), privacy: .public))")
      return try? await keys.latestLocalVersion(circle: circle)
    }
  }

  /// Opens a batch (one feed page or one thread) under §6 rule 9: items
  /// pending a newer key trigger exactly one `refreshKeys` per Circle, then the
  /// ones the refresh made openable are opened again.
  func openBatch(
    _ requests: [CircleOpenRequest]
  ) async -> [ATProtocolURI: CircleOpenedItem] {
    var results = await openConcurrently(requests)

    var pendingByCircle: [String: (circle: CircleSummary, requests: [CircleOpenRequest])] = [:]
    for request in requests {
      guard case .pendingKey? = results[request.uri] else { continue }
      pendingByCircle[request.circle.uri.uriString(), default: (request.circle, [])].requests.append(request)
    }
    for (_, entry) in pendingByCircle {
      guard let latest = await refreshKeys(circle: entry.circle) else { continue }
      let retry = entry.requests.filter { request in
        if case .pendingKey(_, let version)? = results[request.uri] { return version <= latest }
        return false
      }
      guard !retry.isEmpty else { continue }
      for (uri, item) in await openConcurrently(retry) { results[uri] = item }
    }
    return results
  }

  // MARK: Opening

  private func openConcurrently(_ requests: [CircleOpenRequest]) async -> [ATProtocolURI: CircleOpenedItem] {
    await withTaskGroup(of: (ATProtocolURI, CircleOpenedItem).self) { group in
      for request in requests {
        group.addTask {
          switch request {
          case .feedItem(let item):
            return (request.uri, await self.open(item, circle: item.circle))
          case .threadNode(let postView, let circle):
            return (request.uri, await self.open(postView: postView, circle: circle))
          }
        }
      }
      var collected: [ATProtocolURI: CircleOpenedItem] = [:]
      for await (uri, item) in group { collected[uri] = item }
      return collected
    }
  }

  /// What opening an envelope produced, independent of the envelope's view
  /// state (counts, viewer), which is re-applied on every call.
  private enum Outcome: Sendable {
    case payload(CircleOpenedPayload)
    case pendingKey(UInt64)
    case unverifiable
    case postedBeforeJoined(UInt64)
    case unavailable
    case retryLater
  }

  private func open(envelope: Envelope, circle: CircleSummary) async -> CircleOpenedItem {
    let uri = envelope.uri
    // Guards run before any memo lookup: a memo never vouches for an envelope
    // presented under another Circle or at a non-canonical URI.
    guard envelope.record.circleId.description == circle.circleId.description,
          envelope.record.keyVersion > 0,
          Self.isCanonical(uri: uri, authorDID: envelope.author.did)
    else { return .unverifiable(uri: uri) }

    let generation = cache.generation(accountDID: accountDID)
    if let memo = cache.openedPayload(accountDID: accountDID, space: circle.uri, uri: uri, cid: envelope.cid) {
      await register(memo.media, circle: circle, authorDID: envelope.author.did, generation: generation)
      return .post(Self.feedViewPost(envelope, payload: memo), media: memo.media)
    }
    let flightKey = "\(circle.uri.uriString())|\(uri.uriString())|\(envelope.cid.string)"
    let outcome: Outcome
    if let running = inFlight[flightKey] {
      outcome = await running.value
    } else {
      let task = Task { await self.perform(envelope: envelope, circle: circle, generation: generation) }
      inFlight[flightKey] = task
      outcome = await task.value
      inFlight[flightKey] = nil
    }

    switch outcome {
    case .payload(let payload):
      return .post(Self.feedViewPost(envelope, payload: payload), media: payload.media)
    case .pendingKey(let version):
      return .pendingKey(uri: uri, keyVersion: version)
    case .unverifiable:
      return .unverifiable(uri: uri)
    case .postedBeforeJoined(let version):
      return .postedBeforeJoined(uri: uri, keyVersion: version)
    case .unavailable:
      return .unavailable(uri: uri)
    case .retryLater:
      return .retryLater(uri: uri)
    }
  }

  private func perform(envelope: Envelope, circle: CircleSummary, generation: UUID) async -> Outcome {
    let version = UInt64(envelope.record.keyVersion)

    let circleKey: Data
    do {
      guard let key = try await keys.key(circle: circle, version: version) else {
        let latest = try await keys.latestLocalVersion(circle: circle) ?? 0
        if version > latest { return .pendingKey(version) }
        if let earliest = try await keys.earliestLocalVersion(circle: circle), version < earliest {
          return .postedBeforeJoined(version)
        }
        return .unverifiable
      }
      circleKey = key
    } catch {
      // I3: the local key store failed (e.g. the Keychain before first
      // unlock). Not a verdict on the post, so not memoized.
      logger.error("Circles: key lookup failed (\(String(describing: type(of: error)), privacy: .public))")
      return .unavailable
    }

    let failureKey = Self.failureKey(envelope, space: circle.uri, circleKey: circleKey)
    if let failedAt = failedOpens[failureKey] {
      if Date().timeIntervalSince(failedAt) < Self.failedOpenTTL { return .unverifiable }
      failedOpens[failureKey] = nil
    }

    // Raw-bytes contract: the record exactly as the AppView served it.
    guard let rawRecord = rawRecords.record(uri: envelope.uri, cid: envelope.cid, envelope: envelope.record) else {
      logger.notice("Circles: the served record bytes are not at hand; opened again on the next load")
      return .retryLater
    }
    let recordJSON = String(decoding: rawRecord, as: UTF8.self)

    // Author-epoch fetches and the FFI open share the same bound.
    await limiter.acquire()
    let epochJSON: String
    do {
      epochJSON = try await epochs.epochJSON(did: envelope.author.did, epochHead: envelope.record.authorEpochHead.data)
    } catch let error as AuthorEpochResolverError {
      await limiter.release()
      // A definitive answer (no such epoch), negative-cached by the resolver.
      logger.notice("Circles: author epoch unknown (\(String(describing: error), privacy: .public))")
      return .unverifiable
    } catch {
      await limiter.release()
      // Offline or the author's PDS unreachable: not a verification failure.
      logger.notice("Circles: author epoch unavailable (\(String(describing: type(of: error)), privacy: .public))")
      return .retryLater
    }
    let payloadJSON: String
    do {
      payloadJSON = try await crypto.openPost(
        recordJSON: recordJSON,
        postURI: envelope.uri.uriString(),
        authorDID: envelope.author.did.didString(),
        circleKey: circleKey,
        authorEpochJSON: epochJSON
      )
      await limiter.release()
    } catch {
      await limiter.release()
      // The error type and class only: FFI messages are not guaranteed free of input fragments.
      let failure = CircleOpenFailure(error)
      if failure.isMemoizable { failedOpens[failureKey] = Date() }
      switch failure {
      case .rejected:
        logger.notice("Circles: opening a post failed (\(String(describing: type(of: error)), privacy: .public))")
        return .unverifiable
      case .untrusted, .ownerMismatch:
        logger.warning("Circles: a post's author could not be verified; retried on the next open")
        return .unverifiable
      case .transient:
        logger.notice("Circles: opening a post is unavailable right now (\(String(describing: type(of: error)), privacy: .public))")
        return .retryLater
      }
    }

    guard let payload = try? Self.parsePayload(payloadJSON, keyVersion: version) else {
      logger.notice("Circles: an opened payload was malformed")
      failedOpens[failureKey] = Date()
      return .unverifiable
    }
    cache.storeOpened(
      payload, accountDID: accountDID, space: circle.uri, uri: envelope.uri, cid: envelope.cid, generation: generation
    )
    await register(payload.media, circle: circle, authorDID: envelope.author.did, generation: generation)
    return .payload(payload)
  }

  /// Registers media keys unless the account or Space was purged since
  /// `generation` was read (the same rule as `storeOpened`).
  private func register(_ media: [CircleMediaKeyRef], circle: CircleSummary, authorDID: DID, generation: UUID) async {
    guard let mediaLoader, !media.isEmpty, cache.generation(accountDID: accountDID) == generation else { return }
    await mediaLoader.registerKeys(media, accountDID: accountDID, space: circle.uri, authorDID: authorDID)
  }

  /// Rejected opens (`CircleOpenFailure.rejected`) and malformed payloads
  /// depend only on these inputs, so they are not retried until
  /// `failedOpenTTL` passes. Transient and untrusted failures are never
  /// memoized (I3).
  static let failedOpenTTL: TimeInterval = 600

  /// The Space and the key's fingerprint are part of the key: the same
  /// uri/cid presented under another Space sharing the `circleId` (a migrated
  /// Circle), or a key re-adopted after a CID conflict, is a different input.
  private static func failureKey(_ envelope: Envelope, space: SpaceRef, circleKey: Data) -> String {
    let fingerprint = SHA256.hash(data: circleKey).prefix(16).map { String(format: "%02x", $0) }.joined()
    return "\(space.uriString())|\(envelope.uri.uriString())|\(envelope.cid.string)|\(envelope.record.keyVersion)|"
      + envelope.record.authorEpochHead.data.base64EncodedString() + "|\(fingerprint)"
  }

  // MARK: Records and payloads

  static let unknownURI = try! ATProtocolURI(uriString: "at://did:web:invalid/blue.catbird.circle.post/unknown")

  /// The images-embed URI naming an encrypted blob. `.invalid` never resolves,
  /// so a renderer outside the Circle path can't fetch anything with it;
  /// `CircleMediaView` reads the `cid` query item.
  static func mediaURI(for cid: CID) -> URI {
    URI(uriString: "https://circle-media.invalid/blob?cid=\(cid.string)")
  }

  /// The envelope inside a thread node's record container, whatever form
  /// Petrel decoded it into.
  static func circlePostRecord(_ container: ATProtocolValueContainer) -> BlueCatbirdCirclePost? {
    switch container {
    case .knownType(let value):
      return value as? BlueCatbirdCirclePost
    case .unknownType(let type, _) where type == CirclePostSealer.postCollection:
      break
    case .object(let fields) where fields["$type"] == .string(CirclePostSealer.postCollection):
      break
    default:
      return nil
    }
    guard let data = try? JSONEncoder().encode(container) else { return nil }
    return try? JSONDecoder().decode(BlueCatbirdCirclePost.self, from: data)
  }

  /// The AAD binds the STANDARD form `at://<author-did>/blue.catbird.circle.post/<tid>`.
  private static func isCanonical(uri: ATProtocolURI, authorDID: DID) -> Bool {
    let prefix = "at://\(authorDID.didString())/\(CirclePostSealer.postCollection)/"
    let string = uri.uriString()
    guard string.hasPrefix(prefix) else { return false }
    return (try? TID(tidString: String(string.dropFirst(prefix.count)))) != nil
  }

  /// The `catbird-mls` `CirclePostPayload` shape: snake_case, byte fields as
  /// JSON integer arrays.
  private struct WirePayload: Decodable {
    struct Media: Decodable {
      let cid: String
      let key: [UInt8]
      let iv: [UInt8]
      let sha256: String
      let mime_type: String
      let alt: String?
      let width: Int?
      let height: Int?
    }

    let post: AppBskyFeedPost
    let media: [Media]
  }

  static func parsePayload(_ json: String, keyVersion: UInt64 = 0) throws -> CircleOpenedPayload {
    let wire = try JSONDecoder().decode(WirePayload.self, from: Data(json.utf8))
    let media = try wire.media.map { entry in
      CircleMediaKeyRef(
        cid: try CID.parse(entry.cid),
        key: Data(entry.key),
        iv: Data(entry.iv),
        sha256: entry.sha256,
        mimeType: entry.mime_type,
        alt: entry.alt,
        width: entry.width,
        height: entry.height
      )
    }
    return CircleOpenedPayload(post: wire.post, media: media, keyVersion: keyVersion)
  }

  private static func feedViewPost(_ envelope: Envelope, payload: CircleOpenedPayload) -> AppBskyFeedDefs.FeedViewPost {
    var embed: AppBskyFeedDefs.PostViewEmbedUnion?
    if !payload.media.isEmpty {
      let images = payload.media.map { ref in
        let ratio: AppBskyEmbedDefs.AspectRatio?
        if let width = ref.width, let height = ref.height, width > 0, height > 0 {
          ratio = AppBskyEmbedDefs.AspectRatio(width: width, height: height)
        } else {
          ratio = nil
        }
        let uri = mediaURI(for: ref.cid)
        return AppBskyEmbedImages.ViewImage(thumb: uri, fullsize: uri, alt: ref.alt ?? "", aspectRatio: ratio)
      }
      embed = .appBskyEmbedImagesView(AppBskyEmbedImages.View(images: images))
    }
    let post = AppBskyFeedDefs.PostView(
      uri: envelope.uri,
      cid: envelope.cid,
      author: envelope.author,
      record: .knownType(payload.post),
      embed: embed,
      bookmarkCount: nil,
      replyCount: envelope.replyCount,
      repostCount: envelope.repostCount,
      likeCount: envelope.likeCount,
      quoteCount: nil,
      indexedAt: envelope.indexedAt,
      viewer: envelope.viewer,
      labels: envelope.labels,
      threadgate: nil,
      debug: nil
    )
    return AppBskyFeedDefs.FeedViewPost(post: post)
  }
}

/// One thing to open in a batch.
enum CircleOpenRequest: Sendable {
  case feedItem(BlueCatbirdCircleDefs.FeedItem)
  case threadNode(AppBskyFeedDefs.PostView, circle: CircleSummary)

  var uri: ATProtocolURI {
    switch self {
    case .feedItem(let item): return item.post.postURI ?? CirclePostOpener.unknownURI
    case .threadNode(let post, _): return post.uri
    }
  }

  var circle: CircleSummary {
    switch self {
    case .feedItem(let item): return item.circle
    case .threadNode(_, let circle): return circle
    }
  }
}
