import Petrel

/// A pure URI patch over V2 records; unrelated IDs, types and relative order survive.
enum FeedLibraryServerMerge {
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
      return .init(id: id, type: SystemFeedTypes.savedFeedType(for: uri), value: uri,
                   pinned: pinnedValues.contains(uri))
    }
  }

  /// Repairs a V2 list before merging: an at:// value typed "timeline" (written by the old
  /// substring classifier) is retyped as the feed or list it is, only the first timeline item
  /// is kept, and a value saved more than once keeps its first entry.
  static func normalize(_ original: [AppBskyActorDefs.SavedFeed]) -> [AppBskyActorDefs.SavedFeed] {
    var seen = Set<String>()
    var hasTimeline = false
    var feeds: [AppBskyActorDefs.SavedFeed] = []
    for feed in original {
      var item = feed
      if item.type == "timeline" && item.value.hasPrefix("at://") {
        item = .init(id: item.id, type: SystemFeedTypes.savedFeedType(for: item.value),
                     value: item.value, pinned: item.pinned)
      }
      let isTimeline = item.type == "timeline" || SystemFeedTypes.isTimelineFeed(item.value)
      if isTimeline {
        if hasTimeline { continue }
        hasTimeline = true
      }
      guard seen.insert(item.value).inserted else { continue }
      feeds.append(item)
    }
    return feeds
  }

  /// `ensureTimeline` is for a library with no V2 record yet. An existing V2 list without a
  /// timeline item is the user's choice and is left as it is, so adding a feed never adds one.
  static func apply(_ intents: [FeedLibraryPendingStore.Entry],
                    to original: [AppBskyActorDefs.SavedFeed],
                    newIDs: [String: String],
                    ensureTimeline: Bool = true) -> [AppBskyActorDefs.SavedFeed] {
    var feeds = original
    // Append rather than prepend: an existing pinned default retains its position.
    if ensureTimeline,
       !feeds.contains(where: { $0.type == "timeline" || SystemFeedTypes.isTimelineFeed($0.value) }),
       let id = newIDs["following"] {
      feeds.append(.init(id: id, type: "timeline", value: "following", pinned: true))
    }
    for entry in intents {
      switch entry.intent {
      case .removed: feeds.removeAll { $0.value == entry.uri }
      case .saved:
        if !feeds.contains(where: { $0.value == entry.uri }), let id = newIDs[entry.uri] {
          feeds.append(.init(id: id, type: SystemFeedTypes.savedFeedType(for: entry.uri),
                             value: entry.uri, pinned: false))
        }
      case .pinned, .unpinned:
        let pin = entry.intent == .pinned
        if let existing = feeds.first(where: { $0.value == entry.uri }) {
          if existing.pinned != pin {
            feeds.removeAll { $0.value == entry.uri }
            feeds.append(.init(id: existing.id, type: existing.type, value: existing.value, pinned: pin))
          }
        } else if let id = newIDs[entry.uri] {
          feeds.append(.init(id: id, type: SystemFeedTypes.savedFeedType(for: entry.uri),
                             value: entry.uri, pinned: pin))
        }
      }
    }
    return feeds
  }
}
