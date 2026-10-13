//
//  PostEntityCache.swift
//  Catbird
//
//  Persistent mirror of PostEntity data in the shared app group so App Intents
//  extension processes (Siri, Shortcuts, Spotlight) can resolve onscreen-context
//  annotations without a network round trip.
//
//  The main app process writes here via PostEntityStore.store(views:). The
//  intent extension process reads here in PostEntityQuery.entities(for:),
//  before falling through to the network. Siri enforces a sub-second deadline
//  on 'View AppIntents Payload'; this cache is the only reliable path that
//  fits inside that window from an out-of-process context.
//
//  Writes are buffered (AppGroupEntityWriteBuffer) and reach the App Group
//  about 1.5 s after the last one, or when the app resigns active, instead of
//  rewriting the blob for every rendered row and thread snapshot.
//

import Foundation
import OSLog
import Petrel

// MARK: - Persisted model

struct PersistedPostEntity: Codable, Equatable, Sendable {
  var id: String
  var authorDisplayName: String?
  var authorHandle: String
  var authorAvatar: URL?
  var likeCount: Int?
  var repostCount: Int?
  var replyCount: Int?
  var indexedAt: Date
  var text: String?
  var rkey: String

  init?(from view: AppBskyFeedDefs.PostView) {
    self.id = view.uri.uriString()
    self.authorDisplayName = view.author.displayName
    self.authorHandle = view.author.handle.value
    self.authorAvatar = view.author.avatar?.url
    self.likeCount = view.likeCount
    self.repostCount = view.repostCount
    self.replyCount = view.replyCount
    self.indexedAt = view.indexedAt.date
    self.text = IntentEntityBridges.postText(view)
    self.rkey = IntentEntityBridges.recordKey(view.uri)
  }
}

// MARK: - Cache

enum PostEntityCache {
  private static let logger = Logger(subsystem: "blue.catbird", category: "PostEntityCache")
  static let storageKey = "recentPostEntities.v1"
  static let capacity = 50

  /// The App Group suite. Shared so the thread seed and `PostEntityStore.shared`
  /// feed one write buffer.
  static let appGroupDefaults = UserDefaults(suiteName: IntentAccountResolver.appGroupSuiteName)

  private static let buffers = WriteBufferRegistry()

  /// Merges new post views into the persistent shared cache. Existing entries
  /// for the same AT URI are updated; new entries are prepended. The cache is
  /// trimmed to `capacity`. The App Group write is coalesced; in-process reads
  /// through `entities(for:)` see the entries immediately.
  ///
  /// Callers outside tests should keep the default `appGroupDefaults`. Each
  /// UserDefaults instance gets its own buffer, which the registry keeps for
  /// the life of the process: a fresh `UserDefaults(suiteName:)` per call would
  /// register a new buffer and lifecycle observers every time, and two buffers
  /// on one suite would race and drop each other's writes.
  static func upsert(
    _ views: [AppBskyFeedDefs.PostView],
    defaults: UserDefaults? = appGroupDefaults
  ) {
    guard let defaults else { return }
    // Only the first `capacity` distinct posts can survive the trim, so a
    // large thread snapshot doesn't build entries that are thrown away.
    var seen = Set<String>()
    var newEntries: [PersistedPostEntity] = []
    for view in views where newEntries.count < capacity {
      guard seen.insert(view.uri.uriString()).inserted,
        let entry = PersistedPostEntity(from: view)
      else { continue }
      newEntries.append(entry)
    }
    guard !newEntries.isEmpty else { return }
    buffers.buffer(for: defaults).enqueue(newEntries)
  }

  /// Returns PostEntity instances for the given AT URI identifiers from the
  /// persistent shared cache, including writes not yet flushed by this
  /// process. Identifiers with no matching entry are omitted. As with
  /// `upsert`, keep the default `appGroupDefaults` outside tests.
  @available(iOS 18.0, *)
  static func entities(
    for identifiers: [String],
    defaults: UserDefaults? = appGroupDefaults
  ) -> [PostEntity] {
    // PostEntityStore asks only for its in-memory misses, usually none; don't
    // decode the stored blob for an empty request.
    guard !identifiers.isEmpty, let defaults else { return [] }
    let entries = buffers.buffer(for: defaults).entries()
    let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let result = identifiers.compactMap { id in byID[id].map { PostEntity(persisted: $0) } }
    if !result.isEmpty {
      logger.info(
        "persistent cache: \(result.count)/\(identifiers.count) hits")
    }
    return result
  }

  /// Writes any buffered entries to the App Group now.
  static func flushPendingWrites(defaults: UserDefaults? = appGroupDefaults) {
    guard let defaults else { return }
    buffers.buffer(for: defaults).flush()
  }

  /// Drops buffered entries and the stored list (sign-out); see AppGroupEntityWriteBuffer.removeAll.
  static func removeAll(defaults: UserDefaults? = appGroupDefaults) {
    guard let defaults else { return }
    buffers.buffer(for: defaults).removeAll()
  }

  /// One write buffer per UserDefaults instance. Holding the instance keeps
  /// its ObjectIdentifier from being reused while its buffer is registered.
  private final class WriteBufferRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [ObjectIdentifier: (defaults: UserDefaults, buffer: AppGroupEntityWriteBuffer<PersistedPostEntity>)] = [:]

    func buffer(for defaults: UserDefaults) -> AppGroupEntityWriteBuffer<PersistedPostEntity> {
      lock.lock()
      defer { lock.unlock() }
      if let existing = buffers[ObjectIdentifier(defaults)] {
        return existing.buffer
      }
      let buffer = AppGroupEntityWriteBuffer<PersistedPostEntity>(
        defaults: defaults,
        storageKey: PostEntityCache.storageKey,
        capacity: PostEntityCache.capacity,
        id: { $0.id },
        encode: { try PostEntityCache.makeEncoder().encode($0) },
        decode: { try PostEntityCache.makeDecoder().decode([PersistedPostEntity].self, from: $0) })
      buffers[ObjectIdentifier(defaults)] = (defaults, buffer)
      return buffer
    }
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    return encoder
  }

  private static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return decoder
  }
}

// MARK: - PostEntity convenience init

@available(iOS 18.0, *)
extension PostEntity {
  /// Creates a PostEntity from a persisted cache entry without requiring the
  /// full PostView. Used by PostEntityCache.entities(for:).
  init(persisted: PersistedPostEntity) {
    self.id = persisted.id
    self.authorDisplayName = persisted.authorDisplayName
    self.authorHandle = persisted.authorHandle
    self.authorAvatar = persisted.authorAvatar
    self.likeCount = persisted.likeCount
    self.repostCount = persisted.repostCount
    self.replyCount = persisted.replyCount
    self.indexedAt = persisted.indexedAt
    self.text = persisted.text
    self.rkey = persisted.rkey
  }
}
