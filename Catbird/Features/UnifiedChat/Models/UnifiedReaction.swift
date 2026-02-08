import Foundation

// MARK: - UnifiedReaction

struct UnifiedReaction: Identifiable, Hashable, Sendable {
  var id: String { "\(messageID)_\(emoji)_\(senderDID)" }
  let messageID: String
  let emoji: String
  let senderDID: String
  let isFromCurrentUser: Bool
  let reactedAt: Date?
}

// MARK: - UnifiedReactionSummary

struct UnifiedReactionSummary: Identifiable, Hashable, Sendable {
  var id: String { emoji }
  let emoji: String
  let count: Int
  let reactors: [String]
  let isReactedByCurrentUser: Bool
}
