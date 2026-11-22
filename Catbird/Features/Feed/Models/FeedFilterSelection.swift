import Foundation

/// Stored sources stay distinct until an explicit user edit reconciles them.
struct FeedFilterSources: Equatable, Sendable {
  let local: Bool
  let synced: Bool

  var isHidden: Bool { local || synced }
  var description: String {
    switch (local, synced) {
    case (true, true):
      return String(
        localized: "Hidden by Bluesky and a filter on this device",
        comment: "Feed filter status when a content type is hidden both on Bluesky and locally"
      )
    case (true, false):
      return String(
        localized: "Hidden by a filter on this device",
        comment: "Feed filter status when a content type is hidden by a local device filter"
      )
    case (false, true):
      return String(
        localized: "Hidden by Bluesky preferences",
        comment: "Feed filter status when a content type is hidden by synced Bluesky preferences"
      )
    case (false, false):
      return String(
        localized: "Shown",
        comment: "Feed filter status when a content type is visible in the feed"
      )
    }
  }
}

enum FeedContentType: String, CaseIterable, Identifiable, Sendable {
  case any, text, media, conflicting
  var id: Self { self }
  var title: String {
    switch self {
    case .any:
      return String(localized: "All Posts", comment: "Feed content filter option showing all posts")
    case .text:
      return String(localized: "Text Only", comment: "Feed content filter option showing text-only posts")
    case .media:
      return String(localized: "Images and Videos Only", comment: "Feed content filter option showing media posts only")
    case .conflicting:
      return String(localized: "Existing Conflicting Filters", comment: "Feed content filter state when incompatible filters are both enabled")
    }
  }
  init(textOnly: Bool, mediaOnly: Bool) {
    switch (textOnly, mediaOnly) {
    case (false, false): self = .any
    case (true, false): self = .text
    case (false, true): self = .media
    case (true, true): self = .conflicting
    }
  }
}
