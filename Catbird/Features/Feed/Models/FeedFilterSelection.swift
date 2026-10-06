import Foundation

/// Stored sources stay distinct until an explicit user edit reconciles them.
struct FeedFilterSources: Equatable, Sendable {
  let local: Bool
  let synced: Bool

  var isHidden: Bool { local || synced }
  var description: String {
    switch (local, synced) {
    case (true, true): return "Hidden by Bluesky and a filter on this device"
    case (true, false): return "Hidden by a filter on this device"
    case (false, true): return "Hidden by Bluesky preferences"
    case (false, false): return "Shown"
    }
  }
}

enum FeedContentType: String, CaseIterable, Identifiable, Sendable {
  case any, text, media, conflicting
  var id: Self { self }
  var title: String {
    switch self {
    case .any: return "All Posts"
    case .text: return "Text Only"
    case .media: return "Images and Videos Only"
    case .conflicting: return "Existing Conflicting Filters"
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
