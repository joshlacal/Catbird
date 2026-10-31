import Petrel

/// A pure URI patch over V2 records; unrelated IDs, types and relative order survive.
enum FeedLibraryServerMerge {
  /// Reorder the pinned subsequence, leaving unpinned and unknown records in their slots.
  static func applyPinnedOrder(_ order: FeedLibraryPendingStore.PinnedOrder?,
                               to original: [AppBskyActorDefs.SavedFeed]) -> [AppBskyActorDefs.SavedFeed] {
    guard let order else { return original }
    let pinned = original.filter(\.pinned)
    let values = FeedLibraryPendingStore.applyingPinnedOrder(order.uris, to: pinned.map(\.value))
    var remaining = pinned
    var ordered: [AppBskyActorDefs.SavedFeed] = []
    for value in values {
      if let index = remaining.firstIndex(where: { $0.value == value }) { ordered.append(remaining.remove(at: index)) }
    }
    ordered.append(contentsOf: remaining)
    var index = 0
    return original.map { item in
      guard item.pinned, index < ordered.count else { return item }
      defer { index += 1 }
      return ordered[index]
    }
  }

  static func migrateV1(pinned: [String], saved: [String], timelineIndex: Int?,
                        newIDs: [String: String]) -> [AppBskyActorDefs.SavedFeed] {
    var values = pinned
    if let timelineIndex, !values.contains("following") {
      values.insert("following", at: max(0, min(timelineIndex, values.count)))
    }
    let pinnedValues = Set(values)
    for uri in saved where !values.contains(uri) { values.append(uri) }
    return values.compactMap { uri in
      guard let id = newIDs[uri] else { return nil }
      let type = uri == "following" ? "timeline"
        : uri.contains("/app.bsky.graph.list/") ? "list" : "feed"
      return .init(id: id, type: type, value: uri, pinned: pinnedValues.contains(uri))
    }
  }

  static func apply(_ intents: [FeedLibraryPendingStore.Entry],
                    to original: [AppBskyActorDefs.SavedFeed],
                    newIDs: [String: String]) -> [AppBskyActorDefs.SavedFeed] {
    var feeds = original
    // Append rather than prepend: an existing pinned default retains its position.
    // On an empty library this establishes Following before any new pin is applied.
    if !feeds.contains(where: { $0.type == "timeline" || ["following", "home", "timeline"].contains($0.value) }),
       let id = newIDs["following"] {
      feeds.append(.init(id: id, type: "timeline", value: "following", pinned: true))
    }
    for entry in intents {
      switch entry.intent {
      case .removed: feeds.removeAll { $0.value == entry.uri }
      case .saved:
        if !feeds.contains(where: { $0.value == entry.uri }), let id = newIDs[entry.uri] {
          feeds.append(.init(id: id, type: "feed", value: entry.uri, pinned: false))
        }
      case .pinned, .unpinned:
        let pin = entry.intent == .pinned
        if let existing = feeds.first(where: { $0.value == entry.uri }) {
          if existing.pinned != pin {
            feeds.removeAll { $0.value == entry.uri }
            feeds.append(.init(id: existing.id, type: existing.type, value: existing.value, pinned: pin))
          }
        } else if let id = newIDs[entry.uri] {
          feeds.append(.init(id: id, type: "feed", value: entry.uri, pinned: pin))
        }
      }
    }
    return feeds
  }
}
