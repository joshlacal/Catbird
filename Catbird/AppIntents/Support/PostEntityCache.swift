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
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
// MARK: - Persisted model

struct PersistedPostEntity: Codable, Equatable {
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
  static let flushInterval: TimeInterval = 1.5

  private static let lock = NSLock()
  private static var pendingEntries: [String: PersistedPostEntity] = [:]
  private static var pendingOrder: [String] = []
  private static var cachedPersisted: [PersistedPostEntity]? = nil
  private static var flushTask: Task<Void, Never>? = nil

  private static let lifecycleObserverSetup: Void = {
    #if canImport(UIKit)
    NotificationCenter.default.addObserver(
      forName: UIApplication.willResignActiveNotification,
      object: nil,
      queue: nil
    ) { _ in
      flushSync()
    }
    NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: nil
    ) { _ in
      flushSync()
    }
    #elseif canImport(AppKit)
    NotificationCenter.default.addObserver(
      forName: NSApplication.willResignActiveNotification,
      object: nil,
      queue: nil
    ) { _ in
      flushSync()
    }
    #endif
  }()
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
    _ = lifecycleObserverSetup
    guard let defaults else { return }

    // Deduplicate views by URI and cap to capacity before building entries (P084)
    var seen = Set<String>()
    var deduped: [AppBskyFeedDefs.PostView] = []
    for v in views {
      let uri = v.uri.uriString()
      if seen.insert(uri).inserted {
        deduped.append(v)
        if deduped.count == capacity { break }
      }
    }
    let newEntries = deduped.compactMap { PersistedPostEntity(from: $0) }
    guard !newEntries.isEmpty else { return }

    lock.lock()
    for entry in newEntries {
      if pendingEntries.updateValue(entry, forKey: entry.id) == nil {
        pendingOrder.append(entry.id)
      }
    }

    flushTask?.cancel()
    flushTask = Task.detached(priority: .utility) {
      try? await Task.sleep(nanoseconds: UInt64(flushInterval * 1_000_000_000))
      guard !Task.isCancelled else { return }
      flushSync(defaults: defaults)
    }
    lock.unlock()
  }

  /// Flushes pending post entities to UserDefaults synchronously.
  static func flushSync(
    defaults: UserDefaults? = UserDefaults(suiteName: IntentAccountResolver.appGroupSuiteName)
  ) {
    guard let defaults else { return }
    lock.lock()
    guard !pendingEntries.isEmpty else {
      lock.unlock()
      return
    }

    let pending = pendingEntries
    let order = pendingOrder
    pendingEntries.removeAll()
    pendingOrder.removeAll()
    flushTask?.cancel()
    flushTask = nil

    var entries = cachedPersisted ?? decode(from: defaults)
    let freshEntries = order.reversed().compactMap { pending[$0] }
    let freshIDs = Set(freshEntries.map(\.id))

    // Prepend fresh entries, removing any stale copies for the same AT URIs
    entries = freshEntries + entries.filter { !freshIDs.contains($0.id) }

    if entries.count > capacity {
      entries = Array(entries.prefix(capacity))
    }

    let changed = (cachedPersisted == nil) || (entries != cachedPersisted!)
    if changed {
      let signpostState = PerformanceSignposts.beginInterval("EntityExport")
      defer { PerformanceSignposts.endInterval("EntityExport", signpostState) }

      do {
        let data = try encoder.encode(entries)
        defaults.set(data, forKey: storageKey)
        cachedPersisted = entries
      } catch {
        logger.error("upsert failed: \(error.localizedDescription)")
      }
    } else {
      cachedPersisted = entries
    }
    lock.unlock()
  }

  /// Flushes pending post entities to UserDefaults immediately.
  static func flushPendingWrites(
    defaults: UserDefaults? = UserDefaults(suiteName: IntentAccountResolver.appGroupSuiteName)
  ) {
    flushSync(defaults: defaults)
  }

  /// Returns PostEntity instances for the given AT URI identifiers from the
  /// persistent shared cache. Identifiers with no matching entry are omitted.
  @available(iOS 18.0, *)
  static func entities(
    for identifiers: [String],
    defaults: UserDefaults? = UserDefaults(suiteName: IntentAccountResolver.appGroupSuiteName)
  ) -> [PostEntity] {
    guard let defaults else { return [] }
    lock.lock()
    let pending = pendingEntries
    let persisted = cachedPersisted ?? decode(from: defaults)
    lock.unlock()

    let persistedByID = Dictionary(persisted.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    let result = identifiers.compactMap { id -> PostEntity? in
      if let pendingEntry = pending[id] {
        return PostEntity(persisted: pendingEntry)
      } else if let persistedEntry = persistedByID[id] {
        return PostEntity(persisted: persistedEntry)
      }
      return nil
    }
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
    self.authorAvatar = persisted.authorAvatar
    self.likeCount = persisted.likeCount
    self.repostCount = persisted.repostCount
    self.replyCount = persisted.replyCount
    self.indexedAt = persisted.indexedAt
    self.text = persisted.text
    self.rkey = persisted.rkey
  }
}
