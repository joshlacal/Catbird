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

import Foundation
import OSLog
import Petrel

// MARK: - Persisted model

struct PersistedPostEntity: Codable {
  var id: String
  var authorDisplayName: String?
  var authorHandle: String
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

  private static let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .secondsSince1970
    return e
  }()

  private static let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .secondsSince1970
    return d
  }()

  /// Merges new post views into the persistent shared cache. Existing entries
  /// for the same AT URI are updated; new entries are prepended. The cache is
  /// trimmed to `capacity` after each write.
  static func upsert(
    _ views: [AppBskyFeedDefs.PostView],
    defaults: UserDefaults? = UserDefaults(suiteName: IntentAccountResolver.appGroupSuiteName)
  ) {
    guard let defaults else { return }
    let newEntries = views.compactMap { PersistedPostEntity(from: $0) }
    guard !newEntries.isEmpty else { return }

    var entries = decode(from: defaults)
    let newIDs = Set(newEntries.map(\.id))

    // Prepend fresh entries, removing any stale copies for the same AT URIs
    entries = newEntries + entries.filter { !newIDs.contains($0.id) }

    if entries.count > capacity {
      entries = Array(entries.prefix(capacity))
    }

    do {
      let data = try encoder.encode(entries)
      defaults.set(data, forKey: storageKey)
    } catch {
      logger.error("upsert failed: \(error.localizedDescription)")
    }
  }

  /// Returns PostEntity instances for the given AT URI identifiers from the
  /// persistent shared cache. Identifiers with no matching entry are omitted.
  @available(iOS 18.0, *)
  static func entities(
    for identifiers: [String],
    defaults: UserDefaults? = UserDefaults(suiteName: IntentAccountResolver.appGroupSuiteName)
  ) -> [PostEntity] {
    guard let defaults else { return [] }
    let entries = decode(from: defaults)
    let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let result = identifiers.compactMap { id in byID[id].map { PostEntity(persisted: $0) } }
    if !result.isEmpty {
      logger.info(
        "persistent cache: \(result.count)/\(identifiers.count) hits")
    }
    return result
  }

  private static func decode(from defaults: UserDefaults) -> [PersistedPostEntity] {
    guard let data = defaults.data(forKey: storageKey) else { return [] }
    do {
      return try decoder.decode([PersistedPostEntity].self, from: data)
    } catch {
      logger.error("decode failed: \(error.localizedDescription)")
      return []
    }
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
    self.likeCount = persisted.likeCount
    self.repostCount = persisted.repostCount
    self.replyCount = persisted.replyCount
    self.indexedAt = persisted.indexedAt
    self.text = persisted.text
    self.rkey = persisted.rkey
  }
}
