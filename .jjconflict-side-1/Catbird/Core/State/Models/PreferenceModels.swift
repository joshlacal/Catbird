import Foundation
import Petrel

// Models for Bluesky preferences, following the AT Protocol specifications

/// Represents content label preference for controlling visibility of labeled content
struct ContentLabelPreference: Codable, Hashable {
  let labelerDid: DID?
  let label: String
  let visibility: String  // "hide", "warn", or "ignore"
}

/// Represents thread view preference for controlling thread display
struct ThreadViewPreference: Codable, Hashable {
  let sort: String?  // "oldest", "newest", "most-likes", "random"
  let prioritizeFollowedUsers: Bool?
}

/// Represents feed view preference for controlling feed content display
struct FeedViewPreference: Codable, Hashable {
  let hideReplies: Bool?
  let hideRepliesByUnfollowed: Bool?
  let hideRepliesByLikeCount: Int?
  let hideReposts: Bool?
  let hideQuotePosts: Bool?
}

/// Represents a muted word with configuration
struct MutedWord: Codable, Hashable, Identifiable {
  var id: String
  let value: String
  let targets: [String]  // "content", "tag"
  let actorTarget: String?
  let expiresAt: Date?
}

/// Represents a labeler preference
struct LabelerPreference: Codable, Hashable {
  let did: DID
}

/// Represents a new user experience state
struct NuxState: Codable, Hashable, Identifiable {
  let id: String
  var completed: Bool
  var data: String?
  var expiresAt: Date?
}
