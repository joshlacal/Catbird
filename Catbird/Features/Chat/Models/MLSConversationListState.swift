import CatbirdMLSCore
import SwiftUI

/// Equatable wrapper for MLS last message preview, replacing the tuple
/// `(senderDID: String, text: String)` so the parent struct can conform to Equatable.
struct MLSLastMessagePreview: Equatable, Sendable {
  let senderDID: String
  let text: String
}

/// Bundles all MLS conversation list state into a single struct.
/// Assigning this as one value prevents SwiftUI flicker from multiple @State updates.
struct MLSConversationListState: Equatable {
  var conversations: [MLSConversationModel] = []
  var participants: [String: [MLSParticipantViewModel]] = [:]
  var unreadCounts: [String: Int] = [:]
  var lastMessages: [String: MLSLastMessagePreview] = [:]
  var latestActivity: [String: Date] = [:]
  var memberChanges: [String: MemberChangeInfo] = [:]
  var pendingChatRequestCount: Int = 0
  var isLoading: Bool = false

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.conversations.map(\.conversationID) == rhs.conversations.map(\.conversationID)
      && lhs.unreadCounts == rhs.unreadCounts
      && lhs.lastMessages == rhs.lastMessages
      && lhs.latestActivity == rhs.latestActivity
      && lhs.pendingChatRequestCount == rhs.pendingChatRequestCount
      && lhs.isLoading == rhs.isLoading
  }
}
