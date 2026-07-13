//
//  PostEntityStore.swift
//  Catbird
//
//  In-memory registry of recently rendered posts so App Intents entity
//  resolution can answer Siri's onscreen-context requests ("like this post")
//  without a network round trip. Siri enforces a sub-second deadline on the
//  'View AppIntents Payload' request; client bootstrap + getPosts reliably
//  missed it (observed 800ms+ for a post that was already on screen).
//  Populated from the feed pipeline and from PostView render setup, which
//  covers threads and search — everything "this post" can refer to.
//

import Foundation
import OSLog
import Petrel

@available(iOS 18.0, *)
actor PostEntityStore {
  static let shared = PostEntityStore()

  private let logger = Logger(subsystem: "blue.catbird", category: "PostEntityStore")

  /// FIFO-evicted view cache; refreshing an existing id updates its content
  /// without re-ordering.
  private var views: [String: AppBskyFeedDefs.PostView] = [:]
  private var order: [String] = []
  private let capacity = 500

  private init() {}

  func store(_ view: AppBskyFeedDefs.PostView) {
    let id = view.uri.uriString()
    if views.updateValue(view, forKey: id) == nil {
      order.append(id)
      if order.count > capacity {
        views.removeValue(forKey: order.removeFirst())
      }
    }
  }

  func store(views newViews: [AppBskyFeedDefs.PostView]) {
    for view in newViews {
      store(view)
    }
    // Write through to the shared app group so App Intents extension processes
    // (Siri, Shortcuts) can resolve entities without a network round trip.
    PostEntityCache.upsert(newViews)
  }

  /// Contract consumed by the generated PostEntityQuery (manifest
  /// `query.byIds.localStore`): identifiers with no cached view are simply
  /// omitted — the query fetches only those over the network.
  func entities(for identifiers: [String]) -> [PostEntity] {
    let hits = identifiers.compactMap { id in
      views[id].map { PostEntity(from: $0) }
    }
    logger.info(
      "resolve: \(hits.count)/\(identifiers.count) from store (\(self.views.count) cached)")
    if hits.count < identifiers.count {
      let missing = identifiers.filter { views[$0] == nil }
      logger.warning("misses (network fallback): \(missing.prefix(3).joined(separator: " | "))")
    }
    return hits
  }
}
